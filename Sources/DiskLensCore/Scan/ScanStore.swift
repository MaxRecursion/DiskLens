import Foundation

/// Compact per-directory size summary kept between scans for change detection, including what was
/// NOT measured so that differences in coverage are never reported as growth or shrinkage.
public struct ScanSummary: Codable, Sendable {
    public var scanID: UUID
    public var finishedAt: Date
    /// path -> allocated bytes, for directories >= `minBytes`.
    public var sizes: [String: Int64]
    public var minBytes: Int64
    public var roots: [String]
    /// Unreadable, privacy-blocked, cloud-only, excluded or mount-point folders (size unknown).
    public var unknownPaths: [String]

    public init(scanID: UUID, finishedAt: Date, sizes: [String: Int64], minBytes: Int64, roots: [String], unknownPaths: [String]) {
        self.scanID = scanID; self.finishedAt = finishedAt; self.sizes = sizes
        self.minBytes = minBytes; self.roots = roots; self.unknownPaths = unknownPaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scanID = try c.decode(UUID.self, forKey: .scanID)
        finishedAt = try c.decode(Date.self, forKey: .finishedAt)
        sizes = try c.decode([String: Int64].self, forKey: .sizes)
        minBytes = try c.decodeIfPresent(Int64.self, forKey: .minBytes) ?? 10_000_000
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? []
        unknownPaths = try c.decodeIfPresent([String].self, forKey: .unknownPaths) ?? []
    }

    public static func make(from tree: ScanTree, manifest: ScanManifest? = nil, scanID: UUID, finishedAt: Date,
                            minBytes: Int64 = 10_000_000) -> ScanSummary {
        var sizes: [String: Int64] = [:]
        var unknown: [String] = []
        tree.walk { id, n in
            guard id != ScanTree.root else { return true }
            if n.isDirectory && !n.flags.isDisjoint(with: [.unreadable, .dataless, .mountBoundary]) {
                unknown.append(tree.path(of: id))
            }
            guard n.isDirectory, n.allocated >= minBytes || !n.flags.isDisjoint(with: [.unreadable, .partial]) else { return false }
            if n.allocated >= minBytes { sizes[tree.path(of: id)] = n.allocated }
            return true
        }
        if let manifest {
            unknown += manifest.privacyBlockedPaths
            unknown += manifest.options.excludedPaths.map { PathUtil.canonical($0) ?? $0 }
        }
        return ScanSummary(scanID: scanID, finishedAt: finishedAt, sizes: sizes, minBytes: minBytes,
                           roots: tree.rootIDs.map { tree.nodes[Int($0)].name }, unknownPaths: Array(Set(unknown)).sorted())
    }
}

public struct ScanChange: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var before: Int64
    public var after: Int64
    /// True when the folder was below the summary threshold on that side (value is an upper bound).
    public var beforeIsBelowThreshold: Bool = false
    public var afterIsBelowThreshold: Bool = false
    public var delta: Int64 { after - before }
}

public enum ScanDiff {
    /// Folders not scanned this time (privacy-blocked or excluded) — and their ancestors — would
    /// show fake shrinkage, so their changes are not reported.
    public static func excludingUnscanned(_ changes: [ScanChange], manifest: ScanManifest) -> [ScanChange] {
        let skipped = manifest.privacyBlockedPaths + manifest.options.excludedPaths
        return changes.filter { c in
            !skipped.contains { PathUtil.isSameOrInside(c.path, $0) || PathUtil.isStrictlyInside($0, c.path) }
        }
    }

    /// Most specific directories whose size changed by at least `threshold` bytes, restricted to what
    /// was measured the same way in both scans: inside roots common to both, outside any unknown
    /// folder, and not an ancestor of a folder whose coverage changed between the scans.
    public static func changes(previous: ScanSummary, current: ScanSummary, threshold: Int64 = 100_000_000, limit: Int = 40) -> [ScanChange] {
        let commonRoots = previous.roots.isEmpty || current.roots.isEmpty ? nil : Set(previous.roots).intersection(current.roots)
        let prevUnknown = Set(previous.unknownPaths), curUnknown = Set(current.unknownPaths)
        let allUnknown = prevUnknown.union(curUnknown)
        let changedCoverage = prevUnknown.symmetricDifference(curUnknown)
        func comparable(_ p: String) -> Bool {
            if let commonRoots, !commonRoots.contains(where: { PathUtil.isSameOrInside(p, $0) }) { return false }
            if allUnknown.contains(where: { PathUtil.isSameOrInside(p, $0) }) { return false }
            if changedCoverage.contains(where: { PathUtil.isStrictlyInside($0, p) }) { return false }
            return true
        }
        var cands: [String: ScanChange] = [:]
        for path in Set(previous.sizes.keys).union(current.sizes.keys) where comparable(path) {
            let b = previous.sizes[path], a = current.sizes[path]
            let change = ScanChange(path: path, before: b ?? 0, after: a ?? 0,
                                    beforeIsBelowThreshold: b == nil, afterIsBelowThreshold: a == nil)
            if abs(change.delta) >= threshold { cands[path] = change }
        }
        // Drop a candidate when one of its descendants explains >= 80% of its change.
        let paths = cands.keys.sorted()
        var explained = Set<String>()
        for p in paths {
            guard let c = cands[p] else { continue }
            let prefix = p + "/"
            for q in paths where q.hasPrefix(prefix) {
                if let d = cands[q], (d.delta >= 0) == (c.delta >= 0), Double(abs(d.delta)) >= 0.8 * Double(abs(c.delta)) {
                    explained.insert(p); break
                }
            }
        }
        return cands.values.filter { !explained.contains($0.path) }
            .sorted { abs($0.delta) > abs($1.delta) }
            .prefix(limit).map { $0 }
    }
}

