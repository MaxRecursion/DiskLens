import Foundation
import DiskLensCore

// disklens-cli — headless front end to DiskLensCore (direct edition).
//   scan       read-only scan of the default scope (or --root PATH ...); saves to the DiskLens store
//   recommend  analyse the latest scan, refine reclaim estimates, write recommendations JSON/Markdown
//   plan       build a cleanup plan from recommendation ids (or --tier1) and print its preview + digest
//   execute    dry-run or execute a saved plan; real execution needs --approve <plan digest> + a license
//   policy     evaluate a cleanup policy (dry run by default; --execute needs a Pro/Team license)
//   export     write a Markdown or JSON report (Pro/Team)
//   license    status | activate --key-file FILE | deactivate
//   report     print the latest scan manifest summary
//
// Free without a license: scan, recommend, plan, execute --dry-run, policy (dry run), report, license.
// Exit codes: 0 ok · 1 error · 2 usage · 3 approval refused · 4 license required ·
//             5 some items failed · 6 policy executed but free space is still below its threshold.

setvbuf(stdout, nil, _IOLBF, 0)
DatalessPolicy.disableMaterialization()
let args = Array(CommandLine.arguments.dropFirst())
let store = ScanStore()
let home = Platform.realHome

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func values(_ flag: String) -> [String] {
    var out: [String] = []
    for (i, a) in args.enumerated() where a == flag && i + 1 < args.count { out.append(args[i + 1]) }
    return out
}
func flag(_ f: String) -> Bool { args.contains(f) }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func gb(_ b: Int64) -> String { ByteFormat.gb(b) }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

let recsURL = store.directory.appendingPathComponent("latest-recommendations.json")
let jsonOut = flag("--json")

/// The CLI honours license keys (file: ~/Library/Application Support/DiskLens/license.dlk or
/// $DISKLENS_LICENSE_FILE). It does not read the app's Keychain trial, so it never triggers Keychain
/// prompts on headless/CI machines.
@MainActor func licenseService() -> LicenseService {
    let s = LicenseService(edition: .direct, purchaseStore: NoPurchaseStore(), secure: InMemorySecureStore(),
                           licenseFile: LicenseFileStore.fromEnvironment())
    s.prepare()
    return s
}

func exitWith(_ code: CLIExitCode) -> Never { exit(code.rawValue) }

@MainActor func requireLicense(_ feature: Feature, for what: String) {
    let l = licenseService()
    guard l.isEnabled(feature) else {
        err("\(what) requires a DiskLens Pro or Team license (\(feature.displayName)). Previews and dry runs are free.")
        if let p = l.licenseProblem { err("License problem: \(p)") }
        err("Activate one with: disklens-cli license activate --key-file FILE")
        exitWith(.licenseRequired)
    }
}

func printJSON<T: Encodable>(_ v: T) {
    if let d = try? encoder().encode(v) { print(String(decoding: d, as: UTF8.self)) }
}

func encoder() -> JSONEncoder {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
}
func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

