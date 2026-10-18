import Foundation
import CryptoKit

/// Finds byte-identical copies among large user-content files and reports them per folder as
/// tier-3 (manual review) items. Contents are read only to compute SHA-256 digests in memory;
/// digests and contents are never stored, logged or displayed. APFS clones are recognised via
/// their private size, so a cloned copy is reported as freeing ~0 bytes.
public enum DuplicateFinder {
    public struct Options: Sendable {
        public var minFileBytes: Int64 = 5_000_000
        /// Upper bound on bytes hashed per analysis (coverage is reported when hit).
        public var maxHashBytes: Int64 = 40_000_000_000
        public var categories: Set<StorageCategory> = [.documentsMedia, .downloadsArchives]
        /// Folders whose redundant copies total less than this are not reported (noise).
        public var minFolderBytes: Int64 = 50_000_000
        public init() {}
    }

    struct Candidate { var id: Int32; var path: String; var size: Int64; var alloc: Int64; var mtime: Int64; var device: Int32; var inode: UInt64 }

    public struct Result: Sendable {
        public var recommendations: [Recommendation]
        public var filesHashed: Int
        public var bytesHashed: Int64
        public var truncated: Bool
    }

    public static func analyze(tree: ScanTree, home: String, existing: [Recommendation], options: Options = Options(),
                               isCancelled: () -> Bool = { false }) -> Result {
        DatalessPolicy.disableMaterialization()
        let claimed = existing.map(\.targetPath)
        var cands: [Candidate] = []
        tree.walk { id, n in
            if id == ScanTree.root { return true }
            if n.isDirectory {
                // Skip app-managed and developer areas entirely.
                if n.name == ".git" || n.name == "node_modules" || n.flags.contains(.package)
                    || n.markers.contains(.chromiumProfile) || ["Cache", "Code Cache", "Service Worker", "CacheStorage", "GPUCache"].contains(n.name) {
                    return false
                }
                if n.parent == ScanTree.root && !PathUtil.isSameOrInside(home, n.name) && !PathUtil.isSameOrInside(n.name, home) { return false }
                return true
            }
            guard !n.isAggregate, n.allocated >= options.minFileBytes || n.logical >= options.minFileBytes,
                  options.categories.contains(n.category), !n.flags.contains(.dataless) else { return false }
            let p = tree.path(of: id)
            guard p.hasPrefix(home + "/"), !p.hasPrefix(home + "/Library/"), !p.contains("/."),
                  !claimed.contains(where: { PathUtil.isSameOrInside(p, $0) }) else { return false }
            cands.append(Candidate(id: id, path: p, size: n.logical, alloc: n.allocated, mtime: n.mtime, device: n.device, inode: n.inode))
            return false
        }
        // Same size is necessary for identical content; hard links (same inode) are one file.
        let bySize = Dictionary(grouping: cands, by: \.size).filter { $0.value.count > 1 }
        var hashed = 0
        var bytes: Int64 = 0
        var truncated = false
        var sets: [[Candidate]] = []
        for (_, group) in bySize.sorted(by: { $0.key > $1.key }) {
            if isCancelled() { truncated = true; break }
            var byInode: [String: Candidate] = [:]
            for c in group { byInode["\(c.device):\(c.inode)"] = c }
            let unique = Array(byInode.values)
            guard unique.count > 1 else { continue }
            if bytes + Int64(unique.count) * unique[0].size > options.maxHashBytes { truncated = true; continue }
            var byHash: [Data: [Candidate]] = [:]
            for c in unique {
                guard let h = sha256(c.path) else { continue }
                hashed += 1
                bytes += c.size
                byHash[h, default: []].append(c)
            }
            sets += byHash.values.filter { $0.count > 1 }
        }

        // Keep the copy whose removal would free the least (e.g. one whose blocks are shared with an
        // APFS clone elsewhere), so the reported copies are the ones that actually free space.
        // Ties prefer keeping a copy outside Downloads, then the oldest.
        struct Copy { var c: Candidate; var original: String; var reclaim: Int64; var clone: Bool }
        var copies: [Copy] = []
        for s in sets {
            // Private size handles clones; a file with other hard links frees nothing when one link goes.
            let priv = Dictionary(uniqueKeysWithValues: s.map { c -> (String, Int64) in
                var st = stat()
                if lstat(c.path, &st) == 0 && st.st_nlink > 1 { return (c.path, 0) }
                return (c.path, min(ReclaimEstimator.privateSize(of: c.path) ?? c.alloc, c.alloc))
            })
            let ordered = s.sorted { a, b in
                let pa = priv[a.path] ?? a.alloc, pb = priv[b.path] ?? b.alloc
                if (pa < a.alloc / 10) != (pb < b.alloc / 10) { return pa < a.alloc / 10 }
                let ad = a.path.contains("/Downloads/"), bd = b.path.contains("/Downloads/")
                if ad != bd { return !ad }
                if a.mtime != b.mtime { return a.mtime < b.mtime }
                return a.path.count < b.path.count
            }
            let original = ordered[0]
            for c in ordered.dropFirst() {
                let p = priv[c.path] ?? c.alloc
                copies.append(Copy(c: c, original: original.path, reclaim: p, clone: p < c.alloc / 10))
            }
        }

        // Aggregate per folder holding the redundant copies.
        let byDir = Dictionary(grouping: copies) { PathUtil.parent($0.c.path) }
        var recs: [Recommendation] = []
        for (dir, items) in byDir {
            let alloc = items.reduce(Int64(0)) { $0 + $1.c.alloc }
            guard items.reduce(Int64(0), { $0 + $1.reclaim }) >= options.minFolderBytes else { continue }
            let logical = items.reduce(Int64(0)) { $0 + $1.c.size }
            let reclaim = items.reduce(Int64(0)) { $0 + $1.reclaim }
            let origDirs = Dictionary(grouping: items) { PathUtil.parent($0.original) }.sorted { $0.value.count > $1.value.count }
            let clones = items.filter(\.clone).count
            let totalInDir = tree.find(path: dir).map { tree.nodes[Int($0)].fileCount } ?? Int64(items.count)
            var notes = items.prefix(4).map { "\(PathUtil.lastComponent($0.c.path)) = \(PathUtil.abbreviated($0.original, home: home))" }
            if clones > 0 { notes.append("\(clones) of these copies share their blocks (APFS clone or hard link), so removing them frees almost nothing.") }
            var st = stat()
            lstat(dir, &st)
            recs.append(Recommendation(
                id: "duplicates:\(dir)", ruleID: "duplicates",
                title: "\(items.count) duplicate file\(items.count == 1 ? "" : "s") in \(PathUtil.abbreviated(dir, home: home))",
                targetPath: dir, category: .documentsMedia, detectedAllocated: alloc, detectedLogical: logical,
                fileCount: Int64(items.count), estimatedReclaimable: reclaim,
                reclaimMethod: "SHA-256 identical copies; APFS private size of the redundant copies",
                reason: "\(items.count) of \(totalInDir) files here are byte-identical (SHA-256) to files in \(origDirs.prefix(3).map { PathUtil.abbreviated($0.key, home: home) }.joined(separator: ", ")). The copy in the other location is treated as the original.",
                confidence: .high, risk: .high, tier: .manualReview,
                dependencies: "None — but these are personal files; decide which copy to keep yourself.",
                consequences: "Deleting the copies leaves the originals intact. Check that nothing (an app or script) reads files from this folder.",
                action: .review(dir),
                verification: "After you remove copies, rescan: the folder should shrink by about the estimate.",
                requiresElevation: false, inUseBy: [], ownerProcessHints: [], analysisComplete: !truncated, notes: notes,
                expectedDevice: st.st_dev, expectedInode: UInt64(st.st_ino), lastModified: nil))
        }
        recs.sort { $0.estimatedReclaimable > $1.estimatedReclaimable }
        return Result(recommendations: recs, filesHashed: hashed, bytesHashed: bytes, truncated: truncated)
    }

    static func sha256(_ path: String) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try fh.read(upToCount: 4 << 20) } catch { return nil }   // nil = end of file
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}
