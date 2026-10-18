import Foundation
import Darwin

public struct ScanProgress: Sendable, Hashable {
    public var entriesVisited: Int64
    public var filesVisited: Int64
    public var directoriesVisited: Int64
    public var bytesAllocated: Int64
    public var errors: Int
    public var currentPath: String
    public var currentRoot: String
    public var rootIndex: Int
    public var rootCount: Int
}

public struct ScanResult: Sendable {
    public var tree: ScanTree
    public var manifest: ScanManifest
    public init(tree: ScanTree, manifest: ScanManifest) {
        self.tree = tree
        self.manifest = manifest
    }
}

/// Thread-safe cancellation flag shared between the async caller and the scanning thread.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Prevents this process from triggering downloads of cloud-only (dataless) files and folders.
/// Without it, merely listing a File Provider folder (Google Drive, iCloud) can block on the network
/// and pull data onto the disk — the opposite of what a read-only analyzer should do.
public enum DatalessPolicy {
    static let IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES: Int32 = 3
    static let IOPOL_SCOPE_PROCESS: Int32 = 0
    static let IOPOL_MATERIALIZE_DATALESS_FILES_OFF: Int32 = 1

    @discardableResult
    public static func disableMaterialization() -> Bool {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
    }

    public static var materializationDisabled: Bool {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF
    }
}

/// Detects folders whose opening blocks (e.g. waiting on a TCC consent prompt).
public enum PrivacyProbe {
    public static func protectedFolders(home: String) -> [String] {
        ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public",
         "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail", "Library/Messages"]
            .map { home + "/" + $0 }
            .filter { var st = stat(); return lstat($0, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR }
    }

    /// Paths whose opendir() did not complete within `timeout` seconds. Probes run concurrently;
    /// a probe stuck on a prompt is simply abandoned (its thread finishes whenever the user answers).
    public static func unresponsive(_ paths: [String], timeout: TimeInterval) -> [String] {
        final class Box: @unchecked Sendable { let lock = NSLock(); var done = Set<String>() }
        let box = Box()
        let group = DispatchGroup()
        for p in paths {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                if let d = opendir(p) { closedir(d) }
                box.lock.lock(); box.done.insert(p); box.lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        box.lock.lock(); defer { box.lock.unlock() }
        return paths.filter { !box.done.contains($0) }
    }
}

/// Read-only filesystem scanner built on fts(3). Never follows symlinks, never opens file
/// contents, never materializes cloud-only content, never mutates anything.
public enum DiskScanner {
    static let SF_DATALESS_FLAG: UInt32 = 0x4000_0000
    static let maxRecordedErrors = 5_000
    static let packageSuffixes = [".app", ".bundle", ".framework", ".photoslibrary", ".xcarchive",
                                  ".plugin", ".appex", ".kext", ".xpc", ".musiclibrary", ".tvlibrary"]

