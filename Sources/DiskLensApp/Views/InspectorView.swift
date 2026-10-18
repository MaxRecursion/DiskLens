import SwiftUI
import DiskLensCore

/// Details of the selected (or focused) node plus a sortable list of its children.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @State private var trashCandidate: Int32?

    var body: some View {
        @Bindable var model = model
        if let tree = model.tree {
            let id = model.selection ?? model.focus
            let n = tree.nodes[Int(id)]
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: n.isDirectory ? "folder.fill" : "doc.fill").font(.title2).foregroundStyle(n.category.color)
                            Text(id == ScanTree.root ? "All scanned locations" : (n.parent == ScanTree.root ? PathUtil.abbreviated(n.name) : n.name)).font(.headline).lineLimit(2)
                        }
                        Text(id == ScanTree.root ? (model.scan?.manifest.effectiveRoots.map { PathUtil.abbreviated($0) }.joined(separator: " · ") ?? "") : tree.path(of: id)).font(.caption.monospaced()).foregroundStyle(Theme.muted).textSelection(.enabled).lineLimit(4)
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            row("Allocated (on disk)", ByteFormat.string(n.allocated), "measured")
                            row("Logical size", ByteFormat.string(n.logical), n.flags.contains(.sparse) ? "sparse file" : "measured")
                            row("Files", n.fileCount.formatted(), "")
                            row("Category", n.category.displayName, "rule: \(n.categoryRule)")
                            let rec = model.reclaimable(under: id)
                            row("Est. recoverable", rec > 0 ? ByteFormat.string(rec) : "—", rec > 0 ? "estimate (tier 1+2)" : "no candidates here")
                            if n.mtime > 0 { row("Modified", Date(timeIntervalSince1970: TimeInterval(n.mtime)).formatted(date: .abbreviated, time: .shortened), "") }
                        }
                        .font(.callout)
                        FlagBadges(flags: n.flags, errors: n.errorCount)
                        if let r = model.recommendation(for: id) {
                            RecommendationBadge(rec: r)
                        }
                        HStack {
                            Button { model.reveal(id) } label: { Label("Reveal in Finder", systemImage: "folder") }
                            if n.isDirectory && !n.children.isEmpty && id != model.focus {
                                Button { model.zoom(into: id) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                            }
                            if id != ScanTree.root && !n.isAggregate && n.parent != ScanTree.root {
                                Button { trashCandidate = id } label: { Label("Move to Trash…", systemImage: "trash") }
                                    .disabled(model.isExecuting)
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(14)
                }
                .frame(maxHeight: 360)
                Divider().opacity(0.4)
                ChildrenList(parent: n.isDirectory ? id : n.parent)
            }
            .background(Theme.panel)
            .confirmationDialog(trashTitle(tree), isPresented: Binding(get: { trashCandidate != nil }, set: { if !$0 { trashCandidate = nil } })) {
                if let c = trashCandidate, model.manualTrashProblem(c) == nil {
                    Button("Move to Trash", role: .destructive) { model.trashSingle(c); trashCandidate = nil }
                }
                Button("Cancel", role: .cancel) { trashCandidate = nil }
            } message: {
                if let c = trashCandidate {
                    if let problem = model.manualTrashProblem(c) {
                        Text("DiskLens will not move this item: \(problem)")
                    } else {
                        Text("\(tree.path(of: c))\n\n\(ByteFormat.string(tree.nodes[Int(c)].allocated)) on disk (measured at scan time). Moving to the Trash is reversible; the space is freed when you empty the Trash. DiskLens re-checks the item before moving it.")
                    }
                }
            }
        }
    }

    func trashTitle(_ tree: ScanTree) -> String {
        guard let c = trashCandidate else { return "" }
        return "Move “\(tree.nodes[Int(c)].name)” to the Trash?"
    }

    @ViewBuilder
    func row(_ k: String, _ v: String, _ note: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 0) {
                Text(v).monospacedDigit()
                if !note.isEmpty { Text(note).font(.caption2).foregroundStyle(Theme.muted) }
            }
        }
    }
}

