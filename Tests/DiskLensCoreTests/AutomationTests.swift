import Testing
import Foundation
@testable import DiskLensCore

@Suite("Scheduling and low-space alerts")
struct ScheduleTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    func at(_ day: Int, _ hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func offNeverRunsAndFirstScanRunsImmediately() {
        #expect(!ScanSchedule(frequency: .off).isDue(lastScan: nil, now: at(16, 12), calendar: cal))
        #expect(ScanSchedule(frequency: .daily).isDue(lastScan: nil, now: at(16, 3), calendar: cal))
    }

    @Test func dailyWaitsForThePreferredHourUnlessOverdue() {
        let s = ScanSchedule(frequency: .daily, preferredHour: 10)
        #expect(!s.isDue(lastScan: at(15, 10), now: at(16, 6), calendar: cal))     // due, but before 10:00
        #expect(s.isDue(lastScan: at(15, 10), now: at(16, 10), calendar: cal))
        #expect(!s.isDue(lastScan: at(16, 2), now: at(16, 12), calendar: cal))     // scanned today
        #expect(s.isDue(lastScan: at(13, 10), now: at(16, 1), calendar: cal))      // overdue (Mac was asleep)
    }

    @Test func weeklyInterval() {
        let s = ScanSchedule(frequency: .weekly, preferredHour: 0)
        #expect(!s.isDue(lastScan: at(10, 12), now: at(16, 12), calendar: cal))
        #expect(s.isDue(lastScan: at(9, 12), now: at(16, 12), calendar: cal))
    }

    @Test func lowSpaceAlertsOnceThenRearmsAfterRecovery() {
        var m = LowSpaceMonitor(thresholdBytes: 20_000_000_000, rearmMarginBytes: 2_000_000_000, repeatInterval: 86_400)
        let t = at(16, 12)
        func step(_ avail: Int64, _ dt: TimeInterval) -> Bool { m.evaluate(availableBytes: avail, now: t.addingTimeInterval(dt)) }
        #expect(!step(25_000_000_000, 0))
        #expect(step(19_000_000_000, 0))                         // first drop: alert
        #expect(!step(18_000_000_000, 600)) // no nagging
        #expect(!step(20_500_000_000, 700)) // within margin: still disarmed
        #expect(!step(19_900_000_000, 800))
        #expect(!step(23_000_000_000, 900)) // recovered: re-armed
        #expect(step(19_000_000_000, 1000))
        #expect(step(19_000_000_000, 1000 + 86_400))  // still low a day later
    }
}

@Suite("CLI cleanup policies")
struct PolicyTests {
    func recs() -> [Recommendation] {
        var inUse = rec(rule: "npm-cache", bytes: 3_000_000_000)
        inUse.id = "npm-in-use"; inUse.inUseBy = ["node"]
        var elevated = rec(rule: "pip-cache", bytes: 900_000_000); elevated.id = "elevated"; elevated.requiresElevation = true
        return [rec(rule: "npm-cache", bytes: 4_000_000_000), rec(rule: "xcode-deriveddata", bytes: 2_000_000_000),
                rec(rule: "node-modules", tier: .conditional, bytes: 5_000_000_000),
                rec(rule: "app-cache:Code Cache", bytes: 100_000_000), inUse, elevated,
                rec(rule: "large-file", tier: .manualReview, bytes: 50_000_000_000, kind: .manualReview)]
    }

    @Test func notTriggeredWhileFreeSpaceIsAboveTheThreshold() throws {
        let p = CleanupPolicy(name: "low-space", whenFreeBelowGB: 20, tiers: [1])
        let e = try p.evaluate(recommendations: recs(), availableBytes: 25_000_000_000, scanID: nil)
        #expect(!e.triggered && e.plan == nil)
        let unknown = try p.evaluate(recommendations: recs(), availableBytes: nil, scanID: nil)
        #expect(!unknown.triggered)
    }

    @Test func selectsOnlyEligibleItemsOfTheAllowedTiersAndRules() throws {
        let p = CleanupPolicy(name: "ci", whenFreeBelowGB: 20, tiers: [1], rules: ["npm-cache", "app-cache:"])
        let e = try p.evaluate(recommendations: recs(), availableBytes: 10_000_000_000, scanID: nil)
        #expect(e.triggered)
        #expect(Set(e.plan!.items.map(\.ruleID)) == ["npm-cache", "app-cache:Code Cache"])
        #expect(e.excluded.contains { $0.id == "npm-in-use" })
        #expect(!e.plan!.items.contains { $0.tier == .manualReview || $0.tier == .conditional })
    }

