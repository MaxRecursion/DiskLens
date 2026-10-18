import Testing
import Foundation
import Darwin
@testable import DiskLensCore

@Suite("Cleanup-plan generation")
struct RecommendationTests {
    /// A synthetic home with the situations found on the real machine.
    func makeHome() throws -> (Fixture, ScanTree, EnvironmentFacts) {
        let fx = Fixture("rec-home")
        fx.file(".npm/_cacache/content-v2/sha512/aa/blob", bytes: 60_000_000)
        fx.file(".npm/_npx/abc123/node_modules/tool/index.js", bytes: 15_000_000)
        fx.file(".npm/_npx/inuse99/node_modules/srv/index.js", bytes: 15_000_000)
        // Project with lockfile -> tier 2
        fx.file("proj/package.json", bytes: 40)
        fx.file("proj/package-lock.json", bytes: 40)
        fx.file("proj/node_modules/big/lib.js", bytes: 55_000_000)
        fx.file("proj/.next/cache/x.bin", bytes: 25_000_000)
        // Project without lockfile -> tier 3
        fx.file("nolock/package.json", bytes: 40)
        fx.file("nolock/node_modules/dep/a.js", bytes: 55_000_000)
        // Project run by a LaunchAgent -> tier 3
        fx.file("bot/package.json", bytes: 40)
        fx.file("bot/package-lock.json", bytes: 40)
        fx.file("bot/node_modules/dep/a.js", bytes: 55_000_000)
        // Tool-owned node_modules (must be ignored)
        fx.file(".cache/somecli/node_modules/x/a.js", bytes: 55_000_000)
        // Sparkle: stale and pending
        fx.file("Applications/FooApp.app/Contents/MacOS/Foo", bytes: 10)
        try plist(fx.path("Applications/FooApp.app/Contents/Info.plist"), id: "com.example.foo", version: "2.0")
        fx.file("Library/Caches/com.example.foo/org.sparkle-project.Sparkle/Installation/old1/x/Foo.app/Contents/MacOS/Foo", bytes: 60_000_000)
        try plist(fx.path("Library/Caches/com.example.foo/org.sparkle-project.Sparkle/Installation/old1/x/Foo.app/Contents/Info.plist"), id: "com.example.foo", version: "1.9")
        fx.file("Library/Caches/com.example.foo/org.sparkle-project.Sparkle/Installation/new2/x/Foo.app/Contents/MacOS/Foo", bytes: 60_000_000)
        try plist(fx.path("Library/Caches/com.example.foo/org.sparkle-project.Sparkle/Installation/new2/x/Foo.app/Contents/Info.plist"), id: "com.example.foo", version: "2.1")
        // Electron cache of a running and a non-running app
        fx.file("Library/Application Support/Foo/Cache/data_1", bytes: 40_000_000)
        fx.file("Library/Application Support/Bar/Code Cache/js/x", bytes: 40_000_000)
        // Personal installer, VM disk, documents
        fx.file("Downloads/FooApp-2.0.dmg", bytes: 60_000_000)
        fx.file(".colima/_lima/disk", bytes: 600_000_000)
        fx.file("Documents/taxes/2025.pdf", bytes: 5_000_000)
        fx.file("Documents/site/package.json", bytes: 40)
        fx.file("Documents/site/yarn.lock", bytes: 40)
        fx.file("Documents/site/node_modules/a/b.js", bytes: 60_000_000)

        var tree = try fx.scan().tree
        Classifier.classify(&tree, rules: Classifier.defaultRules(home: fx.root))
        let facts = EnvironmentFacts(
            home: fx.root,
            running: [RunningProcess(executable: "/opt/homebrew/bin/node", commandLine: "node \(fx.path(".npm/_npx/inuse99"))/node_modules/.bin/srv"),
                      RunningProcess(executable: "/Applications/Bar.app/Contents/MacOS/Bar", commandLine: "Bar")],
            installedApps: ["com.example.foo": fx.path("Applications/FooApp.app")],
            launchAgents: ["com.me.bot": ["/opt/homebrew/bin/node", fx.path("bot/index.js")]])
        return (fx, tree, facts)
    }

    func plist(_ path: String, id: String, version: String) throws {
        let d: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
        try d.write(to: URL(fileURLWithPath: path))
    }

