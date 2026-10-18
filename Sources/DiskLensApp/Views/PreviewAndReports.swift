import SwiftUI
import DiskLensCore

/// Cleanup preview: exactly what will happen, with explicit approval bound to the plan digest.
struct CleanupPreviewSheet: View {
    @Environment(AppModel.self) private var model
    @State private var plan: CleanupPlan?
    @State private var reviewed = false
    @State private var confirmText = ""

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanup preview").font(.title2.bold())
            if let plan {
                HStack(spacing: 12) {
                    StatCard(title: "Items", value: "\(plan.items.count)", note: "selected")
                    StatCard(title: "Selected", value: ByteFormat.gb(plan.totalSelectedBytes), note: "on disk (measured)")
                    StatCard(title: "Reclaimable", value: ByteFormat.gb(plan.totalEstimatedReclaimable), note: "ESTIMATE", tint: Theme.accent)
                    StatCard(title: "Admin rights", value: plan.elevatedItems.isEmpty ? "Not needed" : "\(plan.elevatedItems.count) items",
                             note: plan.elevatedItems.isEmpty ? "runs as you" : "will be skipped")
                }
                Toggle("Move to Trash instead of deleting (reversible — space is freed only after you empty the Trash)", isOn: $model.useTrash)
                    .onChange(of: model.useTrash) { _, _ in rebuild() }
                let commands = plan.items.filter { $0.action.kind == .runCommand }
                if model.useTrash && !commands.isEmpty {
                    Label("\(commands.count) item(s) run a tool command (\(commands.map(\.title).joined(separator: ", "))) — commands cannot be moved to Trash and are permanent.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warn)
                }
                List(plan.items) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(r.title).bold()
                            Spacer()
                            Text("≈ \(ByteFormat.string(r.estimatedReclaimable))").monospacedDigit()
                        }
                        Text(r.action.displayString).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Impact: \(r.consequences)").font(.caption).foregroundStyle(Theme.muted)
                        if !r.inUseBy.isEmpty {
                            Text(r.inUseBy.allSatisfy({ $0.hasPrefix("(") })
                                 ? "⚠︎ \(r.inUseBy.joined(separator: " ")) — make sure no related tool is running."
                                 : "⚠︎ In use by \(r.inUseBy.joined(separator: ", ")) — will be skipped unless quit")
                                .font(.caption).foregroundStyle(Theme.warn)
                        }
                        if !r.analysisComplete { Text("⚠︎ Could not be fully analysed").font(.caption).foregroundStyle(Theme.warn) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 220)
                if let d = model.dryRunReport {
                    GroupBox("Dry-run result (nothing was modified)") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(d.results) { r in
                                Text("\(r.status == .wouldExecute ? "✓" : "–") \(r.title): \(r.message)").font(.caption).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text(Platform.isSandboxed
                     ? "Before removing anything, DiskLens re-validates every target: still exists, same item as scanned, inside the folders you granted, not protected, and no visible app is using it (this edition cannot see every running app or tool, so such items are marked unverified). Tier-3 items are never executed."
                     : "Before removing anything, DiskLens re-validates every target: still exists, same item as scanned, canonical path inside your home, not protected, not owned by another user, owning app or tool not running. Tier-3 items are never executed.")
                    .font(.caption).foregroundStyle(Theme.muted)
                Toggle("I reviewed the exact paths and commands above", isOn: $reviewed)
                let decision = model.executionDecision(for: plan)
                if let note = model.executionNote ?? decisionNote(decision) {
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Approval token:").font(.caption).foregroundStyle(Theme.muted)
                    Text(String(plan.digest.prefix(12))).font(.caption.monospaced())
                    Spacer()
                    Button("Cancel") { model.showPreview = false }.keyboardShortcut(.cancelAction)
                    Button("Dry Run") { model.dryRun(plan) }.disabled(model.isExecuting)
                    switch decision {
                    case .requiresPro:
                        Button { model.showPreview = false; model.showPaywall(.cleanup) } label: {
                            HStack(spacing: 5) { Text("Unlock One-Click Cleanup…"); ProBadge() }
                        }
                        .buttonStyle(.borderedProminent)
                    default:
                        Button(role: .destructive) {
                            model.execute(plan, approval: CleanupApproval(plan: plan, approver: "app:\(NSUserName())"))
                        } label: {
                            if model.isExecuting { ProgressView().controlSize(.small) } else { Text(approveLabel(plan, decision)) }
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.bad)
                        .disabled(!reviewed || model.isExecuting || !executable(decision))
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 860, height: 680)
        .onAppear { rebuild() }
    }

    func approveLabel(_ plan: CleanupPlan, _ decision: FeatureGate.ExecutionDecision) -> String {
        let commands = plan.items.filter { $0.action.kind == .runCommand }.count
        let files = plan.items.count - commands
        let base: String
        if model.useTrash {
            base = commands == 0 ? "Approve & Move \(files) to Trash" : "Approve: \(files) to Trash, \(commands) permanent"
        } else {
            base = "Approve & Delete \(plan.items.count)"
        }
        if case .allowedAsFreeRun = decision { return base + " (free run)" }
        return base
    }

    func executable(_ d: FeatureGate.ExecutionDecision) -> Bool {
        switch d { case .allowed, .allowedAsFreeRun: return true; default: return false }
    }

    func decisionNote(_ d: FeatureGate.ExecutionDecision) -> String? {
        switch d {
        case .allowed, .nothingExecutable: return nil
        case .allowedAsFreeRun(let cap): return "This uses your one free one-click cleanup (plans up to \(ByteFormat.gb(cap)) estimated). Previews and dry runs are always free."
        case .exceedsFreeRunCap(let bytes, let cap): return "This plan is estimated at \(ByteFormat.gb(bytes)); the free cleanup run covers up to \(ByteFormat.gb(cap)). Deselect items, or unlock Pro for unlimited one-click cleanup."
        case .requiresPro(let f): return "\(f.displayName) is part of DiskLens Pro. The preview and dry run above stay free, and you can move single items to the Trash from the Explorer."
        }
    }

    func rebuild() {
        if let pinned = model.pinnedPreviewPlan {
            plan = pinned
            if model.dryRunReport?.planID != pinned.id { model.dryRunReport = nil }
            return
        }
        plan = model.makePlan()
        reviewed = false
        model.dryRunReport = nil
        model.executionNote = nil
    }
}

struct ReportsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ExportAndHistorySection()
                Text("Cleanup reports").font(.title2.bold())
                if model.reports.isEmpty {
                    Text("No cleanup has been executed yet. Reports appear here after you approve a plan.").foregroundStyle(Theme.muted)
                }
                ForEach(model.reports, id: \.planID) { r in ReportCard(report: r) }
            }
            .padding(20)
        }
    }
}

