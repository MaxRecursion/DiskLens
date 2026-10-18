import Testing
import Foundation
import Darwin
@testable import DiskLensCore

@Suite("App Store edition (sandbox-aware behaviour)")
struct PlatformTests {
    @Test func realHomeIsTheUsersHomeOutsideTheSandbox() {
        #expect(!Platform.isSandboxed)
        #expect(Platform.realHome == (PathUtil.canonical(NSHomeDirectory()) ?? NSHomeDirectory()))
        #expect(Platform.canRunExternalTools)
    }

    @Test func spotlightDateIsNilForMissingFiles() {
        #expect(Platform.spotlightDate("/nonexistent/\(UUID().uuidString)", attribute: kMDItemLastUsedDate) == nil)
    }

    @Test func partialProcessListMarksCommandLineOwnersUnverified() {
        let facts = EnvironmentFacts(home: "/Users/x",
                                     running: [RunningProcess(executable: "/Applications/Foo.app/Contents/MacOS/Foo", commandLine: "/Applications/Foo.app")],
                                     installedApps: [:], processListAvailable: true, processListComplete: false)
        #expect(facts.isRunning(hints: ["/Foo.app/"]) == ["Foo"])                    // apps are visible
        #expect(facts.isRunning(hints: ["/Bar.app/"]) == [ProcessProbe.unverifiedMarker]) // not seen ≠ not running
        #expect(facts.isRunning(hints: ["npm-cli.js install"]) == [ProcessProbe.unverifiedMarker])
        #expect(facts.isRunning(hints: []).isEmpty)
    }

    @Test func executorProceedsForUnverifiedCLIOwnersButSkipsRunningApps() throws {
        let fx = Fixture("partial")
        fx.file("npmcache/x.bin", bytes: 1000)
        fx.file("appcache/y.bin", bytes: 1000)
        var ex = testExecutor(fx)
        ex.runningProcesses = { ProcessSnapshot(processes: [RunningProcess(executable: "/Applications/Foo.app/Contents/MacOS/Foo", commandLine: "x")], complete: false) }
        let plan = CleanupPlan(scanID: nil, items: [makeRec(fx.path("npmcache"), owners: ["npm-cli.js install"]),
                                                    makeRec(fx.path("appcache"), owners: ["/Foo.app/"])])
        let report = try ex.execute(plan: plan, approval: CleanupApproval(plan: plan, approver: "t"), dryRun: false)
        #expect(report.results[0].status == .succeeded)   // user saw the "unverified" warning and approved
        #expect(report.results[1].status == .skipped)     // Foo is running
        #expect(fx.exists("appcache/y.bin"))
    }

    @Test func recommendationsWithoutNewFieldsStillDecode() throws {
        let fx = Fixture("codable")
        fx.dir("a")
        var r = makeRec(fx.path("a"))
        r.suggestedCommand = "brew cleanup --prune=all"
        let data = try JSONEncoder().encode(r)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "suggestedCommand")
        let old = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(Recommendation.self, from: old)
        #expect(decoded.suggestedCommand == nil && decoded.id == r.id)
    }

    @Test func missingLaunchAgentsFolderMeansNoneButUnreadableMeansUnknown() {
        let fx = Fixture("agents")
        #expect(EnvironmentFacts.userLaunchAgents(home: fx.root) == [:])      // folder absent: no agents
        fx.dir("Library/LaunchAgents")
        chmod(fx.path("Library/LaunchAgents"), 0o000)
        defer { chmod(fx.path("Library/LaunchAgents"), 0o755) }
        #expect(EnvironmentFacts.userLaunchAgents(home: fx.root) == nil)      // unreadable: unknown
    }

    @Test func unknownLaunchAgentsRaiseNodeModulesRisk() throws {
        let fx = Fixture("agents-risk")
        fx.file("proj/package.json", bytes: 40)
        fx.file("proj/package-lock.json", bytes: 40)
        fx.file("proj/node_modules/x/a.js", bytes: 60_000_000)
        var tree = try fx.scan().tree
        Classifier.classify(&tree, rules: Classifier.defaultRules(home: fx.root))
        var facts = EnvironmentFacts(home: fx.root, running: [], installedApps: [:])
        facts.launchAgentsReadable = false
        let recs = RecommendationEngine.analyze(tree: tree, rules: RuleCatalog.standard(home: fx.root), facts: facts).recommendations
        let nm = try #require(recs.first { $0.targetPath == fx.path("proj/node_modules") })
        #expect(nm.risk == .medium)
        #expect(nm.notes.contains { $0.contains("could not be checked") })
    }
}
