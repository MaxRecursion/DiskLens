import Foundation

/// Markdown/JSON reports (Pro). Contains measured sizes, paths, recommendations and cleanup
/// results only — never file contents, host names, user names or process command lines.
public enum ReportExporter {
    public struct Report: Codable, Sendable {
        public struct Volume: Codable, Sendable {
            public var name: String
            public var capacityBytes: Int64
            public var usedBytes: Int64
            public var availableBytes: Int64
            public var purgeableBytes: Int64
            public var measuredAt: Date
        }
        public struct Category: Codable, Sendable {
            public var category: String
            public var allocatedBytes: Int64?
            public var files: Int64
        }
        public struct Folder: Codable, Sendable {
            public var path: String
            public var allocatedBytes: Int64
        }
        public struct Item: Codable, Sendable {
            public var id: String
            public var title: String
            public var path: String
            public var tier: Int
            public var risk: String
            public var confidence: String
            public var pack: String
            public var detectedBytes: Int64
            public var estimatedReclaimableBytes: Int64
            public var reclaimMethod: String
            public var action: String
            public var inUseBy: [String]
            public var reason: String
        }
        public struct Coverage: Codable, Sendable {
            public var unreadableFolders: Int64
            public var errorCount: Int
            public var privacyBlocked: [String]
            public var cloudOnlyFilesNotDownloaded: Int64
            public var symlinksNotFollowed: Int64
            public var hardLinkDuplicatesSkipped: Int64
        }
        public struct Cleanup: Codable, Sendable {
            public var finishedAt: Date
            public var dryRun: Bool
            public var measuredFreeSpaceDeltaBytes: Int64?
            public var estimatedBytes: Int64
            public var succeeded: Int
            public var skipped: Int
            public var failed: Int
        }

        public var format = "disklens-report/1"
        public var generatedAt: Date
        public var appVersion: String
        public var scanID: UUID
        public var scanFinishedAt: Date
        public var scanDurationSeconds: Double
        public var roots: [String]
        public var scannedAllocatedBytes: Int64
        public var scannedLogicalBytes: Int64
        public var files: Int64
        public var volume: Volume?
        public var categories: [Category]
        public var largestFolders: [Folder]
        public var coverage: Coverage
        public var estimatedReclaimableBytes: Int64
        public var recommendations: [Item]
        public var changesSincePreviousScan: [ScanChange]
        public var cleanups: [Cleanup]
        public var history: [ScanHistoryEntry]
    }

    public static func build(scan: ScanResult, recommendations: [Recommendation], changes: [ScanChange],
                             cleanups: [CleanupReport], history: [ScanHistoryEntry], appVersion: String,
                             now: Date = Date(), topFolders: Int = 25) -> Report {
        let t = scan.tree, m = scan.manifest
        let cats = t.categoryTotals().sorted { $0.value.allocated > $1.value.allocated }.map { c, v in
            Report.Category(category: c.displayName, allocatedBytes: c == .inaccessible ? nil : v.allocated, files: v.files)
        }
        var folders: [(Int32, Int64)] = []
        t.walk { id, n in
            guard id != ScanTree.root, n.isDirectory else { return true }
            let d = t.depth(of: id)
            if d >= 2 { folders.append((id, n.allocated)) }
            return d < 4
        }
        let listed = Set(folders.map(\.0))
        let largest = folders.filter { id, a in
            let p = t.nodes[Int(id)].parent
            return !(listed.contains(p) && Double(a) >= 0.95 * Double(t.nodes[Int(p)].allocated))
        }.sorted { $0.1 > $1.1 }.prefix(topFolders).map { Report.Folder(path: t.path(of: $0.0), allocatedBytes: $0.1) }
        let items = recommendations.sorted { ($0.tier, -$0.estimatedReclaimable) < ($1.tier, -$1.estimatedReclaimable) }.map {
            Report.Item(id: $0.id, title: $0.title, path: $0.targetPath, tier: $0.tier.rawValue, risk: $0.risk.rawValue,
                        confidence: $0.confidence.rawValue, pack: $0.pack.rawValue, detectedBytes: $0.detectedAllocated,
                        estimatedReclaimableBytes: $0.estimatedReclaimable, reclaimMethod: $0.reclaimMethod,
                        action: $0.action.displayString, inUseBy: $0.inUseBy, reason: $0.reason)
        }
        let vol = m.volumeBefore.map {
            Report.Volume(name: $0.volumeName, capacityBytes: $0.totalBytes, usedBytes: $0.usedBytes, availableBytes: $0.availableBytes,
                          purgeableBytes: $0.purgeableBytes, measuredAt: $0.takenAt)
        }
        return Report(generatedAt: now, appVersion: appVersion, scanID: m.scanID, scanFinishedAt: m.finishedAt,
                      scanDurationSeconds: m.duration, roots: m.effectiveRoots, scannedAllocatedBytes: t.totalAllocated,
                      scannedLogicalBytes: t.totalLogical, files: t.nodes[0].fileCount, volume: vol, categories: cats,
                      largestFolders: Array(largest),
                      coverage: Report.Coverage(unreadableFolders: m.stats.unreadableDirectories, errorCount: m.errorCount,
                                                privacyBlocked: m.privacyBlockedPaths, cloudOnlyFilesNotDownloaded: m.stats.datalessFiles,
                                                symlinksNotFollowed: m.stats.symlinksNotFollowed,
                                                hardLinkDuplicatesSkipped: m.stats.hardLinkDuplicatesSkipped),
                      estimatedReclaimableBytes: recommendations.filter { !$0.requiresManualReview }.reduce(0) { $0 + $1.estimatedReclaimable },
                      recommendations: items, changesSincePreviousScan: changes,
                      cleanups: cleanups.map { Report.Cleanup(finishedAt: $0.finishedAt, dryRun: $0.dryRun,
                                                              measuredFreeSpaceDeltaBytes: $0.measuredFreeSpaceDelta,
                                                              estimatedBytes: $0.estimatedTotal, succeeded: $0.succeeded.count,
                                                              skipped: $0.skipped.count, failed: $0.failed.count) },
                      history: history)
    }