struct ReportCard: View {
    var report: CleanupReport
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(report.finishedAt.formatted(date: .abbreviated, time: .standard)).font(.headline)
                Spacer()
                Text(report.dryRun ? "DRY RUN" : "EXECUTED").font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill((report.dryRun ? Theme.muted : Theme.good).opacity(0.25)))
            }
            HStack(spacing: 12) {
                StatCard(title: "Free space change", value: report.measuredFreeSpaceDelta.map { ($0 >= 0 ? "+" : "") + ByteFormat.string($0) } ?? "n/a",
                         note: "MEASURED (statfs before/after)", tint: Theme.good)
                StatCard(title: "Estimated", value: ByteFormat.string(report.estimatedTotal), note: "estimate for completed items")
                StatCard(title: "Removed", value: "\(report.succeeded.count)", note: "items")
                StatCard(title: "Skipped / failed", value: "\(report.skipped.count) / \(report.failed.count)", note: "see below",
                         tint: report.failed.isEmpty ? .primary : Theme.bad)
            }
            ForEach(report.results) { r in
                HStack(alignment: .top) {
                    Image(systemName: icon(r.status)).foregroundStyle(color(r.status))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.callout)
                        Text(r.message).font(.caption).foregroundStyle(Theme.muted)
                        if let o = r.commandOutput, !o.isEmpty { Text(o.suffix(300)).font(.caption2.monospaced()).foregroundStyle(Theme.muted) }
                    }
                    Spacer()
                    if let b = r.bytesBefore { Text("\(ByteFormat.string(b)) → \(r.bytesAfter.map(ByteFormat.string) ?? "?")").font(.caption.monospacedDigit()) }
                }
            }
            ForEach(report.unexpected, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warn) }
            ForEach(report.followUp, id: \.self) { Label($0, systemImage: "arrow.right.circle").font(.caption).foregroundStyle(Theme.muted) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
    }
    func icon(_ s: CleanupItemStatus) -> String {
        switch s { case .succeeded: return "checkmark.circle.fill"; case .partiallySucceeded: return "circle.lefthalf.filled"; case .skipped: return "minus.circle"; case .failed: return "xmark.octagon.fill"; case .wouldExecute: return "eye" }
    }
    func color(_ s: CleanupItemStatus) -> Color {
        switch s { case .succeeded: return Theme.good; case .partiallySucceeded, .skipped: return Theme.warn; case .failed: return Theme.bad; case .wouldExecute: return Theme.muted }
    }
}

