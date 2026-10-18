import SwiftUI
import AppKit
import DiskLensCore

struct CleanupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if !model.license.isEnabled(.cleanupExecution) { FreeTierBanner().padding(.horizontal, 12).padding(.top, 8) }
                List {
                    ForEach(CleanupTier.allCases.filter { model.tierFilter.contains($0) }, id: \.self) { tier in
                        let items = model.recommendations.filter { $0.tier == tier }.sorted { $0.estimatedReclaimable > $1.estimatedReclaimable }
                        if !items.isEmpty {
                            Section {
                                ForEach(items) { r in RecRow(rec: r) }
                            } header: {
                                HStack {
                                    Text(tier.label).font(.subheadline.bold())
                                    Spacer()
                                    Text("\(items.count) items · ≈ \(ByteFormat.gb(items.reduce(0) { $0 + $1.estimatedReclaimable }))")
                                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                                }
                            } footer: {
                                Text(tierExplanation(tier)).font(.caption2).foregroundStyle(Theme.muted)
                            }
                        }
                        if tier == .manualReview && !model.license.isEnabled(.duplicates) && model.scan != nil {
                            LockedFeatureCard(feature: .duplicates, trigger: .duplicates,
                                              detail: "Find byte-identical copies of large files (SHA-256, computed in memory and never stored). Clones and hard links are recognised, so copies that would free nothing are not counted.")
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                footer
            }
            Divider().opacity(0.4)
            RecDetail()
                .frame(width: 400)
        }
    }

    var header: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cleanup recommendations").font(.title3.bold())
                Text(model.isAnalyzing ? model.analysisProgress : "Evidence-based candidates. Estimates use APFS private size, so cloned/shared data is not over-counted.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            ForEach(CleanupTier.allCases, id: \.self) { t in
                Toggle(isOn: Binding(get: { model.tierFilter.contains(t) },
                                     set: { on in if on { model.tierFilter.insert(t) } else { model.tierFilter.remove(t) } })) {
                    Text("Tier \(t.rawValue)")
                }
                .toggleStyle(.button).controlSize(.small)
            }
            Button { model.analyze() } label: { Label("Re-analyse", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(model.isAnalyzing || model.scan == nil).controlSize(.small)
        }
        .padding(12)
        .background(Theme.panel.opacity(0.6))
    }

    var footer: some View {
        @Bindable var model = model
        let sel = model.selectedRecommendations
        let est = sel.reduce(Int64(0)) { $0 + $1.estimatedReclaimable }
        return HStack {
            Text("\(sel.count) selected · ≈ \(ByteFormat.gb(est)) estimated").font(.callout.monospacedDigit())
            Spacer()
            Button("Select safe tier 1") {
                model.selectedRecs = Set(model.recommendations.filter { $0.tier == .low && $0.eligibleForAutoSelection }.map(\.id))
            }
            Button("Clear") { model.selectedRecs = [] }
            Button { model.dryRunReport = nil; model.showPreview = true } label: { Label("Preview Cleanup…", systemImage: "eye") }
                .buttonStyle(.borderedProminent)
                .disabled(sel.isEmpty)
        }
        .padding(12)
        .background(Theme.panel)
    }

    func tierExplanation(_ t: CleanupTier) -> String {
        switch t {
        case .low: return "Clearly disposable caches and build outputs that tools recreate automatically. Still requires preview + approval."
        case .conditional: return "Removable after checking purpose and reproducibility (lockfiles, pending updates, in-use apps)."
        case .manualReview: return "Never removed by DiskLens. Personal data, VM disks, backups, apps and histories — review them yourself."
        }
    }
}

struct RecRow: View {
    @Environment(AppModel.self) private var model
    var rec: Recommendation

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            if rec.requiresManualReview {
                Image(systemName: "hand.raised").foregroundStyle(Theme.warn).frame(width: 18)
            } else {
                Toggle("", isOn: Binding(get: { model.selectedRecs.contains(rec.id) },
                                         set: { on in if on { model.selectedRecs.insert(rec.id) } else { model.selectedRecs.remove(rec.id) } }))
                    .labelsHidden().toggleStyle(.checkbox)
            }
            RoundedRectangle(cornerRadius: 2).fill(rec.category.color).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.title).lineLimit(1)
                Text(PathUtil.abbreviated(rec.targetPath)).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !rec.inUseBy.isEmpty {
                Text(rec.inUseBy.allSatisfy({ $0.hasPrefix("(") }) ? "unverified" : "in use").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.warn.opacity(0.25)))
            }
            if rec.pack == .developer {
                Image(systemName: "hammer.fill").font(.caption2).foregroundStyle(Theme.muted)
                    .help("Developer rule pack").accessibilityLabel("Developer rule pack")
            }
            RiskPill(risk: rec.risk)
            VStack(alignment: .trailing, spacing: 1) {
                Text("≈ " + ByteFormat.string(rec.estimatedReclaimable)).font(.callout.monospacedDigit().bold())
                Text("of " + ByteFormat.string(rec.detectedAllocated)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.muted)
            }
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rec.title), \(rec.tier.label), risk \(rec.risk.rawValue), about \(ByteFormat.string(rec.estimatedReclaimable)) reclaimable")
        .onTapGesture { model.activeRecID = rec.id }
        .listRowBackground(model.activeRecID == rec.id ? Theme.accent.opacity(0.18) : Color.clear)
    }
}

