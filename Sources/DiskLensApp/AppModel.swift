import SwiftUI
import AppKit
import DiskLensCore

enum Pane: String, CaseIterable, Identifiable {
    case explorer = "Explorer"
    case categories = "Categories"
    case largest = "Largest Files"
    case cleanup = "Cleanup"
    case reports = "Reports"
    case manifest = "Scan Manifest"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .explorer: return "square.grid.3x3.fill"
        case .categories: return "chart.bar.fill"
        case .largest: return "doc.on.doc.fill"
        case .cleanup: return "sparkles"
        case .reports: return "checkmark.seal.fill"
        case .manifest: return "list.bullet.clipboard.fill"
        }
    }
}

enum ScanScope: String, CaseIterable, Identifiable {
    case standard = "Home + Apps + Dev locations"
    case home = "Home folder only"
    var id: String { rawValue }
    var options: ScanOptions {
        switch self {
        case .standard: return .defaultScope()
        case .home: return ScanOptions(roots: [Platform.realHome])
        }
    }
}

enum ChildSort: String, CaseIterable, Identifiable {
    case allocated = "Size on disk", logical = "Logical size", files = "File count", name = "Name"
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    // Scan state
    var scan: ScanResult?
    var volume: VolumeSnapshot? = VolumeInfo.snapshot()
    var isScanning = false
    var progress: ScanProgress?
    var scanError: String?
    var changes: [ScanChange] = []
    var scope: ScanScope = .standard
    private var scanTask: Task<Void, Never>?

    // Explorer
    var focus: Int32 = ScanTree.root
    var selection: Int32?
    var searchText = ""
    var minSizeMB: Double = 0
    var hiddenCategories: Set<StorageCategory> = []
    var childSort: ChildSort = .allocated
    var pane: Pane = .explorer

    // Cleanup
    var recommendations: [Recommendation] = []
    var selectedRecs: Set<String> = []
    var analysisNotes: [String] = []
    var isAnalyzing = false
    var analysisProgress: String = ""
    var tierFilter: Set<CleanupTier> = Set(CleanupTier.allCases)
    var showPreview = false
    var useTrash = false
    var lastReport: CleanupReport?
    var dryRunReport: CleanupReport?
    /// Offscreen snapshots only: the preview sheet shows this exact plan (and keeps its dry run).
    var pinnedPreviewPlan: CleanupPlan?
    var isExecuting = false
    var reports: [CleanupReport] = []
    var activeRecID: String?

    let store = ScanStore()
    let access = FolderAccess()
    let license: LicenseService
    let settings = AppSettings()
    /// Non-nil while the paywall sheet is shown (contextual, never blocking).
    var paywall: PaywallContext?
    var history: [ScanHistoryEntry] = []
    /// Result of the last single-item Move to Trash (shown as an alert).
    var trashResult: String?
    /// Message shown in the preview sheet when execution was refused (cap, Keychain …).
    var executionNote: String?
    var duplicatesAnalyzed = false
    var lowSpace = LowSpaceMonitor()
    var showOnboarding = false
    /// Snapshot/demo rendering: draw the treemap as an image so offscreen capture includes it.
    var renderStaticTreemap = false
    let isDemo: Bool
    static let onboardedKey = "DiskLens.onboarded.v1"