    @Test func tierThreeCanNeverBePartOfAPolicy() {
        #expect(throws: CleanupPolicy.PolicyError.invalidTier(3)) {
            try CleanupPolicy(name: "x", tiers: [1, 3]).evaluate(recommendations: [], availableBytes: 0, scanID: nil)
        }
        #expect(throws: CleanupPolicy.PolicyError.emptyTiers) { try CleanupPolicy(name: "x", tiers: []).validate() }
    }

    @Test func budgetTrashModeAndJSONDecoding() throws {
        let json = #"{"name":"trash-small","tiers":[1,2],"action":"trash","maxTotalGB":9.5,"minItemMB":500}"#
        let p = try JSONDecoder().decode(CleanupPolicy.self, from: Data(json.utf8))
        let e = try p.evaluate(recommendations: recs(), availableBytes: 1, scanID: nil)
        let items = e.plan!.items
        #expect(items.allSatisfy { $0.action.kind == .moveToTrash })
        #expect(items.map(\.ruleID) == ["node-modules", "npm-cache"])   // 5 + 4 GB; the 2 GB item would exceed 9.5
        #expect(e.excluded.contains { $0.reason == "would exceed maxTotalGB" })
        #expect(e.excluded.contains { $0.reason == "below minItemMB" })
    }
}

@Suite("Report export and scan history")
struct ReportTests {
    @Test func markdownAndJSONContainMeasurementsButNoFileContents() throws {
        let fx = Fixture("report")
        fx.file("proj/secret.env", bytes: 3 << 20, fill: 0x41)    // content "AAAA…" must never appear
        fx.file("proj/node_modules/pkg/index.js", bytes: 2 << 20)
        var scan = try fx.scan()
        Classifier.classify(&scan.tree, rules: Classifier.defaultRules(home: fx.root))
        let recs = [makeRec(fx.path("proj/node_modules"), bytes: 2 << 20)]
        let r = ReportExporter.build(scan: scan, recommendations: recs, changes: [], cleanups: [], history: [], appVersion: "test")
        let md = ReportExporter.markdown(r, home: fx.root)
        let json = String(decoding: try ReportExporter.json(r), as: UTF8.self)
        for s in [md, json] {
            #expect(!s.contains("AAAAAAAA"))
            #expect(!s.contains(ProcessInfo.processInfo.hostName) || ProcessInfo.processInfo.hostName.isEmpty)
        }
        #expect(md.contains("# DiskLens report") && md.contains("node_modules") && md.contains("estimate"))
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(decoded?["format"] as? String == "disklens-report/1")
        #expect(decoded?["scannedAllocatedBytes"] as? Int64 == scan.tree.totalAllocated)
    }

    @Test func unknownSizesAreReportedAsUnknownNotZero() throws {
        let fx = Fixture("report-unknown")
        fx.file("a/big.bin", bytes: 2 << 20)
        var opts = ScanOptions(roots: [fx.root])
        opts.assumeBlocked = [fx.dir("a/locked")]
        var scan = try DiskScanner.scanSync(options: opts)
        Classifier.classify(&scan.tree, rules: Classifier.defaultRules(home: fx.root))
        let r = ReportExporter.build(scan: scan, recommendations: [], changes: [], cleanups: [], history: [], appVersion: "t")
        let md = ReportExporter.markdown(r, home: fx.root)
        #expect(md.contains("unknown"))
        #expect(r.coverage.privacyBlocked.count == 1)
    }

    @Test func historyRecordsEveryScanNewestFirst() throws {
        let fx = Fixture("history")
        fx.file("x/a.bin", bytes: 2 << 20)
        let store = ScanStore(directory: URL(fileURLWithPath: fx.dir("store")))
        let first = try fx.scan(roots: [fx.path("x")])
        try store.save(first)
        fx.file("x/b.bin", bytes: 3 << 20)
        let second = try fx.scan(roots: [fx.path("x")])
        try store.save(second)
        let h = store.loadHistory()
        #expect(h.map(\.scanID) == [second.manifest.scanID, first.manifest.scanID])
        #expect(h[0].scannedAllocated > h[1].scannedAllocated)
    }
}
