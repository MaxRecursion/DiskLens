import Testing
import Foundation
import Darwin
@testable import DiskLensCore

@Suite("Path traversal protection")
struct PathGuardTests {
    @Test func acceptsCanonicalPathInsideScope() throws {
        let fx = Fixture("guard-ok")
        fx.file("cache/x.bin", bytes: 10)
        let g = PathGuard(allowedRoots: [fx.root], protectedPaths: [], minimumDepth: 2)
        let v = try g.validate(fx.path("cache")).get()
        #expect(v.isDirectory)
    }

    @Test func manualTrashAllowsUserContentButKeepsHardProtections() throws {
        let fx = Fixture("guard-manual")
        fx.file("Downloads/Installer.dmg", bytes: 10)
        fx.file("Documents/old-report.pdf", bytes: 10)
        fx.file(".ssh/id_ed25519", bytes: 10)
        fx.file(".Trash/x.bin", bytes: 10)
        fx.file("Library/Keychains/login.keychain-db", bytes: 10)
        fx.file("proj/.git/objects/pack.bin", bytes: 10)
        let manual = PathGuard.manualTrash(home: fx.root, allowedRoots: [fx.root])
        let auto = PathGuard.standard(home: fx.root, allowedRoots: [fx.root])
        // A file the user picked inside Downloads/Documents: allowed for manual Trash only.
        #expect(throws: PathGuardError.self) { try auto.validate(fx.path("Downloads/Installer.dmg")).get() }
        #expect((try? manual.validate(fx.path("Downloads/Installer.dmg")).get()) != nil)
        #expect((try? manual.validate(fx.path("Documents/old-report.pdf")).get()) != nil)
        // The content folders themselves and every hard protection stay refused.
        for rel in ["Documents", "Downloads", ".ssh/id_ed25519", ".Trash/x.bin", ".Trash", "Library/Keychains/login.keychain-db",
                    "proj/.git", "proj/.git/objects/pack.bin"] {
            #expect(throws: PathGuardError.self, "\(rel) must be refused") { try manual.validate(fx.path(rel)).get() }
        }
        // Case-folded: ~/documents is still the protected folder.
        #expect(throws: PathGuardError.self) { try manual.validate(fx.path("documents")).get() }
    }

    @Test func rejectsRelativeTraversalAndOddPaths() {
        let fx = Fixture("guard-trav")
        fx.dir("a/b")
        let g = PathGuard(allowedRoots: [fx.path("a")], protectedPaths: [], minimumDepth: 2)
        #expect(throws: PathGuardError.self) { try g.validate("relative/path").get() }
        #expect(throws: PathGuardError.self) { try g.validate(fx.path("a/b/../../escape")).get() }
        #expect(throws: PathGuardError.self) { try g.validate(fx.path("a/./b")).get() }
        #expect(throws: PathGuardError.self) { try g.validate(fx.path("a//b")).get() }
        #expect(throws: PathGuardError.self) { try g.validate("/").get() }
        #expect(throws: PathGuardError.self) { try g.validate(fx.path("a")).get() }   // scope root itself
    }

    @Test func rejectsPathsOutsideScope() {
        let fx = Fixture("guard-scope")
        fx.dir("inside/x")
        fx.dir("outside/y")
        let g = PathGuard(allowedRoots: [fx.path("inside")], protectedPaths: [], minimumDepth: 2)
        #expect(throws: PathGuardError.outsideAllowedScope(fx.path("outside/y"))) { try g.validate(fx.path("outside/y")).get() }
        // Prefix trick: "inside-evil" must not count as inside "inside".
        fx.dir("inside-evil/z")
        #expect(throws: PathGuardError.self) { try g.validate(fx.path("inside-evil/z")).get() }
    }