struct ManifestView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let s = model.scan {
            let m = s.manifest
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Scan manifest").font(.title2.bold())
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        r("Scan ID", m.scanID.uuidString)
                        r("Started", m.startedAt.formatted(date: .abbreviated, time: .standard))
                        r("Finished", "\(m.finishedAt.formatted(date: .abbreviated, time: .standard)) (\(String(format: "%.1f", m.duration)) s)")
                        r("Host / OS", "\(m.hostName) · \(m.osVersion)")
                        r("Roots scanned", m.effectiveRoots.map { PathUtil.abbreviated($0) }.joined(separator: ", "))
                        if !m.droppedOverlappingRoots.isEmpty { r("Overlapping roots dropped", m.droppedOverlappingRoots.joined(separator: ", ")) }
                        if !m.missingRoots.isEmpty { r("Missing roots", m.missingRoots.joined(separator: ", ")) }
                        r("Totals", "\(ByteFormat.gb(m.totalAllocated)) allocated · \(ByteFormat.gb(m.totalLogical)) logical")
                        r("Files / folders", "\(m.stats.filesVisited.formatted()) / \(m.stats.directoriesVisited.formatted())")
                        r("Symlinks (not followed)", m.stats.symlinksNotFollowed.formatted())
                        r("Hard-link duplicates skipped", m.stats.hardLinkDuplicatesSkipped.formatted())
                        r("Mount points not crossed", m.stats.mountPointsNotCrossed.formatted())
                        r("Cloud-only (not downloaded)", "\(m.stats.datalessFiles.formatted()) files · \(m.stats.datalessDirectories.formatted()) folders")
                        r("Unreadable folders", "\(m.stats.unreadableDirectories) (sizes unknown, not zero)")
                        r("Stat failures", m.stats.statFailures.formatted())
                    }
                    .font(.callout)
                    .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))

                    if !model.changes.isEmpty {
                        Text("Changes since previous scan").font(.title3.bold())
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.changes) { c in
                                HStack {
                                    Text((c.delta >= 0 ? "+" : "") + ByteFormat.string(c.delta)).monospacedDigit().foregroundStyle(c.delta >= 0 ? Theme.warn : Theme.good).frame(width: 90, alignment: .trailing)
                                    Text(PathUtil.abbreviated(c.path)).font(.caption).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                    }

                    Text("Coverage gaps (\(m.errorCount))").font(.title3.bold())
                    Text(Platform.isSandboxed
                         ? "These locations are outside the folders you granted or are protected by macOS. Add the containing folder in Settings ▸ Scanning to include it."
                         : "These entries could not be read (usually macOS privacy protection / TCC). Grant DiskLens Full Disk Access in System Settings → Privacy & Security to include them.")
                        .font(.caption).foregroundStyle(Theme.muted)
                    let groups = Dictionary(grouping: m.errors.filter { !m.privacyBlockedPaths.contains($0.path) }) {
                        PathUtil.abbreviated($0.path).split(separator: "/").prefix(3).joined(separator: "/")
                    }
                    .sorted { $0.value.count > $1.value.count }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(m.privacyBlockedPaths, id: \.self) { p in
                            Label("NOT SCANNED: \(PathUtil.abbreviated(p)) — macOS did not grant access in time (privacy prompt pending or denied). Size unknown, not zero.",
                                  systemImage: "lock.trianglebadge.exclamationmark")
                                .font(.caption.bold()).foregroundStyle(Theme.warn)
                        }
                        ForEach(groups.prefix(40), id: \.key) { g in
                            Text("\(g.value.count) × \(g.key) — \(g.value.first?.message ?? "")").font(.caption.monospaced())
                        }
                    }
                    .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))

                    Text("Methodology").font(.title3.bold())
                    Text(m.methodology).font(.caption).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
                .padding(20)
            }
        }
    }
    @ViewBuilder func r(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(Theme.muted); Text(v).textSelection(.enabled) }
    }
}
