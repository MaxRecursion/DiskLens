#if DISKLENS_SNAPSHOTS
import Foundation
import DiskLensCore

/// A synthetic but realistic developer Mac used for App Store screenshots and demos, so no real
/// user's folder names, photos or projects ever appear in marketing material. The real classifier
/// and rule engine run over it.
enum DemoData {
    static let home = "/Users/alex"

    struct Result {
        var scan: ScanResult
        var volume: VolumeSnapshot
        var recommendations: [Recommendation]
        var history: [ScanHistoryEntry] = []
    }

    final class Builder {
        var tree = ScanTree()
        var nextInode: UInt64 = 1000

        @discardableResult
        func dir(_ name: String, in parent: Int32, markers: ProjectMarkers = [], flags: NodeFlags = []) -> Int32 {
            nextInode += 1
            var n = ScanNode(name: name, parent: parent, flags: NodeFlags.directory.union(flags), mtime: 1_759_000_000, device: 1, inode: nextInode)
            n.markers = markers
            return tree.append(n)
        }

        func file(_ name: String, in parent: Int32, gb: Double, logicalGB: Double? = nil) {
            nextInode += 1
            let a = Int64(gb * 1e9)
            tree.append(ScanNode(name: name, parent: parent, flags: [], logical: Int64((logicalGB ?? gb) * 1e9), allocated: a,
                                 fileCount: 1, mtime: 1_759_000_000, device: 1, inode: nextInode))
        }

        func many(_ count: Int, in parent: Int32, gb: Double) {
            tree.append(ScanNode(name: "‹\(count) smaller items›", parent: parent, flags: [.aggregate],
                                 logical: Int64(gb * 1e9), allocated: Int64(gb * 1e9), fileCount: Int64(count)))
        }

        /// Directory totals bottom-up (parents always precede children in the arena).
        func finalize() {
            for i in stride(from: tree.nodes.count - 1, through: 1, by: -1) where tree.nodes[i].isDirectory && !tree.nodes[i].children.isEmpty {
                var a: Int64 = 0, l: Int64 = 0, f: Int64 = 0
                for c in tree.nodes[i].children {
                    a += tree.nodes[Int(c)].allocated; l += tree.nodes[Int(c)].logical; f += tree.nodes[Int(c)].fileCount
                }
                tree.nodes[i].allocated = a; tree.nodes[i].logical = l; tree.nodes[i].fileCount = f
            }
            var a: Int64 = 0, l: Int64 = 0, f: Int64 = 0
            for r in tree.rootIDs { a += tree.nodes[Int(r)].allocated; l += tree.nodes[Int(r)].logical; f += tree.nodes[Int(r)].fileCount }
            tree.nodes[0].allocated = a; tree.nodes[0].logical = l; tree.nodes[0].fileCount = f
        }
    }