    /// Async scan on a background thread. Cancelling the calling task stops the scan promptly
    /// and throws `CancellationError`.
    public static func scan(options: ScanOptions,
                            progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanResult {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ScanResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let r = try scanSync(options: options, isCancelled: { flag.isCancelled }, progress: progress)
                        cont.resume(returning: r)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    public static func scanSync(options: ScanOptions,
                                isCancelled: @escaping () -> Bool = { false },
                                progress: ((ScanProgress) -> Void)? = nil) throws -> ScanResult {
        let startedAt = Date()
        DatalessPolicy.disableMaterialization()
        let volumeBefore = VolumeInfo.snapshot(for: Platform.realHome)
        var missing: [String] = []
        var canonical: [String] = []
        var unreadableRoots: [(String, Int32)] = []
        for r in options.roots {
            let expanded = (r as NSString).expandingTildeInPath
            errno = 0
            if let c = realpath(expanded, nil) {
                canonical.append(String(cString: c)); free(c)
            } else if errno == ENOENT || errno == ENOTDIR || expanded.isEmpty {
                missing.append(r)
            } else {
                unreadableRoots.append((expanded, errno))   // exists but cannot be resolved: unknown, not missing
            }
        }
        let (effective, dropped) = PathUtil.deoverlap(canonical)
        let excluded = Set(options.excludedPaths.map { PathUtil.canonical($0) ?? $0 })

        // Opening a privacy-protected folder can block until the user answers a macOS consent
        // prompt. Probe those folders with a timeout first; any that don't answer are skipped and
        // reported as coverage gaps instead of hanging the scan.
        let candidates = PrivacyProbe.protectedFolders(home: Platform.realHome)
            .filter { p in effective.contains { PathUtil.isStrictlyInside(p, $0) } }
        let blocked = PrivacyProbe.unresponsive(candidates, timeout: options.privacyProbeTimeout)
            + options.assumeBlocked.map { PathUtil.canonical($0) ?? $0 }

        let walker = Walker(options: options, excluded: excluded, isCancelled: isCancelled, progress: progress)
        walker.blocked = Set(blocked)
        for (r, e) in unreadableRoots {
            walker.record(r, e)
            walker.stats.unreadableDirectories += 1
            walker.tree.append(ScanNode(name: r, parent: ScanTree.root, flags: [.directory, .unreadable], errorCount: 1))
        }
        for p in blocked {
            walker.errorCount += 1
            walker.errors.append(ScanError(path: p, errno: ETIMEDOUT,
                message: "Not scanned: macOS did not grant access within \(Int(options.privacyProbeTimeout)) s (privacy prompt pending or access denied). Size unknown, not zero."))
        }
        for (i, root) in effective.enumerated() {
            try walker.scanRoot(root, rootIndex: i, rootCount: effective.count)
        }
        walker.finalizeVirtualRoot()
        for p in blocked { Log.scan.notice("privacy-blocked, not scanned: \(p, privacy: .private)") }
        Log.scan.info("scan finished: \(effective.count) roots, \(walker.stats.filesVisited) files, \(walker.errorCount) unreadable entries, \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 1)) s")

        let manifest = ScanManifest(
            scanID: UUID(), startedAt: startedAt, finishedAt: Date(),
            requestedRoots: options.roots, effectiveRoots: effective.filter { !walker.aliasRoots.contains($0) },
            droppedOverlappingRoots: dropped + walker.aliasRoots,
            missingRoots: missing, options: options, stats: walker.stats, errors: walker.errors,
            errorCount: walker.errorCount, volumeBefore: volumeBefore, privacyBlockedPaths: blocked.sorted(),
            totalAllocated: walker.tree.totalAllocated, totalLogical: walker.tree.totalLogical,
            cancelled: false, hostName: ProcessInfo.processInfo.hostName,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            methodology: ScanManifest.methodologyText)
        return ScanResult(tree: walker.tree, manifest: manifest)
    }

    struct InodeKey: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    struct Frame {
        let id: Int32
        let level: Int
        var smallAlloc: Int64 = 0
        var smallLogical: Int64 = 0
        var smallFiles: Int64 = 0
        var smallEntries: Int64 = 0
        var errors: Int32 = 0
        var markers: ProjectMarkers = []
    }

    final class Walker {
        var tree = ScanTree()
        var stats = ScanStats()
        var errors: [ScanError] = []
        var errorCount = 0
        var seen = Set<InodeKey>()
        /// Directory identities already visited — catches firmlink/alias paths to the same folder.
        var seenDirs = Set<InodeKey>()
        var aliasRoots: [String] = []
        /// Privacy-blocked folders: recorded as unreadable nodes (unknown size), never entered.
        var blocked = Set<String>()
        let options: ScanOptions
        let excluded: Set<String>
        let isCancelled: () -> Bool
        let progress: ((ScanProgress) -> Void)?
        var entries: Int64 = 0
        var lastEmit = DispatchTime.now().uptimeNanoseconds
        var bytesSoFar: Int64 = 0

        init(options: ScanOptions, excluded: Set<String>, isCancelled: @escaping () -> Bool, progress: ((ScanProgress) -> Void)?) {
            self.options = options
            self.excluded = excluded
            self.isCancelled = isCancelled
            self.progress = progress
        }

        func record(_ path: String, _ err: Int32) {
            errorCount += 1
            if errors.count < DiskScanner.maxRecordedErrors {
                errors.append(ScanError(path: path, errno: err, message: String(cString: strerror(err))))
            }
        }

        @inline(__always)
        static func name(of ent: UnsafeMutablePointer<FTSENT>) -> String {
            let pathLen = Int(ent.pointee.fts_pathlen)
            let nameLen = Int(ent.pointee.fts_namelen)
            return String(cString: ent.pointee.fts_path + (pathLen - nameLen))
        }

        func finalize(_ frame: Frame) {
            if frame.smallEntries > 0 || frame.smallAlloc > 0 {
                let label = frame.smallFiles == 1 ? "‹1 smaller file›" : "‹\(frame.smallFiles) smaller items›"
                tree.append(ScanNode(name: label, parent: frame.id, flags: [.aggregate],
                                     logical: frame.smallLogical, allocated: frame.smallAlloc,
                                     fileCount: frame.smallFiles))
            }
            var a: Int64 = 0, l: Int64 = 0, c: Int64 = 0
            var e: Int32 = frame.errors
            for ch in tree.nodes[Int(frame.id)].children {
                let n = tree.nodes[Int(ch)]
                a += n.allocated; l += n.logical; c += n.fileCount; e += n.errorCount
            }
            tree.nodes[Int(frame.id)].allocated = a
            tree.nodes[Int(frame.id)].logical = l
            tree.nodes[Int(frame.id)].fileCount = c
            tree.nodes[Int(frame.id)].errorCount = e
            tree.nodes[Int(frame.id)].markers = frame.markers
            if e > 0 { tree.nodes[Int(frame.id)].flags.insert(.partial) }
        }

        func finalizeVirtualRoot() {
            var a: Int64 = 0, l: Int64 = 0, c: Int64 = 0, e: Int32 = 0
            for r in tree.nodes[0].children {
                let n = tree.nodes[Int(r)]
                a += n.allocated; l += n.logical; c += n.fileCount; e += n.errorCount
            }
            tree.nodes[0].allocated = a
            tree.nodes[0].logical = l
            tree.nodes[0].fileCount = c
            tree.nodes[0].errorCount = e
        }

        func emitProgress(_ ent: UnsafeMutablePointer<FTSENT>, root: String, rootIndex: Int, rootCount: Int, force: Bool = false) {
            guard let progress else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if !force && now - lastEmit < 100_000_000 { return }
            lastEmit = now
            progress(ScanProgress(entriesVisited: entries, filesVisited: stats.filesVisited,
                                  directoriesVisited: stats.directoriesVisited, bytesAllocated: bytesSoFar,
                                  errors: errorCount, currentPath: String(cString: ent.pointee.fts_path),
                                  currentRoot: root, rootIndex: rootIndex, rootCount: rootCount))
        }

        func scanRoot(_ root: String, rootIndex: Int, rootCount: Int) throws {
            guard let cpath = strdup(root) else { return }
            defer { free(cpath) }
            var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
            let fts: UnsafeMutablePointer<FTS>? = argv.withUnsafeMutableBufferPointer { buf in
                fts_open(buf.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR, nil)
            }
            guard let fts else {
                record(root, errno)
                return
            }
            defer { fts_close(fts) }

            var frames: [Frame] = []
            var rootDev: Int32 = 0

            while true {
                errno = 0
                guard let ent = fts_read(fts) else {
                    if errno != 0 { record(root, errno) }
                    break
                }
                entries += 1
                if entries & 1023 == 0 {
                    if isCancelled() { throw CancellationError() }
                    emitProgress(ent, root: root, rootIndex: rootIndex, rootCount: rootCount)
                }
                let info = Int32(ent.pointee.fts_info)
                let level = Int(ent.pointee.fts_level)

                switch info {
                case FTS_D:
                    let st = ent.pointee.fts_statp.pointee
                    if level == 0 { rootDev = st.st_dev }
                    let path = level == 0 ? root : String(cString: ent.pointee.fts_path)
                    if level > 0 && excluded.contains(path) {
                        fts_set(fts, ent, FTS_SKIP)   // its FTS_DP is ignored below (no frame)
                        continue
                    }
                    if !seenDirs.insert(InodeKey(dev: st.st_dev, ino: UInt64(st.st_ino))).inserted {
                        // Same directory reached again through another path (firmlink/alias root).
                        if level == 0 { aliasRoots.append(root) }
                        fts_set(fts, ent, FTS_SKIP)
                        continue
                    }
                    if level > 0 && blocked.contains(path) {
                        let id = tree.append(ScanNode(name: Walker.name(of: ent), parent: frames.last?.id ?? ScanTree.root,
                                                      flags: [.directory, .unreadable], errorCount: 0,
                                                      mtime: Int64(st.st_mtimespec.tv_sec), device: st.st_dev, inode: UInt64(st.st_ino)))
                        stats.unreadableDirectories += 1
                        frames.append(Frame(id: id, level: level, errors: 1))
                        fts_set(fts, ent, FTS_SKIP)   // FTS_DP pops the frame and propagates .partial
                        continue
                    }
                    let name = level == 0 ? root : Walker.name(of: ent)
                    if level > 0, !frames.isEmpty { frames[frames.count - 1].markers.formUnion(ProjectMarkers.forDirectory(name)) }
                    let parentID = level == 0 ? ScanTree.root : (frames.last?.id ?? ScanTree.root)
                    var flags: NodeFlags = [.directory]
                    let lower = name.lowercased()
                    if DiskScanner.packageSuffixes.contains(where: { lower.hasSuffix($0) }) { flags.insert(.package) }
                    let id = tree.append(ScanNode(name: name, parent: parentID, flags: flags,
                                                  mtime: Int64(st.st_mtimespec.tv_sec), device: st.st_dev,
                                                  inode: UInt64(st.st_ino)))
                    stats.directoriesVisited += 1
                    var frame = Frame(id: id, level: level)
                    frame.smallAlloc += Int64(st.st_blocks) * 512   // directory metadata blocks
                    bytesSoFar += Int64(st.st_blocks) * 512
                    frames.append(frame)
                    if level > 0 && (st.st_flags & DiskScanner.SF_DATALESS_FLAG) != 0 {
                        // Cloud-only folder: listing it would download its contents. Record, don't enter.
                        tree.nodes[Int(id)].flags.insert(.dataless)
                        stats.datalessDirectories += 1
                        frames[frames.count - 1].smallAlloc = 0
                        fts_set(fts, ent, FTS_SKIP)
                    } else if options.stayOnDevice && level > 0 && st.st_dev != rootDev {
                        tree.nodes[Int(id)].flags.insert(.mountBoundary)
                        stats.mountPointsNotCrossed += 1
                        frames[frames.count - 1].smallAlloc = 0
                        fts_set(fts, ent, FTS_SKIP)
                    }

                case FTS_DP:
                    guard let top = frames.last, top.level == level else { continue }
                    frames.removeLast()
                    finalize(top)

                case FTS_DNR:
                    let err = ent.pointee.fts_errno
                    let path = level == 0 ? root : String(cString: ent.pointee.fts_path)
                    record(path, err)
                    stats.unreadableDirectories += 1
                    if var top = frames.last, top.level == level {
                        frames.removeLast()
                        tree.nodes[Int(top.id)].flags.insert(.unreadable)
                        top.errors += 1
                        top.smallAlloc = 0
                        finalize(top)
                    } else {
                        let parentID = frames.last?.id ?? ScanTree.root
                        let id = tree.append(ScanNode(name: level == 0 ? root : Walker.name(of: ent), parent: parentID,
                                                      flags: [.directory, .unreadable]))
                        finalize(Frame(id: id, level: level, errors: 1))
                    }

                case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                    let st = ent.pointee.fts_statp.pointee
                    let alloc = Int64(st.st_blocks) * 512
                    let logical = Int64(st.st_size)
                    if level == 0 || frames.isEmpty {
                        // A scan root that is itself a file.
                        if info == FTS_F && st.st_nlink > 1 && !seen.insert(InodeKey(dev: st.st_dev, ino: UInt64(st.st_ino))).inserted {
                            stats.hardLinkDuplicatesSkipped += 1
                            continue
                        }
                        var flags: NodeFlags = []
                        if info == FTS_F {
                            stats.filesVisited += 1
                            if (st.st_flags & DiskScanner.SF_DATALESS_FLAG) != 0 { stats.datalessFiles += 1; flags.insert(.dataless) }
                            if logical > alloc * 2 && logical >= 64 << 20 { flags.insert(.sparse) }
                        }
                        tree.append(ScanNode(name: root, parent: ScanTree.root, flags: flags, logical: logical,
                                             allocated: alloc, fileCount: info == FTS_F ? 1 : 0,
                                             mtime: Int64(st.st_mtimespec.tv_sec), device: st.st_dev, inode: UInt64(st.st_ino)))
                        bytesSoFar += alloc
                        continue
                    }
                    let fi = frames.count - 1
                    if ent.pointee.fts_namelen < 32 {
                        let m = ProjectMarkers.forFile(Walker.name(of: ent))
                        if !m.isEmpty { frames[fi].markers.formUnion(m) }
                    }
                    if info == FTS_F {
                        if st.st_nlink > 1 {
                            let key = InodeKey(dev: st.st_dev, ino: UInt64(st.st_ino))
                            if !seen.insert(key).inserted {
                                stats.hardLinkDuplicatesSkipped += 1
                                continue
                            }
                        }
                        stats.filesVisited += 1
                        bytesSoFar += alloc
                        let dataless = (st.st_flags & DiskScanner.SF_DATALESS_FLAG) != 0
                        if dataless { stats.datalessFiles += 1 }
                        if max(alloc, logical) >= options.fileNodeThreshold {
                            var flags: NodeFlags = []
                            if logical > alloc * 2 && logical >= 64 << 20 { flags.insert(.sparse) }
                            if dataless { flags.insert(.dataless) }
                            tree.append(ScanNode(name: Walker.name(of: ent), parent: frames[fi].id, flags: flags,
                                                 logical: logical, allocated: alloc, fileCount: 1,
                                                 mtime: Int64(st.st_mtimespec.tv_sec), device: st.st_dev,
                                                 inode: UInt64(st.st_ino)))
                        } else {
                            frames[fi].smallAlloc += alloc
                            frames[fi].smallLogical += logical
                            frames[fi].smallFiles += 1
                            frames[fi].smallEntries += 1
                        }
                    } else {
                        if info == FTS_SL || info == FTS_SLNONE { stats.symlinksNotFollowed += 1 } else { stats.otherFileTypes += 1 }
                        bytesSoFar += alloc
                        frames[fi].smallAlloc += alloc
                        frames[fi].smallLogical += logical
                        frames[fi].smallEntries += 1
                    }

                case FTS_NS, FTS_ERR:
                    let err = ent.pointee.fts_errno
                    let path = String(cString: ent.pointee.fts_path)
                    record(path, err)
                    stats.statFailures += 1
                    if !frames.isEmpty { frames[frames.count - 1].errors += 1 }

                default:
                    continue   // FTS_DC (cycles cannot occur with FTS_PHYSICAL), FTS_DOT, FTS_NSOK
                }
            }
            // Defensive: close any frames left open (should not happen).
            while let top = frames.popLast() { finalize(top) }
        }
    }
}