    public static func json(_ r: Report) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(r)
    }

    static func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }

    public static func markdown(_ r: Report, home: String = Platform.realHome) -> String {
        func p(_ s: String) -> String { cell(PathUtil.abbreviated(s, home: home)) }
        let df = ISO8601DateFormatter()
        var s = "# DiskLens report\n\n"
        s += "Generated \(df.string(from: r.generatedAt)) by DiskLens \(r.appVersion) · scan `\(r.scanID.uuidString.prefix(8))` finished \(df.string(from: r.scanFinishedAt)) in \(String(format: "%.1f", r.scanDurationSeconds)) s.\n\n"
        s += "All sizes are measured unless marked **estimate**. Unknown sizes are shown as *unknown*, never as zero.\n\n"
        s += "## Disk\n\n| | |\n|---|---:|\n"
        if let v = r.volume {
            s += "| Capacity | \(ByteFormat.gb(v.capacityBytes)) |\n| Used | \(ByteFormat.gb(v.usedBytes)) |\n"
            s += "| Available | \(ByteFormat.gb(v.availableBytes)) (+\(ByteFormat.gb(v.purgeableBytes)) purgeable per macOS) |\n"
        }
        s += "| Scanned (allocated) | \(ByteFormat.gb(r.scannedAllocatedBytes)) in \(r.files.formatted()) files |\n"
        s += "| Reclaimable (tier 1 + 2) | \(ByteFormat.gb(r.estimatedReclaimableBytes)) **estimate** (APFS private size) |\n\n"
        s += "Roots: " + r.roots.map { "`\(p($0))`" }.joined(separator: ", ") + "\n\n"
        s += "## Categories (each byte counted once)\n\n| Category | Size | Files |\n|---|---:|---:|\n"
        for c in r.categories { s += "| \(c.category) | \(c.allocatedBytes.map(ByteFormat.gb) ?? "unknown") | \(c.files.formatted()) |\n" }
        s += "\n## Largest folders\n\n| Size | Folder |\n|---:|---|\n"
        for f in r.largestFolders { s += "| \(ByteFormat.gb(f.allocatedBytes)) | `\(p(f.path))` |\n" }
        s += "\n## Recommendations\n\n"
        for tier in 1...3 {
            let items = r.recommendations.filter { $0.tier == tier }
            guard !items.isEmpty else { continue }
            let label = CleanupTier(rawValue: tier)!.label
            s += "### \(label) — \(items.count) items, \(ByteFormat.gb(items.reduce(0) { $0 + $1.estimatedReclaimableBytes })) estimate\n\n"
            s += "| Estimate | On disk | Risk | Item | Exact action | In use |\n|---:|---:|---|---|---|---|\n"
            for i in items {
                s += "| \(ByteFormat.gb(i.estimatedReclaimableBytes)) | \(ByteFormat.gb(i.detectedBytes)) | \(i.risk) | \(cell(i.title)) | `\(cell(i.action.replacingOccurrences(of: home + "/", with: "~/")))` | \(cell(i.inUseBy.joined(separator: ", "))) |\n"
            }
            s += "\n"
        }
        if !r.changesSincePreviousScan.isEmpty {
            s += "## Changes since the previous scan\n\n| Change | Folder |\n|---:|---|\n"
            for c in r.changesSincePreviousScan { s += "| \(c.delta >= 0 ? "+" : "")\(ByteFormat.string(c.delta)) | `\(p(c.path))` |\n" }
            s += "\n"
        }
        s += "## Coverage gaps\n\n"
        s += "- \(r.coverage.unreadableFolders) unreadable folders, \(r.coverage.errorCount) unreadable entries — sizes unknown, not zero.\n"
        for b in r.coverage.privacyBlocked { s += "- Not scanned (privacy prompt pending or denied): `\(p(b))`\n" }
        s += "- \(r.coverage.cloudOnlyFilesNotDownloaded.formatted()) cloud-only files were not downloaded; \(r.coverage.symlinksNotFollowed.formatted()) symbolic links were not followed; \(r.coverage.hardLinkDuplicatesSkipped.formatted()) extra hard links were counted once.\n\n"
        if !r.cleanups.isEmpty {
            s += "## Cleanups\n\n| Date | Kind | Free-space change (measured) | Estimate | Done / skipped / failed |\n|---|---|---:|---:|---|\n"
            for c in r.cleanups {
                s += "| \(df.string(from: c.finishedAt)) | \(c.dryRun ? "dry run" : "executed") | \(c.measuredFreeSpaceDeltaBytes.map { ($0 >= 0 ? "+" : "") + ByteFormat.string($0) } ?? "n/a") | \(ByteFormat.gb(c.estimatedBytes)) | \(c.succeeded) / \(c.skipped) / \(c.failed) |\n"
            }
            s += "\n"
        }
        if !r.history.isEmpty {
            s += "## Scan history\n\n| Date | Scanned | Available | Gaps |\n|---|---:|---:|---:|\n"
            for h in r.history {
                s += "| \(df.string(from: h.finishedAt)) | \(ByteFormat.gb(h.scannedAllocated)) | \(h.availableBytes.map(ByteFormat.gb) ?? "n/a") | \(h.coverageGaps) |\n"
            }
            s += "\n"
        }
        return s
    }
}
