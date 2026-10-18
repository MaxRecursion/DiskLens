import Foundation
import Darwin

/// How much space deleting a path would actually free, accounting for APFS clones and hard links.
public struct ReclaimEstimate: Codable, Sendable, Hashable {
    public var path: String
    /// Sum of st_blocks*512 (upper bound; what `du` reports).
    public var allocated: Int64
    /// Bytes that would actually be freed: private (unshared) blocks of files whose every hard
    /// link lies inside `path`.
    public var reclaimable: Int64
    /// Allocated bytes shared with APFS clones outside the deleted set (not freed).
    public var cloneShared: Int64
    /// Allocated bytes of hard-linked files that still have links elsewhere (not freed).
    public var hardLinkRetained: Int64
    public var filesExamined: Int64
    public var errors: Int
    /// True when every entry could be examined.
    public var complete: Bool
    /// True when getattrlist(ATTR_CMNEXT_PRIVATESIZE) was available; false means the estimate
    /// fell back to allocated size.
    public var usedPrivateSize: Bool
    public var method: String {
        usedPrivateSize ? "APFS private-size walk (clone- and hard-link-aware)" : "allocated size (upper bound)"
    }
}

public enum ReclaimEstimator {
    /// Private (unshared) bytes of a single file via getattrlist, or nil if unsupported.
    public static func privateSize(of path: String) -> Int64? {
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buf = [UInt8](repeating: 0, count: 32)
        let r = buf.withUnsafeMutableBytes { p in
            getattrlist(path, &al, p.baseAddress, p.count, UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED))
        }
        guard r == 0 else { return nil }
        return buf.withUnsafeBytes { p -> Int64? in
            let len = p.load(fromByteOffset: 0, as: UInt32.self)
            guard len >= 12 else { return nil }
            return p.loadUnaligned(fromByteOffset: 4, as: Int64.self)
        }
    }

    /// Walks `path` (no symlink following) and estimates bytes freed by deleting it.
    public static func estimate(path: String, isCancelled: () -> Bool = { false }) -> ReclaimEstimate {
        DatalessPolicy.disableMaterialization()
        var est = ReclaimEstimate(path: path, allocated: 0, reclaimable: 0, cloneShared: 0, hardLinkRetained: 0,
                                  filesExamined: 0, errors: 0, complete: true, usedPrivateSize: true)
        guard let cpath = strdup(path) else { est.complete = false; return est }
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = argv.withUnsafeMutableBufferPointer({ fts_open($0.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR, nil) }) else {
            est.complete = false; est.errors += 1; return est
        }
        defer { fts_close(fts) }

        struct Linked { var nlink: Int; var seen: Int; var alloc: Int64; var priv: Int64 }
        var linked: [UInt64: Linked] = [:]
        var rootDev: Int32 = -1
        var n = 0
        while let ent = fts_read(fts) {
            n += 1
            if n & 1023 == 0 && isCancelled() { est.complete = false; break }
            let info = Int32(ent.pointee.fts_info)
            switch info {
            case FTS_D:
                let st = ent.pointee.fts_statp.pointee
                if ent.pointee.fts_level == 0 { rootDev = st.st_dev }
                if st.st_dev != rootDev || (ent.pointee.fts_level > 0 && (st.st_flags & 0x4000_0000) != 0) {
                    fts_set(fts, ent, FTS_SKIP); est.complete = false; continue
                }
                est.allocated += Int64(st.st_blocks) * 512
                est.reclaimable += Int64(st.st_blocks) * 512
            case FTS_F:
                let st = ent.pointee.fts_statp.pointee
                let alloc = Int64(st.st_blocks) * 512
                est.filesExamined += 1
                var priv = alloc
                if let p = privateSize(of: String(cString: ent.pointee.fts_path)) {
                    priv = min(max(0, p), alloc)
                } else {
                    est.usedPrivateSize = false
                }
                if st.st_nlink > 1 {
                    var l = linked[UInt64(st.st_ino)] ?? Linked(nlink: Int(st.st_nlink), seen: 0, alloc: alloc, priv: priv)
                    l.seen += 1
                    if l.seen == 1 { est.allocated += alloc }
                    linked[UInt64(st.st_ino)] = l
                } else {
                    est.allocated += alloc
                    est.reclaimable += priv
                    est.cloneShared += alloc - priv
                }
            case FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                let st = ent.pointee.fts_statp.pointee
                est.allocated += Int64(st.st_blocks) * 512
                est.reclaimable += Int64(st.st_blocks) * 512
            case FTS_DNR, FTS_NS, FTS_ERR:
                est.errors += 1
                est.complete = false
            default:
                break
            }
        }
        for (_, l) in linked {
            if l.seen >= l.nlink {
                est.reclaimable += l.priv
                est.cloneShared += l.alloc - l.priv
            } else {
                est.hardLinkRetained += l.alloc
            }
        }
        return est
    }

    /// Fast allocated-size walk (du -sk equivalent, hard links counted once). Used for
    /// before/after verification.
    public static func allocatedSize(of path: String) -> Int64? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        if (st.st_mode & S_IFMT) != S_IFDIR { return Int64(st.st_blocks) * 512 }
        guard let cpath = strdup(path) else { return nil }
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = argv.withUnsafeMutableBufferPointer({ fts_open($0.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR, nil) }) else { return nil }
        defer { fts_close(fts) }
        var total: Int64 = 0
        var seen = Set<UInt64>()
        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            guard info == FTS_D || info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT else { continue }
            let s = ent.pointee.fts_statp.pointee
            if info == FTS_F && s.st_nlink > 1 && !seen.insert(UInt64(s.st_ino)).inserted { continue }
            total += Int64(s.st_blocks) * 512
        }
        return total
    }
}