/// One line of the scan history: measured totals only (no tree), so it stays small.
public struct ScanHistoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID { scanID }
    public var scanID: UUID
    public var finishedAt: Date
    public var duration: TimeInterval
    public var roots: [String]
    public var scannedAllocated: Int64
    public var files: Int64
    /// Free space measured when the scan started (statfs), if available.
    public var availableBytes: Int64?
    public var capacityBytes: Int64?
    /// Unreadable/privacy-blocked entries (coverage gaps) — sizes unknown.
    public var coverageGaps: Int
    public var changeCount: Int

    public init(_ r: ScanResult, changeCount: Int) {
        scanID = r.manifest.scanID
        finishedAt = r.manifest.finishedAt
        duration = r.manifest.duration
        roots = r.manifest.effectiveRoots
        scannedAllocated = r.tree.totalAllocated
        files = r.tree.nodes[0].fileCount
        availableBytes = r.manifest.volumeBefore?.availableBytes
        capacityBytes = r.manifest.volumeBefore?.totalBytes
        coverageGaps = r.manifest.errorCount
        self.changeCount = changeCount
    }
}

/// Persists scans in ~/Library/Application Support/DiskLens. Only DiskLens's own files are
/// written there; scan data contains paths and sizes, never file contents.
public struct ScanStore: Sendable {
    public var directory: URL

    public init(directory: URL? = nil) {
        if let directory { self.directory = directory } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = base.appendingPathComponent("DiskLens", isDirectory: true)
        }
    }

    var latestTree: URL { directory.appendingPathComponent("latest-tree.json") }
    var latestManifest: URL { directory.appendingPathComponent("latest-manifest.json") }
    var latestSummary: URL { directory.appendingPathComponent("latest-summary.json") }
    var previousSummary: URL { directory.appendingPathComponent("previous-summary.json") }
    var reportsDir: URL { directory.appendingPathComponent("reports", isDirectory: true) }
    var historyFile: URL { directory.appendingPathComponent("scan-history.json") }
    /// Number of past scans kept in the history index.
    public static let historyLimit = 200

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Saves a scan; rotates the previous summary for change detection. Returns changes since
    /// the previous scan (empty on first scan).
    @discardableResult
    public func save(_ result: ScanResult) throws -> [ScanChange] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let summary = ScanSummary.make(from: result.tree, manifest: result.manifest, scanID: result.manifest.scanID,
                                       finishedAt: result.manifest.finishedAt)
        var changes: [ScanChange] = []
        if let data = try? Data(contentsOf: latestSummary),
           let prev = try? ScanStore.decoder().decode(ScanSummary.self, from: data) {
            changes = ScanDiff.excludingUnscanned(ScanDiff.changes(previous: prev, current: summary), manifest: result.manifest)
            try? FileManager.default.removeItem(at: previousSummary)
            try FileManager.default.moveItem(at: latestSummary, to: previousSummary)
        }
        let enc = ScanStore.encoder()
        try enc.encode(result.tree).write(to: latestTree, options: .atomic)
        try enc.encode(result.manifest).write(to: latestManifest, options: .atomic)
        try enc.encode(summary).write(to: latestSummary, options: .atomic)
        try? appendHistory(ScanHistoryEntry(result, changeCount: changes.count))
        return changes
    }

    /// Past scans, newest first (recorded for everyone; browsing the history is a Pro feature).
    public func loadHistory() -> [ScanHistoryEntry] {
        guard let d = try? Data(contentsOf: historyFile),
              let h = try? ScanStore.decoder().decode([ScanHistoryEntry].self, from: d) else { return [] }
        return h.sorted { $0.finishedAt > $1.finishedAt }
    }

    func appendHistory(_ entry: ScanHistoryEntry) throws {
        var h = loadHistory().filter { $0.scanID != entry.scanID }
        h.insert(entry, at: 0)
        try ScanStore.encoder().encode(Array(h.prefix(ScanStore.historyLimit))).write(to: historyFile, options: .atomic)
    }

    public func loadLatest() -> ScanResult? {
        let dec = ScanStore.decoder()
        guard let t = try? Data(contentsOf: latestTree), let m = try? Data(contentsOf: latestManifest),
              let tree = try? dec.decode(ScanTree.self, from: t), let manifest = try? dec.decode(ScanManifest.self, from: m)
        else { return nil }
        return ScanResult(tree: tree, manifest: manifest)
    }

    public func changesSincePrevious() -> [ScanChange] {
        let dec = ScanStore.decoder()
        guard let a = try? Data(contentsOf: previousSummary), let b = try? Data(contentsOf: latestSummary),
              let prev = try? dec.decode(ScanSummary.self, from: a), let cur = try? dec.decode(ScanSummary.self, from: b)
        else { return [] }
        let changes = ScanDiff.changes(previous: prev, current: cur)
        guard let m = try? Data(contentsOf: latestManifest), let manifest = try? dec.decode(ScanManifest.self, from: m) else { return changes }
        return ScanDiff.excludingUnscanned(changes, manifest: manifest)
    }

    public func saveReport(_ report: CleanupReport) throws -> URL {
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
        let f = reportsDir.appendingPathComponent("cleanup-\(Int(report.finishedAt.timeIntervalSince1970)).json")
        let e = ScanStore.encoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(report).write(to: f, options: .atomic)
        return f
    }

    public func loadReports() -> [CleanupReport] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { try? ScanStore.decoder().decode(CleanupReport.self, from: Data(contentsOf: $0)) }
            .sorted { $0.finishedAt > $1.finishedAt }
    }
}