    static func make() -> Result {
        let b = Builder()
        let h = b.dir(home, in: ScanTree.root)

        // ~/Library
        let lib = b.dir("Library", in: h)
        let caches = b.dir("Caches", in: lib)
        let brew = b.dir("Homebrew", in: caches); b.many(840, in: brew, gb: 1.6)
        let pip = b.dir("pip", in: caches); b.many(2_100, in: pip, gb: 0.9)
        let pw = b.dir("ms-playwright", in: caches)
        let c1 = b.dir("chromium-1208", in: pw); b.many(400, in: c1, gb: 0.36)
        let c2 = b.dir("chromium-1243", in: pw); b.many(400, in: c2, gb: 0.38)
        let slackU = b.dir("com.tinyspeck.slackmacgap.ShipIt", in: caches); b.file("update.zip", in: slackU, gb: 0.42)
        b.many(9_000, in: caches, gb: 2.3)
        let asup = b.dir("Application Support", in: lib)
        let code = b.dir("Code", in: asup)
        let codeCache = b.dir("Cache", in: code); b.many(3_000, in: codeCache, gb: 0.62)
        let cd = b.dir("CachedData", in: code); b.many(1_200, in: cd, gb: 0.48)
        b.many(5_000, in: code, gb: 0.9)
        let slack = b.dir("Slack", in: asup)
        let sc = b.dir("Cache", in: slack); b.many(2_000, in: sc, gb: 0.71)
        b.many(1_000, in: slack, gb: 0.4)
        let docker = b.dir("Docker Desktop", in: asup); b.many(200, in: docker, gb: 0.3)
        b.many(30_000, in: asup, gb: 4.1)
        let dev = b.dir("Developer", in: lib)
        let xc = b.dir("Xcode", in: dev)
        let dd = b.dir("DerivedData", in: xc); b.many(48_000, in: dd, gb: 7.4)
        let cs = b.dir("CoreSimulator", in: dev); b.many(60_000, in: cs, gb: 14.2)
        let cont = b.dir("Containers", in: lib); b.many(12_000, in: cont, gb: 3.4)
        if Platform.isSandboxed {
            b.dir("Mail", in: lib, flags: [.unreadable])            // protected even inside a granted Home
        } else {
            let mail = b.dir("Mail", in: lib); b.many(40_000, in: mail, gb: 2.2)
        }

        // Developer caches
        let npm = b.dir(".npm", in: h)
        let cacache = b.dir("_cacache", in: npm); b.many(26_000, in: cacache, gb: 3.8)
        let npx = b.dir("_npx", in: npm)
        let n1 = b.dir("4f1c2a9b8e7d6c5a", in: npx); b.many(3_000, in: n1, gb: 0.21)
        let colima = b.dir(".colima", in: h)
        let lima = b.dir("_lima", in: colima); b.file("datadisk", in: lima, gb: 11.6, logicalGB: 107.4)
        let cache = b.dir(".cache", in: h)
        let hf = b.dir("huggingface", in: cache)
        b.file("llama-3-8b-instruct.Q5_K_M.gguf", in: hf, gb: 5.7)
        b.file("whisper-large-v3.safetensors", in: hf, gb: 3.1)
        let nuget = b.dir(".nuget", in: h); b.many(52_000, in: nuget, gb: 2.6)

        // Projects
        let proj = b.dir("Projects", in: h)
        let web = b.dir("storefront-web", in: proj, markers: [.packageJSON, .npmLock, .gitRepo])
        let nm = b.dir("node_modules", in: web); b.many(61_000, in: nm, gb: 1.35)
        let next = b.dir(".next", in: web); b.many(4_000, in: next, gb: 0.62)
        let wgit = b.dir(".git", in: web); b.many(9_000, in: wgit, gb: 0.48)
        b.many(1_800, in: web, gb: 0.12)
        let api = b.dir("orders-api", in: proj, markers: [.dotnetProject, .gitRepo])
        let bin = b.dir("bin", in: api); b.many(900, in: bin, gb: 0.41)
        let obj = b.dir("obj", in: api); b.many(1_600, in: obj, gb: 0.57)
        b.many(700, in: api, gb: 0.05)
        let ml = b.dir("vision-experiments", in: proj, markers: [.pythonManifest, .gitRepo])
        let venv = b.dir(".venv", in: ml, markers: [.pyvenvCfg]); b.many(38_000, in: venv, gb: 2.9)
        b.file("training-set.parquet", in: ml, gb: 1.8)
        let mob = b.dir("field-app", in: proj, markers: [.packageJSON, .yarnLock])
        let mnm = b.dir("node_modules", in: mob); b.many(70_000, in: mnm, gb: 1.1)

        // Personal content
        let movies = b.dir("Movies", in: h)
        b.file("Iceland-trip-4K.mov", in: movies, gb: 8.4)
        b.file("Conference-talk.mp4", in: movies, gb: 2.6)
        let pics = b.dir("Pictures", in: h); b.many(14_000, in: pics, gb: 9.8)
        let docs = b.dir("Documents", in: h); b.many(6_200, in: docs, gb: 3.9)
        let dl = b.dir("Downloads", in: h)
        b.file("Xcode_26.xip", in: dl, gb: 3.4)
        b.file("Docker.dmg", in: dl, gb: 0.62)
        b.file("Figma-installer.dmg", in: dl, gb: 0.31)
        b.many(320, in: dl, gb: 0.8)
        let desk = b.dir("Desktop", in: h); b.many(240, in: desk, gb: 0.6)

        // /Applications
        let apps = b.dir("/Applications", in: ScanTree.root)
        for (name, gb) in [("Xcode.app", 12.9), ("Docker.app", 2.1), ("Microsoft Word.app", 2.4), ("Final Cut Pro.app", 6.1),
                           ("Slack.app", 0.55), ("Visual Studio Code.app", 0.6), ("Figma.app", 0.42), ("Safari Technology Preview.app", 0.3)] {
            let a = b.dir(name, in: apps, flags: [.package])
            let c = b.dir("Contents", in: a)
            b.many(5_000, in: c, gb: gb)
        }
        if !Platform.isSandboxed {                                  // App Store edition scans granted folders only
            let hb = b.dir("/opt/homebrew", in: ScanTree.root); b.many(90_000, in: hb, gb: 4.4)
        }

        b.finalize()
        var tree = b.tree
        Classifier.classify(&tree, rules: Classifier.defaultRules(home: home))

        let start = Date(timeIntervalSince1970: 1_791_878_400)   // 12 Oct 2026, 13:00 UTC
        var stats = ScanStats()
        stats.filesVisited = tree.nodes[0].fileCount
        stats.directoriesVisited = Int64(tree.nodes.filter(\.isDirectory).count) * 37
        stats.symlinksNotFollowed = 41_210
        stats.unreadableDirectories = 0
        let manifest = ScanManifest(
            scanID: UUID(uuidString: "D3A0D3A0-0000-4000-8000-000000000001")!, startedAt: start, finishedAt: start.addingTimeInterval(28.4),
            requestedRoots: tree.rootIDs.map { tree.nodes[Int($0)].name }, effectiveRoots: tree.rootIDs.map { tree.nodes[Int($0)].name },
            droppedOverlappingRoots: [], missingRoots: [], options: ScanOptions(roots: [home]), stats: stats, errors: [], errorCount: 0,
            volumeBefore: nil, totalAllocated: tree.totalAllocated, totalLogical: tree.totalLogical, cancelled: false,
            hostName: "Alex's MacBook Pro", osVersion: "macOS", methodology: ScanManifest.methodologyText)
        let volume = VolumeSnapshot(takenAt: start, path: home, volumeName: "Macintosh HD", totalBytes: 494_380_000_000,
                                    availableBytes: 38_200_000_000, availableForImportantUsage: 44_900_000_000)

        let facts = EnvironmentFacts(home: home,
                                     running: [RunningProcess(executable: "/Applications/Slack.app/Contents/MacOS/Slack", commandLine: "Slack")],
                                     installedApps: ["com.microsoft.VSCode": "/Applications/Visual Studio Code.app",
                                                     "com.tinyspeck.slackmacgap": "/Applications/Slack.app"],
                                     processListAvailable: true, processListComplete: !Platform.isSandboxed, now: start)
        var recs = RecommendationEngine.analyze(tree: tree, rules: RuleCatalog.standard(home: home), facts: facts).recommendations
        // Synthetic tree has no files on disk: drop rules that need real files and keep the estimates.
        recs = recs.filter { !$0.ruleID.hasPrefix("sparkle") && ($0.ruleID != "rarely-used-app" || $0.targetPath.contains("Final Cut")) }
        let scan = ScanResult(tree: tree, manifest: manifest)
        // Synthetic history: the same demo Mac filling up over four weeks.
        let history = (0..<5).map { w -> ScanHistoryEntry in
            var e = ScanHistoryEntry(scan, changeCount: 12 - w * 2)
            e.scanID = UUID()
            e.finishedAt = start.addingTimeInterval(-Double(w) * 7 * 86_400)
            e.scannedAllocated = tree.totalAllocated - Int64(w) * 4_100_000_000
            e.availableBytes = volume.availableBytes + Int64(w) * 4_300_000_000
            return e
        }
        return Result(scan: scan, volume: volume, recommendations: recs, history: history)
    }
}

#endif