func runScan(quiet: Bool = false) async throws {
    var opts = ScanOptions.defaultScope(home: home)
    let roots = values("--root")
    if !roots.isEmpty { opts.roots = roots }
    if let t = value("--threshold-mb"), let mb = Int64(t) { opts.fileNodeThreshold = mb << 20 }
    err("Scanning (read-only): \(opts.roots.joined(separator: ", "))")
    let started = Date()
    var result = try await DiskScanner.scan(options: opts) { p in
        err(String(format: "  [%d/%d] %@  files=%lld  %@  errors=%d  at %@", p.rootIndex + 1, p.rootCount,
                   PathUtil.abbreviated(p.currentRoot), p.filesVisited, ByteFormat.string(p.bytesAllocated), p.errors,
                   PathUtil.abbreviated(p.currentPath)))
    }
    Classifier.classify(&result.tree, rules: Classifier.defaultRules(home: home))
    let changes = flag("--no-save") ? [] : try store.save(result)
    let m = result.manifest
    let t = result.tree
    if quiet { return }
    if jsonOut {
        struct Summary: Encodable {
            var scanID: UUID; var finishedAt: Date; var durationSeconds: Double; var roots: [String]
            var volume: VolumeSnapshot?; var scannedAllocatedBytes: Int64; var scannedLogicalBytes: Int64; var files: Int64
            var categories: [String: Int64]; var unreadableFolders: Int64; var errorCount: Int; var privacyBlocked: [String]
            var changes: [ScanChange]
        }
        printJSON(Summary(scanID: m.scanID, finishedAt: m.finishedAt, durationSeconds: m.duration, roots: m.effectiveRoots,
                          volume: m.volumeBefore, scannedAllocatedBytes: t.totalAllocated, scannedLogicalBytes: t.totalLogical,
                          files: t.nodes[0].fileCount,
                          categories: Dictionary(uniqueKeysWithValues: t.categoryTotals().filter { $0.key != .inaccessible }.map { ($0.key.rawValue, $0.value.allocated) }),
                          unreadableFolders: m.stats.unreadableDirectories, errorCount: m.errorCount, privacyBlocked: m.privacyBlockedPaths,
                          changes: changes))
        return
    }
    print("Scan \(m.scanID.uuidString) finished in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
    if let v = m.volumeBefore {
        print("Volume '\(v.volumeName)': capacity \(gb(v.totalBytes)), used \(gb(v.usedBytes)), available \(gb(v.availableBytes)) (+\(gb(v.purgeableBytes)) purgeable per macOS)")
    }
    print("Scanned allocated: \(gb(t.totalAllocated))  logical: \(gb(t.totalLogical))  files: \(t.nodes[0].fileCount)  dirs: \(m.stats.directoriesVisited)")
    print("Coverage: \(m.stats.unreadableDirectories) unreadable dirs, \(m.stats.statFailures) stat failures, \(m.stats.symlinksNotFollowed) symlinks not followed, \(m.stats.hardLinkDuplicatesSkipped) hard-link duplicates skipped, \(m.stats.mountPointsNotCrossed) mount points not crossed, \(m.stats.datalessFiles) cloud-only files + \(m.stats.datalessDirectories) cloud-only folders (not downloaded)")
    if !m.droppedOverlappingRoots.isEmpty { print("Dropped overlapping roots: \(m.droppedOverlappingRoots)") }
    if !m.missingRoots.isEmpty { print("Missing roots: \(m.missingRoots)") }
    for p in m.privacyBlockedPaths {
        print("⚠︎ NOT SCANNED: \(PathUtil.abbreviated(p)) — macOS did not grant access in time (a privacy prompt may be waiting, or access was denied). Its size is unknown, not zero.")
    }
    print("\nBy category (each byte counted once):")
    for (c, v) in t.categoryTotals().sorted(by: { $0.value.allocated > $1.value.allocated }) {
        if c == .inaccessible {
            print("  \(pad(c.displayName, 36)) \(lpad("unknown", 10))  (\(m.stats.unreadableDirectories) unreadable folders — size cannot be measured)")
        } else {
            print("  \(pad(c.displayName, 36)) \(lpad(gb(v.allocated), 10))  (\(v.files) files)")
        }
    }
    print("\nLargest folders (depth ≤ 3 below each root):")
    var dirs: [(Int32, Int64)] = []
    t.walk { id, n in
        guard id != ScanTree.root, n.isDirectory else { return true }
        let d = t.depth(of: id)
        if d >= 2 && d <= 4 { dirs.append((id, n.allocated)) }
        return d < 4
    }
    // Skip a folder whose parent is listed and holds (almost) the same bytes: same space, not new info.
    let listedIDs = Set(dirs.map(\.0))
    let shown = dirs.filter { id, a in
        let p = t.nodes[Int(id)].parent
        return !(listedIDs.contains(p) && Double(a) >= 0.95 * Double(t.nodes[Int(p)].allocated))
    }
    for (id, a) in shown.sorted(by: { $0.1 > $1.1 }).prefix(Int(value("--top") ?? "25") ?? 25) {
        print("  \(lpad(gb(a), 10))  \(PathUtil.abbreviated(t.path(of: id)))")
    }
    if !changes.isEmpty {
        print("\nChanges since previous scan:")
        for c in changes.prefix(15) { print("  \(lpad((c.delta >= 0 ? "+" : "") + ByteFormat.string(c.delta), 11))  \(PathUtil.abbreviated(c.path))") }
    }
    let gaps = Dictionary(grouping: m.errors, by: { e -> String in
        let comps = PathUtil.abbreviated(e.path).split(separator: "/").prefix(3)
        return comps.joined(separator: "/")
    })
    print("\nCoverage gaps (\(m.errorCount) unreadable entries; sizes unknown, NOT zero):")
    for (k, v) in gaps.sorted(by: { $0.value.count > $1.value.count }).prefix(12) { print("  \(lpad(String(v.count), 4)) × \(k)  [\(v.first?.message ?? "")]") }
}

func runRecommend() async throws {
    guard let scan = store.loadLatest() else { err("No saved scan. Run: disklens-cli scan"); exitWith(.usage) }
    err("Probing environment (running processes, installed apps)…")
    let facts = EnvironmentFacts.probe(home: home)
    var analysis = RecommendationEngine.analyze(tree: scan.tree, rules: RuleCatalog.standard(home: home), facts: facts)
    if await MainActor.run(body: { licenseService().isEnabled(.duplicates) }) {
        err("Looking for byte-identical duplicate files (SHA-256, in memory only)…")
        let dups = DuplicateFinder.analyze(tree: scan.tree, home: home, existing: analysis.recommendations)
        err("  hashed \(dups.filesHashed) files (\(ByteFormat.string(dups.bytesHashed)))\(dups.truncated ? " — hash budget reached, coverage partial" : "")")
        analysis.recommendations += dups.recommendations
    } else {
        err("Duplicate finder skipped (Pro/Team license).")
    }
    if !flag("--no-refine") {
        err("Refining reclaim estimates with APFS private-size walks…")
        analysis.recommendations = await RecommendationEngine.refineEstimates(analysis.recommendations, progress: { d, n in
            err("  estimated \(d)/\(n)")
        })
        analysis.recommendations = await RuleCatalog.refineCommandEstimates(analysis.recommendations)
    }
    let recs = analysis.recommendations
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try encoder().encode(recs).write(to: recsURL, options: .atomic)
    if let md = value("--markdown") { try RuleCatalog.markdown(recs, scan: scan).write(toFile: md, atomically: true, encoding: .utf8) }
    if jsonOut { printJSON(recs); return }
    for tier in CleanupTier.allCases {
        let items = recs.filter { $0.tier == tier }
        let total = items.reduce(Int64(0)) { $0 + $1.estimatedReclaimable }
        print("\n\(tier.label) — \(items.count) items, est. reclaimable \(gb(total))")
        for r in items.sorted(by: { $0.estimatedReclaimable > $1.estimatedReclaimable }) {
            let users = r.inUseBy.prefix(3).joined(separator: ", ") + (r.inUseBy.count > 3 ? " +\(r.inUseBy.count - 3)" : "")
            let flags = (r.inUseBy.isEmpty ? "" : " [IN USE: \(users)]") + (r.analysisComplete ? "" : " [partial]")
            print("  \(lpad(gb(r.estimatedReclaimable), 9)) / \(lpad(gb(r.detectedAllocated), 9)) \(pad(r.risk.rawValue, 6)) \(pad(r.confidence.rawValue, 6)) \(r.title)\(flags)")
            print("      \(r.action.displayString)")
            if flag("--verbose") { print("      id: \(r.id)\n      why: \(r.reason)") }
        }
    }
    print("\nSaved \(recs.count) recommendations to \(recsURL.path)")
}

func loadRecs() -> [Recommendation] {
    guard let d = try? Data(contentsOf: recsURL), let r = try? decoder().decode([Recommendation].self, from: d) else {
        err("No recommendations. Run: disklens-cli recommend"); exit(2)
    }
    return r
}

func printPreview(_ plan: CleanupPlan) {
    print("Cleanup plan \(plan.id.uuidString)")
    print("Items: \(plan.items.count)   Selected (allocated): \(gb(plan.totalSelectedBytes))   Estimated reclaimable: \(gb(plan.totalEstimatedReclaimable))")
    for r in plan.items {
        print("  • [\(r.tier.label)] \(r.title) — est. \(gb(r.estimatedReclaimable))")
        print("      \(r.action.displayString)")
        print("      Impact: \(r.consequences)")
        if !r.inUseBy.isEmpty { print("      ⚠︎ In use by \(r.inUseBy.joined(separator: ", ")) — will be skipped unless quit") }
        if !r.analysisComplete { print("      ⚠︎ Not fully analysed") }
    }
    print("Requires administrator privileges: \(plan.elevatedItems.isEmpty ? "no" : "yes (\(plan.elevatedItems.count) items — will be skipped)")")
    print("Plan digest (approval token): \(plan.digest)")
}

func runPlan() throws {
    let recs = loadRecs()
    var chosen: [Recommendation]
    if flag("--tier1") {
        chosen = recs.filter { $0.tier == .low && $0.eligibleForAutoSelection }
    } else {
        let ids = Set(values("--select").flatMap { $0.split(separator: ",").map(String.init) })
        chosen = recs.filter { ids.contains($0.id) }
        let missing = ids.subtracting(chosen.map(\.id))
        if !missing.isEmpty { err("Unknown recommendation ids: \(missing.sorted())"); exit(2) }
    }
    if flag("--trash") {
        chosen = chosen.map { var r = $0; if r.action.kind == .deletePermanently { r.action = .trash(r.targetPath) }; return r }
        let cmds = chosen.filter { $0.action.kind == .runCommand }
        if !cmds.isEmpty { err("⚠︎ --trash: \(cmds.count) command item(s) (\(cmds.map(\.title).joined(separator: ", "))) cannot be moved to Trash and remain permanent.") }
    }
    guard !chosen.isEmpty else { err("Nothing selected."); exit(2) }
    let plan = CleanupPlan(scanID: store.loadLatest()?.manifest.scanID, items: chosen)
    let out = value("--out") ?? store.directory.appendingPathComponent("plan-\(plan.id.uuidString.prefix(8)).json").path
    try FileManager.default.createDirectory(atPath: PathUtil.parent(out), withIntermediateDirectories: true)
    try encoder().encode(plan).write(to: URL(fileURLWithPath: out), options: .atomic)
    printPreview(plan)
    print("Saved plan to \(out)")
    print("Dry run:  disklens-cli execute --plan '\(out)' --dry-run")
    print("Execute:  disklens-cli execute --plan '\(out)' --approve \(plan.digest)")
}

func runExecute() throws {
    guard let p = value("--plan"), let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
          let plan = try? decoder().decode(CleanupPlan.self, from: d) else { err("Missing or unreadable --plan"); exit(2) }
    let dry = flag("--dry-run")
    var approval: CleanupApproval? = nil
    if !dry {
        guard let token = value("--approve") else { err("Refusing to execute without --approve <plan digest>. Use --dry-run to preview."); exitWith(.approvalRefused) }
        guard token == plan.digest else { err("Approval token does not match this plan's digest. Nothing was changed."); exitWith(.approvalRefused) }
        MainActor.assumeIsolated { requireLicense(.cli, for: "Executing a cleanup from the command line") }
        approval = CleanupApproval(plan: plan, approver: "cli:\(NSUserName())")
    }
    if !jsonOut { printPreview(plan) }
    let report = try CleanupExecutor().execute(plan: plan, approval: approval, dryRun: dry) { i, n, title in
        err("[\(i + 1)/\(n)] \(title)")
    }
    if !dry { _ = try? store.saveReport(report) }
    if jsonOut { printJSON(report); if !report.failed.isEmpty { exitWith(.partialFailure) }; return }
    print("\n\(dry ? "DRY RUN — nothing modified" : "EXECUTED")")
    for r in report.results {
        print("  \(pad(r.status.rawValue, 18)) \(r.title): \(r.message)")
        if let b = r.bytesBefore { print("      before \(ByteFormat.string(b))\(r.bytesAfter.map { ", after " + ByteFormat.string($0) } ?? "")") }
        if let o = r.commandOutput, !o.isEmpty { print("      output: \(o.split(separator: "\n").suffix(3).joined(separator: " | "))") }
    }
    if let delta = report.measuredFreeSpaceDelta {
        print("Measured free-space change: \(delta >= 0 ? "+" : "")\(ByteFormat.string(delta))  (estimated: \(ByteFormat.string(report.estimatedTotal)))")
    }
    for u in report.unexpected { print("⚠︎ \(u)") }
    for f in report.followUp { print("→ \(f)") }
    if !dry { print("Report saved in \(store.directory.appendingPathComponent("reports").path)") }
    if !report.failed.isEmpty { exitWith(.partialFailure) }
}

/// policy --policy FILE [--rescan] [--execute] [--json]
func runPolicy() async throws {
    guard let file = value("--policy") else { err("usage: disklens-cli policy --policy FILE [--rescan] [--execute] [--json]"); exitWith(.usage) }
    let policy: CleanupPolicy
    do { policy = try CleanupPolicy.load(from: URL(fileURLWithPath: file)) } catch {
        err("Invalid policy \(file): \(error)"); exitWith(.usage)
    }
    let execute = flag("--execute")
    if execute { await MainActor.run { requireLicense(.cli, for: "Executing a policy") } }
    if flag("--rescan") || store.loadLatest() == nil { try await runScan(quiet: true) }
    guard let scan = store.loadLatest() else { err("No scan available."); exitWith(.error) }
    let before = VolumeInfo.snapshot()
    var recs = RecommendationEngine.analyze(tree: scan.tree, rules: RuleCatalog.standard(home: home), facts: EnvironmentFacts.probe(home: home)).recommendations
    recs = await RecommendationEngine.refineEstimates(recs)
    recs = await RuleCatalog.refineCommandEstimates(recs)
    let eval = try policy.evaluate(recommendations: recs, availableBytes: before?.availableBytes, scanID: scan.manifest.scanID)

    struct Output: Encodable {
        var policy: String
        var triggered: Bool
        var dryRun: Bool
        var availableBytes: Int64?
        var thresholdBytes: Int64?
        var planDigest: String?
        var items: [String]
        var estimatedReclaimableBytes: Int64
        var excluded: [CleanupPolicy.Exclusion]
        var report: CleanupReport?
        var availableAfterBytes: Int64?
    }
    var out = Output(policy: policy.name, triggered: eval.triggered, dryRun: !execute, availableBytes: eval.availableBytes,
                     thresholdBytes: eval.thresholdBytes, planDigest: eval.plan?.digest, items: eval.plan?.items.map(\.id) ?? [],
                     estimatedReclaimableBytes: eval.plan?.totalEstimatedReclaimable ?? 0, excluded: eval.excluded, report: nil,
                     availableAfterBytes: nil)
    var code = CLIExitCode.ok
    if let plan = eval.plan {
        // The policy file plus --execute is the approval; it is bound to this exact plan's digest.
        let approval = execute ? CleanupApproval(plan: plan, approver: "policy:\(policy.name):\(NSUserName())") : nil
        let report = try CleanupExecutor().execute(plan: plan, approval: approval, dryRun: !execute)
        if execute { _ = try? store.saveReport(report) }
        out.report = report
        out.availableAfterBytes = report.volumeAfter?.availableBytes
        if !report.failed.isEmpty { code = .partialFailure }
        if execute, code == .ok, let t = eval.thresholdBytes, let a = out.availableAfterBytes, a < t { code = .stillBelowThreshold }
    }
    if jsonOut {
        printJSON(out)
    } else {
        print("Policy “\(policy.name)”: \(eval.triggered ? "TRIGGERED" : "not triggered")"
              + (eval.availableBytes.map { " — free \(gb($0))" } ?? "") + (eval.thresholdBytes.map { ", threshold \(gb($0))" } ?? ""))
        if let plan = eval.plan {
            printPreview(plan)
            if let r = out.report {
                print(execute ? "\nEXECUTED" : "\nDRY RUN — nothing modified (add --execute to clean)")
                for x in r.results { print("  \(pad(x.status.rawValue, 18)) \(x.title): \(x.message)") }
                if let d = r.measuredFreeSpaceDelta, execute { print("Measured free-space change: \(d >= 0 ? "+" : "")\(ByteFormat.string(d))") }
            }
        } else if eval.triggered {
            print("Nothing eligible to clean.")
        }
        for x in eval.excluded.prefix(20) { print("  excluded \(x.id): \(x.reason)") }
    }
    exitWith(code)
}

@MainActor func runLicense() throws {
    let sub = args.dropFirst().first
    let s = licenseService()
    let file = LicenseFileStore.fromEnvironment()
    switch sub {
    case "activate":
        guard let path = value("--key-file") else { err("usage: disklens-cli license activate --key-file FILE   (use - for stdin)"); exitWith(.usage) }
        let text = path == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                               : ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
        do {
            let p = try s.activate(licenseKey: text)
            print("Activated \(p.edition.rawValue) license \(p.licenseID.prefix(8))… (\(p.seats) seat\(p.seats == 1 ? "" : "s"))\(p.expiresAt.map { ", valid until \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "").")
            print("Stored in \(file.url.path) (mode 0600).")
        } catch let e as LicenseKeyError {
            err(e.description); exitWith(.licenseRequired)
        }
    case "deactivate":
        try s.deactivateLicense()
        print("License removed from this Mac.")
    case "machine-id":
        // Salted SHA-256 of the hardware UUID, for per-machine Team keys (not reversible).
        guard let h = MachineIdentity.hash() else { err("Could not read the machine identity."); exitWith(.error) }
        print(h)
    default:
        struct Status: Encodable { var plan: String; var edition: String?; var licenseID: String?; var seats: Int?; var expires: Date?; var problem: String?; var features: [String] }
        let lic = s.activeLicense
        let st = Status(plan: s.state.label, edition: lic?.edition.rawValue, licenseID: lic.map { String($0.licenseID.prefix(8)) + "…" },
                        seats: lic?.seats, expires: lic?.expiresAt, problem: s.licenseProblem,
                        features: Feature.allCases.filter { s.isEnabled($0) }.map(\.rawValue))
        if jsonOut { printJSON(st); return }
        print("Plan: \(st.plan)")
        if let lic { print("License: \(lic.edition.rawValue) · \(st.licenseID ?? "") · \(lic.seats) seat(s)\(lic.expiresAt.map { " · expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")") }
        if let p = s.licenseProblem { print("Problem: \(p)") }
        print("Enabled: \(st.features.isEmpty ? "free features only" : st.features.joined(separator: ", "))")
        print("Key file: \(file.url.path)")
    }
}

func runExport() throws {
    MainActor.assumeIsolated { requireLicense(.reportExport, for: "Report export") }
    guard let scan = store.loadLatest() else { err("No saved scan. Run: disklens-cli scan"); exitWith(.usage) }
    let recs = (try? decoder().decode([Recommendation].self, from: Data(contentsOf: recsURL))) ?? []
    let r = ReportExporter.build(scan: scan, recommendations: recs, changes: store.changesSincePrevious(), cleanups: store.loadReports(),
                                 history: store.loadHistory(), appVersion: "cli")
    var wrote = false
    if let md = value("--markdown") { try ReportExporter.markdown(r).write(toFile: md, atomically: true, encoding: .utf8); print("Wrote \(md)"); wrote = true }
    if let js = value("--json-file") { try ReportExporter.json(r).write(to: URL(fileURLWithPath: js), options: .atomic); print("Wrote \(js)"); wrote = true }
    if !wrote { err("usage: disklens-cli export [--markdown FILE] [--json-file FILE]"); exitWith(.usage) }
}

func runReport() {
    guard let s = store.loadLatest() else { err("No saved scan."); exit(2) }
    let m = s.manifest
    print("Scan \(m.scanID) \(m.startedAt) → \(m.finishedAt) (\(String(format: "%.1f", m.duration)) s)")
    print("Roots: \(m.effectiveRoots)")
    print("Stats: \(m.stats)")
    print("Errors: \(m.errorCount)")
    print(m.methodology)
}

let usage = """
usage: disklens-cli <command> [options]
  scan       [--root PATH]... [--top N] [--json]                 read-only scan (free)
  recommend  [--markdown FILE] [--verbose] [--json]              analyse the latest scan (free)
  plan       (--select ID,... | --tier1) [--trash] [--out FILE]  build a plan and print its digest (free)
  execute    --plan FILE (--dry-run | --approve DIGEST) [--json] dry run is free; execution needs Pro/Team
  policy     --policy FILE [--rescan] [--execute] [--json]       dry run by default; --execute needs Pro/Team
  export     [--markdown FILE] [--json-file FILE]                report export (Pro/Team)
  license    status [--json] | activate --key-file FILE|- | deactivate | machine-id
  report                                                         latest scan manifest
exit codes: 0 ok, 1 error, 2 usage, 3 approval refused, 4 license required, 5 item failures,
            6 policy executed but free space still below threshold
policy file example: {"name":"ci-low-space","whenFreeBelowGB":20,"tiers":[1],"action":"delete"}
"""

do {
    switch args.first {
    case "scan": try await runScan()
    case "recommend": try await runRecommend()
    case "plan": try runPlan()
    case "execute": try runExecute()
    case "policy": try await runPolicy()
    case "export": try runExport()
    case "license": try await MainActor.run { try runLicense() }
    case "report": runReport()
    case "help", "--help", "-h": print(usage)
    default:
        print(usage)
        exitWith(.usage)
    }
} catch {
    err("error: \(error)")
    exitWith(.error)
}