    /// - Parameters:
    ///   - demo: synthetic demo Mac (store screenshots; never real data).
    ///   - licenseOverride: fixed license state for offscreen snapshots (never touches the Keychain).
    init(demo: Bool = false, licenseOverride: LicenseService? = nil) {
        isDemo = demo
        if let licenseOverride {
            license = licenseOverride
        } else if demo {
            license = .fixed(.free, edition: Edition.current)
        } else {
            license = LicenseService(edition: Edition.current,
                                     purchaseStore: Edition.current == .appStore ? StoreKitPurchaseStore() : NoPurchaseStore())
        }
        lowSpace = LowSpaceMonitor(thresholdBytes: Int64(settings.lowSpaceThresholdGB * 1e9))
        #if DISKLENS_SNAPSHOTS
        if demo {
            let d = DemoData.make()
            scan = d.scan
            volume = d.volume
            recommendations = d.recommendations
            selectedRecs = Set(d.recommendations.filter { $0.tier == .low && $0.eligibleForAutoSelection }.map(\.id))
            history = d.history
            return
        }
        #endif
        if licenseOverride == nil {
            license.prepare()
            Task { [license] in await license.connect() }
        }
        license.onStateChange = { [weak self] _ in self?.licenseChanged() }
        history = store.loadHistory()
        // Saved scans are classified before they are written, so loading never blocks the UI.
        if let s = store.loadLatest() {
            scan = s
            focus = ScanTree.root
            changes = store.changesSincePrevious()
        }
        reports = store.loadReports()
        showOnboarding = !UserDefaults.standard.bool(forKey: Self.onboardedKey) || (Platform.isSandboxed && access.paths.isEmpty)
        if scan != nil { DispatchQueue.main.async { [weak self] in self?.analyze() } }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        showOnboarding = false
    }

    /// Scan roots for this edition: granted folders in the App Store build, the chosen scope otherwise.
    var scanOptions: ScanOptions? {
        if Platform.isSandboxed {
            return access.paths.isEmpty ? nil : ScanOptions(roots: access.paths)
        }
        return scope.options
    }

    func makeExecutor() -> CleanupExecutor {
        CleanupExecutor(pathGuard: .standard(allowedRoots: Platform.isSandboxed ? PathUtil.deoverlap(access.paths).kept : nil))
    }

    /// Granted folders as shown in the UI (the demo shows a typical App Store setup).
    var displayedGrants: [String] { isDemo ? ["/Users/alex", "/Applications"] : access.paths }