    @Test func rejectsSymlinkTargetsAndSymlinkedAncestors() {
        let fx = Fixture("guard-link")
        fx.dir("scope/real/data")
        let outside = Fixture("guard-link-out")
        outside.dir("victim")
        fx.symlink("scope/link-dir", to: outside.path(""))
        fx.symlink("scope/link-file", to: fx.path("scope/real"))
        let g = PathGuard(allowedRoots: [fx.path("scope")], protectedPaths: [], minimumDepth: 2)
        // The link itself is refused.
        #expect(throws: PathGuardError.symbolicLink(fx.path("scope/link-file"))) { try g.validate(fx.path("scope/link-file")).get() }
        // A path *through* a symlinked ancestor resolves elsewhere and is refused.
        #expect(throws: PathGuardError.self) { try g.validate(fx.path("scope/link-dir/victim")).get() }
        #expect(outside.exists("victim"))
    }

    @Test func rejectsProtectedLocationsAndTheirAncestors() {
        let fx = Fixture("guard-prot")
        fx.dir("home/Documents/taxes")
        fx.dir("home/proj/.git/objects")
        fx.dir("home/Library/Keychains")
        fx.dir("home/stuff/.ssh")
        let g = PathGuard(allowedRoots: [fx.path("home")], protectedPaths: [fx.path("home/Documents")], minimumDepth: 2)
        #expect(throws: PathGuardError.self) { try g.validate(fx.path("home/Documents/taxes")).get() }
        #expect(throws: PathGuardError.self) { try g.validate(fx.path("home/Documents")).get() }
        #expect(throws: PathGuardError.self) { try g.validate(fx.path("home/proj/.git/objects")).get() }
        #expect(throws: PathGuardError.self) { try g.validate(fx.path("home/proj/.git")).get() }
        #expect(throws: PathGuardError.self) { try g.validate(fx.path("home/Library/Keychains")).get() }
        #expect(throws: PathGuardError.self) { try g.validate(fx.path("home/stuff/.ssh")).get() }
        // Ancestor of a protected path is refused too (deleting it would delete the protected path).
        let g2 = PathGuard(allowedRoots: [fx.root], protectedPaths: [fx.path("home/Documents")], minimumDepth: 2)
        #expect(throws: PathGuardError.self) { try g2.validate(fx.path("home")).get() }
    }

    @Test func protectionIsCaseInsensitive() {
        let fx = Fixture("guard-case")
        fx.dir("home/Documents/taxes")
        fx.dir("home/proj/.Git/objects")
        let g = PathGuard(allowedRoots: [fx.path("home")], protectedPaths: [fx.path("home/Documents")], minimumDepth: 2)
        // Same folder addressed with different case on a case-insensitive volume.
        #expect((try? g.validate(fx.path("home/documents/taxes")).get()) == nil)
        #expect((try? g.validate(fx.path("home/DOCUMENTS")).get()) == nil)
        #expect((try? g.validate(fx.path("home/proj/.Git/objects")).get()) == nil)
    }

    @Test func rejectsMissingPaths() {
        let fx = Fixture("guard-missing")
        let g = PathGuard(allowedRoots: [fx.root], protectedPaths: [], minimumDepth: 2)
        #expect(throws: PathGuardError.doesNotExist(fx.path("ghost"))) { try g.validate(fx.path("ghost")).get() }
    }

    @Test func standardGuardProtectsUserContent() {
        let home = NSHomeDirectory()
        let g = PathGuard.standard()
        // Validation fails for these regardless of existence (protected or outside scope).
        for p in ["/System/Library", "/usr/bin/true", home + "/Documents", home + "/.ssh", home + "/Library/Keychains", "/Applications/Safari.app"] {
            #expect((try? g.validate(p).get()) == nil, "\(p) must be refused")
        }
    }
}