    func rec(_ recs: [Recommendation], _ fx: Fixture, _ rel: String) -> Recommendation? {
        recs.first { $0.targetPath == fx.path(rel) }
    }

    @Test func generatesTieredNonOverlappingPlan() throws {
        let (fx, tree, facts) = try makeHome()
        let recs = RecommendationEngine.analyze(tree: tree, rules: RuleCatalog.standard(home: fx.root), facts: facts).recommendations

        let npm = try #require(rec(recs, fx, ".npm/_cacache"))
        #expect(npm.tier == .low && npm.action.kind == .deletePermanently && npm.eligibleForAutoSelection)

        let npx = try #require(rec(recs, fx, ".npm/_npx/abc123"))
        #expect(npx.inUseBy.isEmpty)
        let npxBusy = try #require(rec(recs, fx, ".npm/_npx/inuse99"))
        #expect(npxBusy.inUseBy == ["node"])
        #expect(!npxBusy.eligibleForAutoSelection)

        let nm = try #require(rec(recs, fx, "proj/node_modules"))
        #expect(nm.tier == .conditional)
        #expect(nm.reason.contains("package-lock.json"))
        #expect(try #require(rec(recs, fx, "proj/.next")).tier == .low)
        #expect(try #require(rec(recs, fx, "nolock/node_modules")).tier == .manualReview)
        let bot = try #require(rec(recs, fx, "bot/node_modules"))
        #expect(bot.tier == .manualReview && bot.reason.contains("com.me.bot"))
        #expect(rec(recs, fx, ".cache/somecli/node_modules") == nil, "tool-owned node_modules must be ignored")

        let stale = try #require(rec(recs, fx, "Library/Caches/com.example.foo/org.sparkle-project.Sparkle/Installation/old1"))
        #expect(stale.tier == .low && stale.title.contains("Stale"))
        let pending = try #require(rec(recs, fx, "Library/Caches/com.example.foo/org.sparkle-project.Sparkle/Installation/new2"))
        #expect(pending.tier == .conditional && pending.title.contains("Pending"))

        #expect(try #require(rec(recs, fx, "Library/Application Support/Foo/Cache")).inUseBy.isEmpty)
        #expect(try #require(rec(recs, fx, "Library/Application Support/Bar/Code Cache")).inUseBy == ["Bar"])

        let dmg = try #require(rec(recs, fx, "Downloads/FooApp-2.0.dmg"))
        #expect(dmg.tier == .manualReview && dmg.action.kind == .manualReview)
        #expect(dmg.reason.contains("FooApp.app"))
        #expect(try #require(rec(recs, fx, ".colima")).tier == .manualReview)
        #expect(!recs.contains { $0.targetPath.hasPrefix(fx.path("Documents/taxes")) })
        #expect(try #require(rec(recs, fx, "Documents/site/node_modules")).tier == .conditional)

        // No two recommendations overlap (no double counting).
        let paths = recs.map(\.targetPath)
        for a in paths { for b in paths where a != b { #expect(!PathUtil.isStrictlyInside(a, b), "\(a) overlaps \(b)") } }
        // Estimates never exceed what is on disk.
        #expect(recs.allSatisfy { $0.estimatedReclaimable <= $0.detectedAllocated })
    }

    @Test func trashAndUnknownDotFoldersAreNeverToolLogs() throws {
        let fx = Fixture("trashlogs")
        fx.file(".Trash/logs/my-notes.bin", bytes: 60_000_000)
        fx.file(".git/logs/HEAD.bin", bytes: 60_000_000)
        fx.file(".openclaw/logs/gw.log", bytes: 60_000_000)
        var tree = try fx.scan().tree
        Classifier.classify(&tree, rules: Classifier.defaultRules(home: fx.root))
        let facts = EnvironmentFacts(home: fx.root, running: [], installedApps: [:])
        let recs = RecommendationEngine.analyze(tree: tree, rules: RuleCatalog.standard(home: fx.root), facts: facts).recommendations
        #expect(!recs.contains { $0.targetPath.hasPrefix(fx.path(".Trash")) })
        #expect(!recs.contains { $0.targetPath.hasPrefix(fx.path(".git")) })
        #expect(recs.contains { $0.targetPath == fx.path(".openclaw/logs") })
        #expect((try? PathGuard.standard(home: fx.root).validate(fx.path(".Trash/logs")).get()) == nil)
    }

    @Test func activeCLIVersionIsNeverOffered() throws {
        let fx = Fixture("versions")
        fx.file(".local/share/claude/versions/2.0.30", bytes: 60_000_000)
        fx.file(".local/share/claude/versions/2.0.35", bytes: 60_000_000)
        fx.file(".local/share/claude/versions/2.0.20", bytes: 60_000_000)
        fx.dir(".local/bin")
        fx.symlink(".local/bin/claude", to: fx.path(".local/share/claude/versions/2.0.30"))   // rolled back
        var tree = try fx.scan().tree
        Classifier.classify(&tree, rules: Classifier.defaultRules(home: fx.root))
        let facts = EnvironmentFacts(home: fx.root, running: [], installedApps: [:])
        let recs = RecommendationEngine.analyze(tree: tree, rules: RuleCatalog.standard(home: fx.root), facts: facts).recommendations
        #expect(!recs.contains { $0.targetPath.hasSuffix("/2.0.30") }, "active (launcher) version must be kept")
        #expect(!recs.contains { $0.targetPath.hasSuffix("/2.0.35") }, "newest version must be kept")
        let old = try #require(recs.first { $0.targetPath.hasSuffix("/2.0.20") })
        #expect(old.tier == .conditional && old.action.kind == .deletePermanently)
    }

    @Test func appCacheWithUnidentifiedOwnerIsNotTierOne() throws {
        let fx = Fixture("owner")
        fx.file("Library/Application Support/obsidian/Code Cache/js/x", bytes: 40_000_000)
        fx.file("Library/Application Support/Mystery/Cache/data", bytes: 40_000_000)
        fx.file("Applications/Obsidian.app/Contents/MacOS/Obsidian", bytes: 10)
        var tree = try fx.scan().tree
        Classifier.classify(&tree, rules: Classifier.defaultRules(home: fx.root))
        let facts = EnvironmentFacts(home: fx.root,
            running: [RunningProcess(executable: fx.path("Applications/Obsidian.app/Contents/MacOS/Obsidian"), commandLine: "Obsidian")],
            installedApps: ["md.obsidian": fx.path("Applications/Obsidian.app")])
        let recs = RecommendationEngine.analyze(tree: tree, rules: RuleCatalog.standard(home: fx.root), facts: facts).recommendations
        let obs = try #require(recs.first { $0.targetPath.hasSuffix("/obsidian/Code Cache") })
        #expect(obs.inUseBy == ["Obsidian"], "folder 'obsidian' must map to running Obsidian.app")
        let mystery = try #require(recs.first { $0.targetPath.hasSuffix("/Mystery/Cache") })
        #expect(mystery.tier == .conditional && !mystery.eligibleForAutoSelection || mystery.risk == .medium)
    }

    @Test func refinedEstimatesAccountForClonesAndHardLinks() async throws {
        let fx = Fixture("clones")
        let store = fx.file("store/pkg.bin", bytes: 8_000_000, fill: 0x11)
        fx.dir("proj/node_modules")
        #expect(clonefile(store, fx.path("proj/node_modules/pkg.bin"), 0) == 0)
        fx.file("proj/node_modules/private.bin", bytes: 3_000_000, fill: 0x22)
        let outsideLink = fx.file("proj/node_modules/linked.bin", bytes: 2_000_000, fill: 0x33)
        fx.hardlink("elsewhere-link.bin", to: outsideLink)

        let est = ReclaimEstimator.estimate(path: fx.path("proj/node_modules"))
        #expect(est.usedPrivateSize)
        #expect(est.cloneShared >= 7_900_000, "cloned blocks are shared and must not count as reclaimable")
        #expect(est.hardLinkRetained >= 1_900_000, "a file with a link outside the target is not freed")
        #expect(est.reclaimable >= 2_900_000 && est.reclaimable < 4_000_000)

        var r = makeRec(fx.path("proj/node_modules"), bytes: est.allocated)
        r.detectedAllocated = est.allocated
        let refined = await RecommendationEngine.refineEstimates([r])
        #expect(refined[0].estimatedReclaimable == est.reclaimable)
        #expect(refined[0].notes.contains { $0.contains("APFS clones") })
    }

    @Test func privateSizeOfOrdinaryFileEqualsAllocation() throws {
        let fx = Fixture("priv")
        let f = fx.file("a.bin", bytes: 5_000_000, fill: 0x44)
        var st = stat()
        lstat(f, &st)
        #expect(ReclaimEstimator.privateSize(of: f) == Int64(st.st_blocks) * 512)
    }

    @Test func versionComparisonAndBrewParsing() {
        #expect(RuleCatalog.compareVersions("26.1007.21159", "26.1005.1") == 1)
        #expect(RuleCatalog.compareVersions("2026.08.04-aaa", "2026.10.01-e37") == -1)
        #expect(RuleCatalog.compareVersions("1.10", "1.9") == 1)
        #expect(RuleCatalog.parseBrewFreed("==> This operation would free approximately 400.2MB of disk space.") == 400_200_000)
        #expect(RuleCatalog.parseBrewFreed("would free approximately 1.5GB") == 1_500_000_000)
        #expect(RuleCatalog.parseBrewFreed("nothing to do") == nil)
    }

    @Test func softProtectedFoldersOnlyAllowArtifacts() {
        let fx = Fixture("soft")
        fx.dir("home/Documents/site/node_modules")
        fx.dir("home/Documents/taxes")
        fx.dir("home/Documents/site/node_modules/inner")
        let g = PathGuard(allowedRoots: [fx.path("home")], protectedPaths: [], softProtectedPaths: [fx.path("home/Documents")], minimumDepth: 2)
        #expect((try? g.validate(fx.path("home/Documents/site/node_modules")).get()) != nil)
        #expect((try? g.validate(fx.path("home/Documents/taxes")).get()) == nil)
        #expect((try? g.validate(fx.path("home/Documents/site/node_modules/inner")).get()) == nil)
        #expect((try? g.validate(fx.path("home/Documents")).get()) == nil)
    }
}

@Suite("Duplicate detection")
struct DuplicateTests {
    @Test func hardLinkedCopyFreesNothing() throws {
        let fx = Fixture("duplinks")
        fx.file("Pictures/p/a.jpg", bytes: 6_000_000, fill: 0x71)
        let c = fx.file("Downloads/c.jpg", bytes: 6_000_000, fill: 0x71)
        fx.dir("Desktop/keep")
        fx.hardlink("Desktop/keep/c-link.jpg", to: c)       // the Downloads copy has another link
        var tree = try fx.scan().tree
        Classifier.classify(&tree, rules: Classifier.defaultRules(home: fx.root))
        var opts = DuplicateFinder.Options(); opts.minFolderBytes = 0
        let r = DuplicateFinder.analyze(tree: tree, home: fx.root, existing: [], options: opts)
        // The hard-linked file is kept (removing one link frees nothing); the real copy is reported.
        #expect(!r.recommendations.contains { ($0.targetPath == fx.path("Downloads") || $0.targetPath == fx.path("Desktop/keep")) && $0.estimatedReclaimable > 0 })
        let real = try #require(r.recommendations.first { $0.targetPath == fx.path("Pictures/p") })
        #expect(real.estimatedReclaimable >= 5_900_000)
    }

    @Test func findsRealCopiesAndRecognisesClones() throws {
        let fx = Fixture("dups")
        let orig = fx.file("Pictures/party/a.jpg", bytes: 6_000_000, fill: 0x61)
        fx.file("Downloads/a-copy.jpg", bytes: 6_000_000, fill: 0x61)          // real copy
        fx.dir("Desktop/clones")
        #expect(clonefile(orig, fx.path("Desktop/clones/a-clone.jpg"), 0) == 0)  // clone: shares blocks
        fx.file("Pictures/party/unique.jpg", bytes: 6_000_000, fill: 0x62)     // same size, different bytes
        fx.dir("Projects/app/node_modules")
        fx.file("Projects/app/node_modules/a.jpg", bytes: 6_000_000, fill: 0x61) // developer area: ignored
        var tree = try fx.scan().tree
        Classifier.classify(&tree, rules: Classifier.defaultRules(home: fx.root))
        var opts = DuplicateFinder.Options()
        opts.minFolderBytes = 0
        let r = DuplicateFinder.analyze(tree: tree, home: fx.root, existing: [], options: opts)
        let copies = r.recommendations.reduce(Int64(0)) { $0 + $1.fileCount }
        #expect(copies == 2, "one real copy + one clone; the unique file and node_modules are not duplicates")
        let reclaim = r.recommendations.reduce(Int64(0)) { $0 + $1.estimatedReclaimable }
        #expect(reclaim >= 5_900_000 && reclaim < 7_000_000, "the clone frees ~0, the real copy frees its size")
        #expect(r.recommendations.allSatisfy { $0.tier == .manualReview && $0.action.kind == .manualReview })
        #expect(!r.recommendations.contains { $0.targetPath == fx.path("Pictures/party") }, "the original is never the target")
        #expect(fx.exists("Downloads/a-copy.jpg"), "analysis is read-only")
    }
}

@Suite("Persistence and change detection")
struct StoreTests {
    func summary(_ sizes: [String: Int64], roots: [String], unknown: [String] = []) -> ScanSummary {
        ScanSummary(scanID: UUID(), finishedAt: Date(), sizes: sizes, minBytes: 10_000_000, roots: roots, unknownPaths: unknown)
    }

    @Test func coverageDifferencesAreNotReportedAsChanges() {
        // A root added in the second scan is not "growth".
        let a = summary(["/h": 1_000_000_000, "/h/x": 500_000_000], roots: ["/h"])
        let b = summary(["/h": 1_000_000_000, "/h/x": 500_000_000, "/apps": 9_000_000_000], roots: ["/h", "/apps"])
        #expect(ScanDiff.changes(previous: a, current: b).isEmpty)
        // A folder that became unreadable (e.g. TCC) is not "shrinkage", nor are its ancestors.
        let c = summary(["/h": 1_000_000_000, "/h/dl": 400_000_000], roots: ["/h"])
        let d = summary(["/h": 600_000_000], roots: ["/h"], unknown: ["/h/dl"])
        #expect(ScanDiff.changes(previous: c, current: d).isEmpty)
        // Real growth elsewhere is still reported, and a vanished folder is marked as below threshold.
        let e = summary(["/h": 1_000_000_000, "/h/old": 300_000_000], roots: ["/h"])
        let f = summary(["/h": 1_200_000_000, "/h/new": 500_000_000], roots: ["/h"])
        let ch = ScanDiff.changes(previous: e, current: f)
        #expect(ch.contains { $0.path == "/h/new" && $0.beforeIsBelowThreshold })
        #expect(ch.contains { $0.path == "/h/old" && $0.afterIsBelowThreshold })
    }

    @Test func saveLoadRoundTripAndDiff() throws {
        let fx = Fixture("store")
        fx.file("data/a.bin", bytes: 30_000_000)
        let store = ScanStore(directory: URL(fileURLWithPath: fx.path("store-dir")))
        var r1 = try DiskScanner.scanSync(options: ScanOptions(roots: [fx.path("data")]))
        Classifier.classify(&r1.tree)
        #expect(try store.save(r1).isEmpty)
        let loaded = try #require(store.loadLatest())
        #expect(loaded.tree.totalAllocated == r1.tree.totalAllocated)
        #expect(loaded.manifest.scanID == r1.manifest.scanID)

        fx.file("data/grow/b.bin", bytes: 150_000_000)
        let r2 = try DiskScanner.scanSync(options: ScanOptions(roots: [fx.path("data")]))
        let changes = try store.save(r2)
        // The most specific folder explaining the growth is reported, not its parent too.
        #expect(changes.contains { $0.path == fx.path("data/grow") && $0.delta >= 150_000_000 })
        #expect(!changes.contains { $0.path == fx.path("data") })

        // A folder skipped in the next scan must not be reported as having shrunk.
        var opts = ScanOptions(roots: [fx.path("data")])
        opts.excludedPaths = [fx.path("data/grow")]
        let r3 = try DiskScanner.scanSync(options: opts)
        let changes3 = try store.save(r3)
        #expect(!changes3.contains { PathUtil.isSameOrInside($0.path, fx.path("data/grow")) || $0.path == fx.path("data") })
    }
}