struct FlagBadges: View {
    var flags: NodeFlags
    var errors: Int32
    var body: some View {
        let items: [(String, Color)] = [
            flags.contains(.unreadable) ? ("Unreadable (permissions/TCC) — size unknown, not zero", Theme.warn) : nil,
            flags.contains(.partial) && !flags.contains(.unreadable) ? ("\(errors) unreadable item(s) inside — totals are a lower bound", Theme.warn) : nil,
            flags.contains(.mountBoundary) ? ("Mount point — not crossed", Theme.muted) : nil,
            flags.contains(.sparse) ? ("Sparse file: allocated ≪ logical", Theme.accent) : nil,
            flags.contains(.dataless) ? ("Cloud placeholder (not stored locally)", Theme.accent) : nil,
            flags.contains(.aggregate) ? ("Aggregate of files below 1 MB", Theme.muted) : nil,
        ].compactMap { $0 }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.0) { t in
                    Label(t.0, systemImage: "info.circle").font(.caption).foregroundStyle(t.1)
                }
            }
        }
    }
}

struct RecommendationBadge: View {
    @Environment(AppModel.self) private var model
    var rec: Recommendation
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(rec.tier.label, systemImage: rec.tier == .manualReview ? "hand.raised.fill" : "sparkles")
                .font(.caption.bold()).foregroundStyle(rec.tier == .manualReview ? Theme.warn : Theme.good)
            Text(rec.title).font(.caption)
            Text("≈ \(ByteFormat.string(rec.estimatedReclaimable)) reclaimable · \(rec.reclaimMethod)").font(.caption2).foregroundStyle(Theme.muted)
            Button("Open in Cleanup") { model.activeRecID = rec.id; model.pane = .cleanup }.controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
    }
}

struct ChildrenList: View {
    @Environment(AppModel.self) private var model
    var parent: Int32

    var body: some View {
        @Bindable var model = model
        if let tree = model.tree, parent >= 0 {
            let kids = sorted(tree, tree.nodes[Int(parent)].children)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Contents (\(kids.count))").font(.caption.bold()).foregroundStyle(Theme.muted)
                    Spacer()
                    Picker("", selection: $model.childSort) { ForEach(ChildSort.allCases) { Text($0.rawValue).tag($0) } }
                        .labelsHidden().controlSize(.small).fixedSize()
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                List(kids.prefix(500), id: \.self) { id in
                    let n = tree.nodes[Int(id)]
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(n.category.color).frame(width: 4, height: 18)
                        Text(n.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(value(n)).font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.selection = id }
                    .onTapGesture(count: 2) { model.zoom(into: id) }
                    .listRowBackground(model.selection == id ? Theme.accent.opacity(0.2) : Color.clear)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    func value(_ n: ScanNode) -> String {
        switch model.childSort {
        case .logical: return ByteFormat.string(n.logical)
        case .files: return n.fileCount.formatted() + " files"
        default: return ByteFormat.string(n.allocated)
        }
    }

    func sorted(_ tree: ScanTree, _ ids: [Int32]) -> [Int32] {
        let minBytes = Int64(model.minSizeMB * 1_000_000)
        let f = ids.filter { tree.nodes[Int($0)].allocated >= minBytes }
        switch model.childSort {
        case .allocated: return f.sorted { tree.nodes[Int($0)].allocated > tree.nodes[Int($1)].allocated }
        case .logical: return f.sorted { tree.nodes[Int($0)].logical > tree.nodes[Int($1)].logical }
        case .files: return f.sorted { tree.nodes[Int($0)].fileCount > tree.nodes[Int($1)].fileCount }
        case .name: return f.sorted { tree.nodes[Int($0)].name.localizedStandardCompare(tree.nodes[Int($1)].name) == .orderedAscending }
        }
    }
}