@Suite("Cleanup execution, approval and verification")
struct ExecutorTests {
    @Test func dryRunNeverMutates() throws {
        let fx = Fixture("dry")
        fx.file("cache1/a.bin", bytes: 100_000)
        fx.file("cache2/b.bin", bytes: 100_000)
        let plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("cache1")), makeRec(fx.path("cache2"), kind: .moveToTrash)])
        let report = try testExecutor(fx).execute(plan: plan, approval: nil, dryRun: true)
        #expect(report.results.allSatisfy { $0.status == .wouldExecute })
        #expect(fx.exists("cache1/a.bin") && fx.exists("cache2/b.bin"))
        #expect(report.dryRun)
    }

    @Test func executionRequiresApproval() throws {
        let fx = Fixture("approval")
        fx.file("cache/a.bin", bytes: 1000)
        let plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("cache"))])
        #expect(throws: CleanupError.approvalRequired) {
            try testExecutor(fx).execute(plan: plan, approval: nil, dryRun: false)
        }
        #expect(fx.exists("cache/a.bin"))
    }

    @Test func approvalIsBoundToTheExactPlan() throws {
        let fx = Fixture("approval2")
        fx.file("cache/a.bin", bytes: 1000)
        fx.file("other/b.bin", bytes: 1000)
        var plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("cache"))])
        let approval = CleanupApproval(plan: plan, approver: "test")
        plan.items.append(makeRec(fx.path("other")))   // tampering after approval
        #expect(throws: CleanupError.self) { try testExecutor(fx).execute(plan: plan, approval: approval, dryRun: false) }
        #expect(fx.exists("cache/a.bin") && fx.exists("other/b.bin"))
    }

    @Test func approvedPlanDeletesAndVerifies() throws {
        let fx = Fixture("exec")
        fx.file("cache/a.bin", bytes: 300_000)
        fx.file("keep/b.bin", bytes: 300_000)
        let plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("cache"))])
        let report = try testExecutor(fx).execute(plan: plan, approval: CleanupApproval(plan: plan, approver: "test"), dryRun: false)
        let r = try #require(report.results.first)
        #expect(r.status == .succeeded)
        #expect((r.bytesBefore ?? 0) >= 300_000)
        #expect(r.bytesAfter == 0)
        #expect(!fx.exists("cache"))
        #expect(fx.exists("keep/b.bin"))
        #expect(report.volumeBefore != nil && report.volumeAfter != nil)
        #expect(report.measuredFreeSpaceDelta != nil)
    }

    @Test func deletionRaceTargetAlreadyGoneIsSkipped() throws {
        let fx = Fixture("race2")
        fx.file("a/x.bin", bytes: 1000)
        fx.file("b/y.bin", bytes: 1000)
        let plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("a")), makeRec(fx.path("b"))])
        try FileManager.default.removeItem(atPath: fx.path("a"))   // vanished after planning
        let report = try testExecutor(fx).execute(plan: plan, approval: CleanupApproval(plan: plan, approver: "t"), dryRun: false)
        #expect(report.results[0].status == .skipped)
        #expect(report.results[0].message.contains("no longer exists"))
        #expect(report.results[1].status == .succeeded)
    }

    @Test func replacedTargetIsSkipped() throws {
        let fx = Fixture("replaced")
        fx.file("a/x.bin", bytes: 1000)
        let plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("a"))])
        try FileManager.default.removeItem(atPath: fx.path("a"))
        fx.file("a/new-user-data.txt", bytes: 10)   // different directory, same path
        let report = try testExecutor(fx).execute(plan: plan, approval: CleanupApproval(plan: plan, approver: "t"), dryRun: false)
        #expect(report.results[0].status == .skipped)
        #expect(fx.exists("a/new-user-data.txt"))
    }

    @Test func failuresDoNotStopOtherItems() throws {
        let fx = Fixture("fail")
        fx.file("a/x.bin", bytes: 1000)
        fx.file("b/y.bin", bytes: 1000)
        let ops = FakeFileOps()
        ops.failPaths = [fx.path("a")]
        let plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("a")), makeRec(fx.path("b"))])
        let report = try testExecutor(fx, ops: ops).execute(plan: plan, approval: CleanupApproval(plan: plan, approver: "t"), dryRun: false)
        #expect(report.results[0].status == .failed)
        #expect(report.results[0].message.contains("injected failure"))
        #expect(fx.exists("a/x.bin"))
        #expect(report.results[1].status == .succeeded)
        #expect(!fx.exists("b"))
        #expect(report.followUp.contains { $0.contains("failed") })
    }

    @Test func tierThreeIsNeverExecuted() throws {
        let fx = Fixture("tier3")
        fx.file("photos/img.jpg", bytes: 1000)
        let plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("photos"), tier: .manualReview, kind: .deletePermanently)])
        let report = try testExecutor(fx).execute(plan: plan, approval: CleanupApproval(plan: plan, approver: "t"), dryRun: false)
        #expect(report.results[0].status == .skipped)
        #expect(fx.exists("photos/img.jpg"))
    }

    @Test func outOfScopeAndProtectedTargetsAreRefused() throws {
        let fx = Fixture("scope")
        let outside = Fixture("scope-out")
        outside.file("victim/x.bin", bytes: 1000)
        fx.file("protected/y.bin", bytes: 1000)
        let plan = CleanupPlan(scanID: nil, items: [makeRec(outside.path("victim")), makeRec(fx.path("protected"))])
        let report = try testExecutor(fx).execute(plan: plan, approval: CleanupApproval(plan: plan, approver: "t"), dryRun: false)
        #expect(report.results.allSatisfy { $0.status == .skipped })
        #expect(outside.exists("victim/x.bin"))
        #expect(fx.exists("protected/y.bin"))
    }

    @Test func inUseTargetsAreSkipped() throws {
        let fx = Fixture("inuse")
        fx.file("appcache/x.bin", bytes: 1000)
        let plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("appcache"), owners: ["/Example.app/"])])
        let ex = testExecutor(fx, running: ["/Applications/Example.app/Contents/MacOS/Example"])
        let report = try ex.execute(plan: plan, approval: CleanupApproval(plan: plan, approver: "t"), dryRun: false)
        #expect(report.results[0].status == .skipped)
        #expect(report.results[0].message.contains("Example"))
        #expect(fx.exists("appcache/x.bin"))
    }

    @Test func commandsMustBeAllowlistedAndRunWithoutShell() throws {
        let fx = Fixture("cmd")
        var ok = makeRec(fx.path(""), kind: .runCommand)
        ok.action = .command("/bin/echo", ["$(touch \(fx.path("pwned")))"], measuring: nil)
        ok.id = "ok"
        var bad = makeRec(fx.path(""), kind: .runCommand)
        bad.action = .command("/bin/rm", ["-rf", fx.path("x")], measuring: nil)
        bad.id = "bad"
        let plan = CleanupPlan(scanID: nil, items: [ok, bad])
        let report = try testExecutor(fx).execute(plan: plan, approval: CleanupApproval(plan: plan, approver: "t"), dryRun: false)
        #expect(report.results[0].status == .succeeded)
        #expect(!fx.exists("pwned"), "arguments must never be interpreted by a shell")
        #expect(report.results[1].status == .skipped)
    }

    @Test func trashModeIsReversibleAndFlagged() throws {
        let fx = Fixture("trash")
        fx.file("old/x.bin", bytes: 1000)
        let ops = FakeFileOps()
        let plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("old"), kind: .moveToTrash, bytes: 200 << 20)])
        let report = try testExecutor(fx, ops: ops).execute(plan: plan, approval: CleanupApproval(plan: plan, approver: "t"), dryRun: false)
        #expect(ops.trashed == [fx.path("old")])
        #expect(report.results[0].status == .succeeded)
        #expect(report.unexpected.contains { $0.contains("Trash") })
    }

    @Test func parentSwappedForSymlinkAfterValidationCannotRedirectDelete() throws {
        let fx = Fixture("toctou")
        fx.file("home/proj/node_modules/dep.js", bytes: 1000)
        fx.file("home/protected/node_modules/IMPORTANT.txt", bytes: 10)
        let plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("home/proj/node_modules"))])
        var ex = testExecutor(fx)
        ex.pathGuard = PathGuard(allowedRoots: [fx.path("home")], protectedPaths: [fx.path("home/protected")], minimumDepth: 2)
        let swapRoot = fx.path("home")
        ex.beforeDestructiveStep = { _ in
            // Attacker/concurrent process swaps the validated parent for a symlink to protected data.
            try? FileManager.default.moveItem(atPath: swapRoot + "/proj", toPath: swapRoot + "/proj.old")
            try? FileManager.default.createSymbolicLink(atPath: swapRoot + "/proj", withDestinationPath: swapRoot + "/protected")
        }
        let report = try ex.execute(plan: plan, approval: CleanupApproval(plan: plan, approver: "t"), dryRun: false)
        #expect(report.results[0].status == .skipped)
        #expect(fx.exists("home/protected/node_modules/IMPORTANT.txt"), "protected data must survive")
        #expect(fx.exists("home/proj.old/node_modules/dep.js"), "nothing else removed either")
    }

    @Test func stagedDeleteFailureRestoresOriginal() throws {
        let fx = Fixture("restore")
        fx.file("cache/x.bin", bytes: 1000)
        let ops = FakeFileOps()
        ops.failPaths = [fx.path("cache")]
        let plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("cache"))])
        let report = try testExecutor(fx, ops: ops).execute(plan: plan, approval: CleanupApproval(plan: plan, approver: "t"), dryRun: false)
        #expect(report.results[0].status == .failed)
        #expect(report.results[0].message.contains("restored"))
        #expect(fx.exists("cache/x.bin"), "a failed delete must leave the item where it was")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: fx.path(".staging"))) ?? []).isEmpty)
    }

    @Test func digestCoversOwnerHintsAndElevation() {
        let fx = Fixture("digest")
        fx.dir("a")
        var plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("a"), owners: ["/Example.app/"])])
        let d1 = plan.digest
        plan.items[0].ownerProcessHints = []
        #expect(plan.digest != d1, "removing in-use hints after approval must invalidate the approval")
        plan.items[0].ownerProcessHints = ["/Example.app/"]
        #expect(plan.digest == d1)
        plan.items[0].requiresElevation = true
        #expect(plan.digest != d1)
    }

    @Test func unknownProcessListSkipsItemsWithOwners() throws {
        let fx = Fixture("noprocs")
        fx.file("appcache/x.bin", bytes: 100)
        fx.file("plain/y.bin", bytes: 100)
        let plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("appcache"), owners: ["/Foo.app/"]), makeRec(fx.path("plain"))])
        let report = try testExecutor(fx, running: nil).execute(plan: plan, approval: CleanupApproval(plan: plan, approver: "t"), dryRun: false)
        #expect(report.results[0].status == .skipped && report.results[0].message.contains("running"))
        #expect(fx.exists("appcache/x.bin"))
        #expect(report.results[1].status == .succeeded)
    }

    @Test func inUseMatchingIsCaseInsensitive() {
        let procs = [RunningProcess(executable: "/Applications/Obsidian.app/Contents/MacOS/Obsidian", commandLine: "Obsidian")]
        #expect(ProcessProbe.matches(hints: ["/obsidian.app/"], running: procs) == ["Obsidian"])
    }

    @Test func commandTimeoutEscalatesToKill() throws {
        let start = Date()
        let o = try ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; /bin/sleep 30"], timeout: 0.5)
        #expect(o.timedOut)
        #expect(Date().timeIntervalSince(start) < 12, "a TERM-ignoring command must be killed")
    }
}
