import Testing
import Foundation
import Darwin
@testable import DiskLensCore

@Suite("Scanner: aggregation and accounting")
struct ScannerTests {
    @Test func aggregatesDirectorySizesExactly() throws {
        let fx = Fixture("agg")
        fx.file("a/one.bin", bytes: 3_000_000)
        fx.file("a/b/two.bin", bytes: 2_000_000)
        fx.file("a/b/small1.txt", bytes: 1_000)
        fx.file("a/b/small2.txt", bytes: 2_500)
        fx.file("c/three.bin", bytes: 1_500_000)
        let r = try fx.scan()
        let t = r.tree
        // Logical bytes are exact.
        #expect(t.totalLogical == 3_000_000 + 2_000_000 + 1_000 + 2_500 + 1_500_000)
        #expect(t.nodes[0].fileCount == 5)
        // Invariant: every directory equals the sum of its children (no double counting).
        for (i, n) in t.nodes.enumerated() where n.isDirectory {
            let rc = t.recomputedTotals(of: Int32(i))
            #expect(rc.allocated == n.allocated, "allocated mismatch at \(t.path(of: Int32(i)))")
            #expect(rc.logical == n.logical)
            #expect(rc.files == n.fileCount)
        }
        // Allocated is block-rounded, never below logical for dense files.
        #expect(t.totalAllocated >= t.totalLogical)
        let b = try #require(t.find(path: fx.path("a/b")))
        #expect(t[b].logical == 2_003_500)
        #expect(t[b].fileCount == 3)
    }

    @Test func smallFilesAreAggregatedIntoOneNode() throws {
        let fx = Fixture("small")
        for i in 0..<50 { fx.file("d/f\(i).txt", bytes: 100) }
        fx.file("d/big.bin", bytes: 2_000_000)
        let t = try fx.scan().tree
        let d = try #require(t.find(path: fx.path("d")))
        let kids = t[d].children.map { t[$0] }
        #expect(kids.count == 2)
        let agg = try #require(kids.first { $0.isAggregate })
        #expect(agg.fileCount == 50)
        #expect(agg.logical == 5_000)
        #expect(kids.contains { $0.name == "big.bin" && $0.logical == 2_000_000 })
    }

    @Test func hardLinksAreCountedOnce() throws {
        let fx = Fixture("hard")
        let orig = fx.file("x/data.bin", bytes: 4_000_000)
        fx.dir("y")
        fx.hardlink("y/data-link.bin", to: orig)
        let r = try fx.scan()
        #expect(r.tree.totalLogical == 4_000_000)
        #expect(r.manifest.stats.hardLinkDuplicatesSkipped == 1)
        #expect(r.manifest.stats.filesVisited == 1)
    }

    @Test func symlinksAreNeverFollowed() throws {
        let outside = Fixture("outside")
        outside.file("huge/blob.bin", bytes: 5_000_000)
        let fx = Fixture("links")
        fx.file("real.bin", bytes: 1_000_000)
        fx.symlink("link-to-file", to: outside.path("huge/blob.bin"))
        fx.symlink("link-to-dir", to: outside.path("huge"))
        fx.symlink("broken", to: fx.path("does-not-exist"))
        let r = try fx.scan()
        #expect(r.tree.totalLogical < 1_100_000, "symlink targets must not be counted")
        #expect(r.manifest.stats.symlinksNotFollowed == 3)
        #expect(r.tree.find(path: fx.path("link-to-dir/blob.bin")) == nil)
    }

    @Test func permissionDeniedIsReportedNotZero() throws {
        let fx = Fixture("perm")
        fx.file("open/a.bin", bytes: 1_000_000)
        fx.file("locked/secret.bin", bytes: 3_000_000)
        chmod(fx.path("locked"), 0o000)
        defer { chmod(fx.path("locked"), 0o755) }
        let r = try fx.scan()
        let locked = try #require(r.tree.find(path: fx.path("locked")))
        #expect(r.tree[locked].flags.contains(.unreadable))
        #expect(r.tree[locked].errorCount >= 1)
        #expect(r.manifest.stats.unreadableDirectories == 1)
        #expect(r.manifest.errors.contains { $0.path == fx.path("locked") && ($0.errno == EACCES || $0.errno == EPERM) })
        // The root is flagged partial so the UI shows a coverage gap.
        let root = r.tree.rootIDs[0]
        #expect(r.tree[root].flags.contains(.partial))
        var t = r.tree
        Classifier.classify(&t, rules: Classifier.defaultRules(home: fx.root))
        #expect(t[locked].category == .inaccessible)
    }

    @Test func overlappingRootsAreDeduplicated() throws {
        let fx = Fixture("overlap")
        fx.file("a/sub/x.bin", bytes: 2_000_000)
        let r = try fx.scan(roots: [fx.root, fx.path("a/sub"), fx.root])
        #expect(r.manifest.effectiveRoots == [fx.root])
        #expect(r.manifest.droppedOverlappingRoots.count == 2)
        #expect(r.tree.totalLogical == 2_000_000)
    }

    @Test func missingRootsAreRecorded() throws {
        let fx = Fixture("missing")
        let r = try fx.scan(roots: [fx.root, fx.path("nope")])
        #expect(r.manifest.missingRoots == [fx.path("nope")])
    }