    /// Removes DiskLens's own saved scans, recommendations and reports. The staging folder is left
    /// alone: after an interrupted cleanup it may hold the user's items.
    func deleteScanData() {
        guard !isScanning && !isExecuting else { return }
        let fm = FileManager.default
        let dir = store.directory
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name != "staging" {
            if name.hasSuffix(".json") || name == "reports" { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        }
        scan = nil
        recommendations = []
        selectedRecs = []
        reports = []
        changes = []
        history = []
    }

    var tree: ScanTree? { scan?.tree }
    /// Dominant category per node (for treemap colouring); recomputed when the scan changes.
    var dominant: [StorageCategory] = []
    private var dominantScanID: UUID?

    func ensureDominant() {
        guard let scan, dominantScanID != scan.manifest.scanID else { return }
        dominant = scan.tree.dominantCategories()
        dominantScanID = scan.manifest.scanID
    }

    /// Space recovered by executed (non-dry-run) cleanups, measured from free-space deltas.
    var recoveredBytes: Int64 {
        reports.filter { !$0.dryRun }.compactMap(\.measuredFreeSpaceDelta).filter { $0 > 0 }.reduce(0, +)
    }

    var reclaimableEstimate: Int64 {
        recommendations.filter { $0.tier != .manualReview }.reduce(0) { $0 + $1.estimatedReclaimable }
    }

    // MARK: Scanning

    func startScan() {
        guard !isScanning else { return }
        guard !isDemo else { return }
        guard let opts = scanOptions else { showOnboarding = true; return }
        isScanning = true
        scanError = nil
        progress = nil
        scanTask = Task { [weak self] in
            do {
                var result = try await DiskScanner.scan(options: opts) { p in
                    Task { @MainActor in self?.progress = p }
                }
                let classified = await Task.detached(priority: .userInitiated) { () -> ScanResult in
                    Classifier.classify(&result.tree)
                    return result
                }.value
                guard let self else { return }
                let store = self.store
                let changes = await Task.detached { (try? store.save(classified)) ?? [] }.value
                self.scan = classified
                self.changes = changes
                self.history = self.store.loadHistory()
                self.focus = ScanTree.root
                self.selection = nil
                self.recommendations = []
                self.selectedRecs = []
                self.volume = VolumeInfo.snapshot()
                self.isScanning = false
                self.analyze()
            } catch is CancellationError {
                self?.isScanning = false
                self?.scanError = "Scan cancelled. The previous results (if any) are still shown."
            } catch {
                self?.isScanning = false
                self?.scanError = "Scan failed: \(error.localizedDescription)"
            }
        }
    }

    func cancelScan() { scanTask?.cancel() }

    // MARK: Analysis

    func analyze() {
        guard let scan, !isAnalyzing, !isDemo else { return }
        isAnalyzing = true
        analysisProgress = "Probing running apps…"
        let tree = scan.tree
        // Duplicate results are Pro: free users are not charged the hashing time for a locked feature.
        let withDuplicates = license.isEnabled(.duplicates)
        Task { [weak self] in
            let analysis = await Task.detached(priority: .userInitiated) { () -> AnalysisResult in
                let facts = EnvironmentFacts.probe()
                var a = RecommendationEngine.analyze(tree: tree, rules: RuleCatalog.standard(), facts: facts)
                if withDuplicates {
                    let dups = DuplicateFinder.analyze(tree: tree, home: Platform.realHome, existing: a.recommendations)
                    a.recommendations += dups.recommendations
                    if dups.truncated { a.notes.append("Duplicate search stopped at its hashing budget; coverage is partial.") }
                }
                return a
            }.value
            self?.duplicatesAnalyzed = withDuplicates
            self?.recommendations = analysis.recommendations
            self?.analysisNotes = analysis.notes
            self?.analysisProgress = "Measuring reclaimable space (APFS private size)…"
            var refined = await RecommendationEngine.refineEstimates(analysis.recommendations, progress: { d, n in
                Task { @MainActor in self?.analysisProgress = "Measuring reclaimable space… \(d)/\(n)" }
            })
            refined = await RuleCatalog.refineCommandEstimates(refined)
            guard let self else { return }
            self.recommendations = refined
            // Pre-select only tier-1 items that are safe to pre-select. Nothing runs without approval.
            self.selectedRecs = Set(refined.filter { $0.tier == .low && $0.eligibleForAutoSelection }.map(\.id))
            self.isAnalyzing = false
            self.analysisProgress = ""
        }
    }

    var selectedRecommendations: [Recommendation] {
        recommendations.filter { selectedRecs.contains($0.id) && !$0.requiresManualReview }
    }

    func makePlan() -> CleanupPlan {
        let items = selectedRecommendations.map { r -> Recommendation in
            var r = r
            if useTrash && r.action.kind == .deletePermanently { r.action = .trash(r.targetPath) }
            return r
        }
        return CleanupPlan(scanID: scan?.manifest.scanID, items: items)
    }

    func dryRun(_ plan: CleanupPlan) {
        isExecuting = true
        Task { [weak self] in
            let executor = self?.makeExecutor() ?? CleanupExecutor()
            let report = await Task.detached { try? executor.execute(plan: plan, approval: nil, dryRun: true) }.value
            self?.dryRunReport = report
            self?.isExecuting = false
        }
    }

    /// What the license allows for this plan (shown on the Approve button).
    func executionDecision(for plan: CleanupPlan) -> FeatureGate.ExecutionDecision {
        license.gate.executionDecision(for: plan)
    }

    func execute(_ plan: CleanupPlan, approval: CleanupApproval) {
        executionNote = nil
        var usingFreeRun = false
        switch executionDecision(for: plan) {
        case .allowed:
            break
        case .allowedAsFreeRun:
            do { try license.reserveFreeRun(); usingFreeRun = true } catch {
                executionNote = "Could not record the free cleanup run in the Keychain (\(error.localizedDescription)), so it was not started. Nothing was changed."
                return
            }
        case .requiresPro:
            showPaywall(.cleanup)
            return
        case .exceedsFreeRunCap(let bytes, let cap):
            executionNote = "This plan is estimated at \(ByteFormat.gb(bytes)); the free cleanup run covers up to \(ByteFormat.gb(cap)). Deselect some items, or unlock Pro."
            return
        case .nothingExecutable:
            return
        }
        isExecuting = true
        let store = store
        let executor = makeExecutor()
        let license = license
        Task { [weak self] in
            let report: CleanupReport? = await Task.detached {
                guard let r = try? executor.execute(plan: plan, approval: approval, dryRun: false) else { return nil }
                _ = try? store.saveReport(r)
                return r
            }.value
            if usingFreeRun && (report?.succeeded.isEmpty ?? true) { license.refundFreeRun() }
            guard let self else { return }
            self.isExecuting = false
            self.lastReport = report
            self.reports = self.store.loadReports()
            self.volume = VolumeInfo.snapshot()
            self.showPreview = false
            self.pane = .reports
            if let report {
                let done = Set(report.succeeded.map(\.id))
                self.recommendations.removeAll { done.contains($0.id) }
                self.selectedRecs.subtract(done)
            }
        }
    }

    // MARK: Licensing

    func showPaywall(_ trigger: PaywallContext.Trigger) {
        paywall = PaywallContext.from(recommendations: recommendations, scanDate: scan?.manifest.finishedAt, trigger: trigger)
    }

    /// Re-runs analysis when Pro unlocks duplicate results.
    func licenseChanged() {
        if license.isEnabled(.duplicates) && !duplicatesAnalyzed && scan != nil && !isAnalyzing { analyze() }
    }

    // MARK: Single item → Trash (free)

    /// Safety check for "Move to Trash…" on one item the user picked. nil = allowed.
    func manualTrashProblem(_ id: Int32) -> String? {
        guard let tree, id != ScanTree.root else { return "Select a file or folder first." }
        let n = tree.nodes[Int(id)]
        if n.isAggregate { return "This tile groups many small files; reveal the folder in Finder to choose them." }
        if n.parent == ScanTree.root { return "A scan location itself cannot be moved to the Trash." }
        if n.flags.contains(.unreadable) { return "DiskLens cannot read this folder, so it cannot check it." }
        if case .failure(let e) = manualTrashGuard().validate(tree.path(of: id)) { return e.description }
        return nil
    }

    func manualTrashGuard() -> PathGuard {
        .manualTrash(allowedRoots: Platform.isSandboxed ? PathUtil.deoverlap(access.paths).kept : nil)
    }

    /// Moves one user-selected item to the Trash after the same revalidation as any cleanup
    /// (canonical path, protections, ownership, same inode as scanned). Free in every edition.
    func trashSingle(_ id: Int32) {
        guard license.gate.allowsSingleItemTrash(), let tree, manualTrashProblem(id) == nil else { return }
        let n = tree.nodes[Int(id)]
        let path = tree.path(of: id)
        let rec = Recommendation.manualTrash(path: path, node: n)
        let plan = CleanupPlan(scanID: scan?.manifest.scanID, items: [rec])
        let approval = CleanupApproval(plan: plan, approver: "app-manual:\(NSUserName())")
        var ex = makeExecutor()
        ex.pathGuard = manualTrashGuard()
        let executor = ex
        let store = store
        isExecuting = true
        Task { [weak self] in
            let report = await Task.detached { () -> CleanupReport? in
                guard let r = try? executor.execute(plan: plan, approval: approval, dryRun: false) else { return nil }
                _ = try? store.saveReport(r)
                return r
            }.value
            guard let self else { return }
            self.isExecuting = false
            self.reports = self.store.loadReports()
            self.volume = VolumeInfo.snapshot()
            let r = report?.results.first
            self.trashResult = r.map { "\($0.title): \($0.message)" } ?? "Nothing was moved."
            if r?.status == .succeeded { self.recommendations.removeAll { PathUtil.isSameOrInside($0.targetPath, path) } }
        }
    }

    // MARK: Reports & history (Pro)

    func buildReport() -> ReportExporter.Report? {
        guard let scan else { return nil }
        return ReportExporter.build(scan: scan, recommendations: recommendations, changes: changes, cleanups: reports,
                                    history: history, appVersion: AppLinks.version)
    }

    func export(markdown: Bool) {
        guard license.isEnabled(.reportExport) else { showPaywall(.reportExport); return }
        guard let report = buildReport() else { return }
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter.string(from: report.scanFinishedAt, timeZone: .current, formatOptions: [.withFullDate])
        panel.nameFieldStringValue = "DiskLens Report \(stamp).\(markdown ? "md" : "json")"
        panel.allowedContentTypes = markdown ? [.init(filenameExtension: "md") ?? .plainText] : [.json]
        panel.message = "Reports contain paths and sizes only — never file contents."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = markdown ? Data(ReportExporter.markdown(report).utf8) : try ReportExporter.json(report)
            try data.write(to: url, options: .atomic)
        } catch {
            trashResult = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Schedule & low-space monitor (Pro)

    /// Called periodically by the scheduler (and on launch).
    func scheduledTick(now: Date = Date()) {
        guard !isDemo, license.isEnabled(.scheduling) else { return }
        volume = VolumeInfo.snapshot()
        if settings.lowSpaceAlerts, let v = volume {
            lowSpace.thresholdBytes = Int64(settings.lowSpaceThresholdGB * 1e9)
            if lowSpace.evaluate(availableBytes: v.availableBytes, now: now) {
                Notifier.lowSpace(available: v.availableBytes, threshold: lowSpace.thresholdBytes, reclaimable: reclaimableEstimate)
            }
        }
        if settings.schedule.isDue(lastScan: scan?.manifest.finishedAt, now: now) && !isScanning && scanOptions != nil {
            Log.app.info("scheduled scan starting")
            startScan()
        }
    }

    // MARK: Navigation

    func zoom(into id: Int32) {
        guard let tree, tree.nodes[Int(id)].isDirectory, !tree.nodes[Int(id)].children.isEmpty else { return }
        focus = id
        selection = nil
    }

    func zoomOut() {
        guard let tree, focus != ScanTree.root else { return }
        focus = max(tree.nodes[Int(focus)].parent, ScanTree.root)
    }

    func reveal(_ id: Int32) {
        guard let tree, let target = revealablePath(tree.path(of: id)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    func reveal(path: String) {
        if let target = revealablePath(path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
        }
    }

    func revealablePath(_ p: String) -> String? {
        var cur = p
        while !cur.isEmpty && cur != "/" {
            if FileManager.default.fileExists(atPath: cur) { return cur }
            cur = (cur as NSString).deletingLastPathComponent
        }
        return nil
    }

    func navigate(to id: Int32) {
        guard let tree else { return }
        let n = tree.nodes[Int(id)]
        focus = n.isDirectory && !n.children.isEmpty ? id : max(n.parent, ScanTree.root)
        selection = id
        pane = .explorer
    }

    func navigate(toPath p: String) {
        guard let tree, let id = tree.find(path: p) else { return }
        navigate(to: id)
    }

    /// Estimated reclaimable bytes from recommendations at or below a node.
    func reclaimable(under id: Int32) -> Int64 {
        guard let tree else { return 0 }
        let p = tree.path(of: id)
        return recommendations.filter { $0.tier != .manualReview && PathUtil.isSameOrInside($0.targetPath, p) }
            .reduce(0) { $0 + $1.estimatedReclaimable }
    }

    func recommendation(for id: Int32) -> Recommendation? {
        guard let tree else { return nil }
        let p = tree.path(of: id)
        return recommendations.first { PathUtil.isSameOrInside(p, $0.targetPath) }
    }
}

extension StorageCategory {
    var color: Color { let (r, g, b) = rgb; return Color(red: r, green: g, blue: b) }
    /// Compact label for the treemap legend (full name in the tooltip).
    var shortName: String {
        switch self {
        case .applications: return "Apps"
        case .documentsMedia: return "Documents"
        case .developerArtifacts: return "Dev artifacts"
        case .packageCaches: return "Pkg caches"
        case .sdkData: return "SDKs & VMs"
        case .aiTools: return "AI & tools"
        case .downloadsArchives: return "Downloads"
        case .systemManaged: return "System"
        case .other: return "Other"
        case .inaccessible: return "Unknown"
        }
    }
}