struct RiskPill: View {
    var risk: RiskLevel
    var body: some View {
        let c: Color = risk == .low ? Theme.good : risk == .medium ? Theme.warn : Theme.bad
        Text(risk.rawValue).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.22))).foregroundStyle(c)
    }
}

struct RecDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            if let id = model.activeRecID, let r = model.recommendations.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(r.title).font(.headline)
                    HStack { Text(r.tier.label); RiskPill(risk: r.risk); Text("confidence: \(r.confidence.rawValue)").foregroundStyle(Theme.muted) }.font(.caption)
                    field("Target", r.targetPath, mono: true)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow { Text("Detected").foregroundStyle(Theme.muted); Text("\(ByteFormat.string(r.detectedAllocated)) on disk · \(ByteFormat.string(r.detectedLogical)) logical · \(r.fileCount.formatted()) files").monospacedDigit() }
                        GridRow { Text("Reclaimable").foregroundStyle(Theme.muted); Text("≈ \(ByteFormat.string(r.estimatedReclaimable)) (estimate)").monospacedDigit().foregroundStyle(Theme.good) }
                        GridRow { Text("Method").foregroundStyle(Theme.muted); Text(r.reclaimMethod).font(.caption) }
                    }
                    .font(.callout)
                    field("Why it is considered removable", r.reason)
                    field("Dependencies", r.dependencies)
                    field("Consequences", r.consequences)
                    field("Exact action", r.action.displayString, mono: true)
                    if let cmd = r.suggestedCommand {
                        VStack(alignment: .leading, spacing: 4) {
                            field("Run it yourself in Terminal", cmd, mono: true)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cmd, forType: .string)
                            } label: { Label("Copy Command", systemImage: "doc.on.doc") }.controlSize(.small)
                        }
                    }
                    field("Verification after execution", r.verification)
                    if !r.inUseBy.isEmpty {
                        if r.inUseBy.allSatisfy({ $0.hasPrefix("(") }) {
                            field("In-use check", r.inUseBy.joined(separator: " ") + " Make sure no related tool is running before you approve.")
                        } else {
                            field("In use by", r.inUseBy.joined(separator: ", ") + " — DiskLens skips this item while they run.")
                        }
                    }
                    if r.requiresElevation { field("Elevation", "Would require administrator privileges — DiskLens will not perform it.") }
                    if !r.analysisComplete { field("Analysis", "Incomplete — some contents could not be read.") }
                    ForEach(r.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.muted) }
                    if r.pack == .developer { field("Rule set", "Developer rule pack — free to inspect, preview and dry-run; one-click cleanup is Pro.") }
                    HStack {
                        Button { model.reveal(path: r.targetPath) } label: { Label("Reveal in Finder", systemImage: "folder") }
                        Button { model.navigate(toPath: r.targetPath) } label: { Label("Show in Treemap", systemImage: "square.grid.3x3") }
                    }
                    .controlSize(.small)
                }
                .padding(16)
            } else {
                Text("Select a recommendation to inspect its evidence, consequences and exact action.")
                    .foregroundStyle(Theme.muted).padding(24)
            }
        }
        .background(Theme.panel)
    }

    func field(_ k: String, _ v: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(1).foregroundStyle(Theme.muted)
            Text(v).font(mono ? .caption.monospaced() : .callout).textSelection(.enabled)
        }
    }
}

/// Explains the free tier in the Cleanup pane, without blocking anything.
struct FreeTierBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let free = model.license.freeAllowance.remaining > 0
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Theme.accent).accessibilityHidden(true)
            Text(free
                 ? "Free plan: every recommendation, preview and dry run is included, and you can move single items to the Trash from the Explorer. Your first one-click cleanup (up to \(ByteFormat.gb(FreeCleanupAllowance.capBytes))) is on us."
                 : "Free plan: every recommendation, preview and dry run is included, and you can move single items to the Trash from the Explorer. One-click cleanup is part of Pro.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Pro…") { model.showPaywall(.cleanup) }.controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.10)))
    }
}