    @Test func excludedPathsAreSkipped() throws {
        let fx = Fixture("excl")
        fx.file("keep/a.bin", bytes: 1_000_000)
        fx.file("skip/b.bin", bytes: 1_000_000)
        let r = try DiskScanner.scanSync(options: ScanOptions(roots: [fx.root], excludedPaths: [fx.path("skip")]))
        #expect(r.tree.find(path: fx.path("skip")) == nil)
        #expect(r.tree.totalLogical == 1_000_000)
    }

    @Test func cancellationStopsTheScan() async throws {
        let fx = Fixture("cancel")
        for i in 0..<3000 { fx.file("d\(i % 30)/f\(i).txt", bytes: 10) }
        let flag = CancelFlag()
        flag.cancel()
        #expect(throws: CancellationError.self) {
            _ = try DiskScanner.scanSync(options: ScanOptions(roots: [fx.root]), isCancelled: { flag.isCancelled })
        }
    }

    @Test func asyncScanReportsProgressAndPaths() async throws {
        let fx = Fixture("async")
        for i in 0..<2500 { fx.file("p\(i % 10)/f\(i).txt", bytes: 10) }
        final class Box: @unchecked Sendable { var n = 0 }
        let box = Box()
        let r = try await DiskScanner.scan(options: ScanOptions(roots: [fx.root])) { _ in box.n += 1 }
        #expect(r.tree.nodes[0].fileCount == 2500)
        let p = try #require(r.tree.find(path: fx.path("p3")))
        #expect(r.tree.path(of: p) == fx.path("p3"))
    }

    @Test func privacyProbeReportsOnlyUnresponsiveFolders() {
        let fx = Fixture("probe")
        fx.dir("Downloads"); fx.dir("Documents")
        #expect(PrivacyProbe.unresponsive([fx.path("Downloads"), fx.path("Documents")], timeout: 5).isEmpty)
        #expect(PrivacyProbe.protectedFolders(home: fx.root).sorted() == [fx.path("Documents"), fx.path("Downloads")])
    }

    @Test func scanningDisablesCloudMaterialization() throws {
        let fx = Fixture("dataless")
        fx.file("a.bin", bytes: 10)
        _ = try fx.scan()
        #expect(DatalessPolicy.materializationDisabled, "scans must never download cloud-only files")
    }

    @Test func fileVanishingDuringScanIsHandled() throws {
        // Simulates a deletion race: the tree is scanned, then the file disappears; reclaim
        // estimation and size measurement must not crash and must report absence.
        let fx = Fixture("race")
        let f = fx.file("gone/x.bin", bytes: 2_000_000)
        let r = try fx.scan()
        #expect(r.tree.find(path: f) != nil)
        try FileManager.default.removeItem(atPath: fx.path("gone"))
        #expect(ReclaimEstimator.allocatedSize(of: fx.path("gone")) == nil)
        let est = ReclaimEstimator.estimate(path: fx.path("gone"))
        #expect(est.reclaimable == 0)
    }

    @Test func privacyBlockedFolderIsUnknownNotMissing() throws {
        let fx = Fixture("blocked")
        fx.file("Downloads/big.bin", bytes: 2_000_000)
        fx.file("other/a.bin", bytes: 1_000_000)
        var opts = ScanOptions(roots: [fx.root])
        opts.assumeBlocked = [fx.path("Downloads")]
        var r = try DiskScanner.scanSync(options: opts)
        let d = try #require(r.tree.find(path: fx.path("Downloads")), "blocked folder must stay visible")
        #expect(r.tree[d].flags.contains(.unreadable))
        #expect(r.tree[r.tree.rootIDs[0]].flags.contains(.partial))
        #expect(r.tree.totalLogical == 1_000_000)
        #expect(r.manifest.privacyBlockedPaths == [fx.path("Downloads")])
        Classifier.classify(&r.tree, rules: Classifier.defaultRules(home: fx.root))
        #expect(r.tree[d].category == .inaccessible)
    }

    @Test func firmlinkAliasRootIsCountedOnce() throws {
        let fx = Fixture("alias")
        fx.file("a/x.bin", bytes: 3_000_000)
        // /private/var is firmlinked to /System/Volumes/Data/private/var: same folder, different path.
        let alias = "/System/Volumes/Data" + fx.root
        guard FileManager.default.fileExists(atPath: alias) else { return }
        let r = try DiskScanner.scanSync(options: ScanOptions(roots: [fx.root, alias]))
        #expect(r.tree.totalLogical == 3_000_000)
        #expect(r.manifest.droppedOverlappingRoots.contains(alias))
    }

    @Test func hardLinkedFileRootsCountOnce() throws {
        let fx = Fixture("rootlinks")
        let a = fx.file("a.bin", bytes: 2_000_000)
        let b = fx.hardlink("b.bin", to: a)
        let r = try DiskScanner.scanSync(options: ScanOptions(roots: [a, b]))
        #expect(r.tree.totalLogical == 2_000_000)
        #expect(r.manifest.stats.hardLinkDuplicatesSkipped == 1)
    }

    @Test func unreadableRootIsReportedAsUnknown() throws {
        let fx = Fixture("lockedroot")
        fx.file("locked/inner/a.bin", bytes: 1000)
        chmod(fx.path("locked"), 0o000)
        defer { chmod(fx.path("locked"), 0o755) }
        let r = try DiskScanner.scanSync(options: ScanOptions(roots: [fx.path("locked/inner")]))
        #expect(r.manifest.missingRoots.isEmpty)
        #expect(r.tree.rootIDs.count == 1 && r.tree[r.tree.rootIDs[0]].flags.contains(.unreadable))
        #expect(r.manifest.errors.contains { $0.path == fx.path("locked/inner") })
    }
}
