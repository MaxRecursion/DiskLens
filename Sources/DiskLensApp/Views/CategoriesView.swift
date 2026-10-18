import SwiftUI
import Charts
import DiskLensCore

struct CategoriesView: View {
    @Environment(AppModel.self) private var model

    struct Row: Identifiable { var id: StorageCategory { cat }; var cat: StorageCategory; var bytes: Int64; var files: Int64 }

    var body: some View {
        if let tree = model.tree {
            let totals = tree.categoryTotals()
            var rows = totals.map { Row(cat: $0.key, bytes: $0.value.allocated, files: $0.value.files) }.sorted { $0.bytes > $1.bytes }
            let _ = { if !rows.contains(where: { $0.cat == .inaccessible }) && (model.scan?.manifest.stats.unreadableDirectories ?? 0) > 0 { rows.append(Row(cat: .inaccessible, bytes: 0, files: 0)) } }()
            let ruleTotals = Classifier.ruleTotals(tree).sorted { $0.value > $1.value }
            let rules = Dictionary(uniqueKeysWithValues: Classifier.defaultRules().map { ($0.id, $0) })
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Storage by category").font(.title2.bold())
                    Text("Each byte of the scan is attributed to exactly one category (computed from leaf entries), so the bars sum to the scanned total of \(ByteFormat.gb(tree.totalAllocated)).")
                        .font(.callout).foregroundStyle(Theme.muted)
                    Chart(rows) { r in
                        BarMark(x: .value("GB", Double(r.bytes) / 1e9), y: .value("Category", r.cat.displayName))
                            .foregroundStyle(r.cat.color)
                            .annotation(position: .trailing) {
                                Text(r.cat == .inaccessible ? "unknown — \(model.scan?.manifest.stats.unreadableDirectories ?? 0) unreadable folders" : ByteFormat.gb(r.bytes))
                                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                            }
                    }
                    .chartXAxisLabel("GB on disk")
                    .frame(height: CGFloat(rows.count) * 34 + 30)
                    .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))

                    Text("How bytes were classified").font(.title3.bold())
                    Text("Rules are evaluated top-down; a sticky rule classifies its whole subtree. Every node records the rule that classified it (shown in the inspector).")
                        .font(.callout).foregroundStyle(Theme.muted)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("Rule").bold(); Text("Category").bold(); Text("Description").bold(); Text("On disk").bold()
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(ruleTotals.prefix(60), id: \.key) { kv in
                            GridRow {
                                Text(kv.key).font(.caption.monospaced())
                                Text(rules[kv.key]?.category.displayName ?? (kv.key == Classifier.unreadableRuleID ? StorageCategory.inaccessible.displayName : "Other Files")).font(.caption)
                                Text(rules[kv.key]?.description ?? (kv.key == Classifier.unreadableRuleID ? "Folders that could not be read (size unknown)" : "Unmatched (inherits Other)")).font(.caption).foregroundStyle(Theme.muted)
                                Text(ByteFormat.gb(kv.value)).font(.caption.monospacedDigit())
                            }
                        }
                    }
                    .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                }
                .padding(20)
            }
        }
    }
}

struct LargestFilesView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let tree = model.tree {
            let files = tree.largestFiles(limit: 300)
            VStack(alignment: .leading, spacing: 8) {
                Text("Largest individual files").font(.title2.bold()).padding([.horizontal, .top], 20)
                Text("Large is not the same as junk — use this list to spot forgotten downloads, VM images and media. Double-click to show in the treemap.")
                    .font(.callout).foregroundStyle(Theme.muted).padding(.horizontal, 20)
                Table(files.map { FileRow(id: $0, node: tree.nodes[Int($0)], path: tree.path(of: $0)) }) {
                    TableColumn("Name") { r in
                        HStack { RoundedRectangle(cornerRadius: 2).fill(r.node.category.color).frame(width: 4, height: 16); Text(r.node.name).lineLimit(1) }
                    }
                    TableColumn("On disk") { r in Text(ByteFormat.string(r.node.allocated)).monospacedDigit() }.width(90)
                    TableColumn("Logical") { r in Text(ByteFormat.string(r.node.logical)).monospacedDigit() }.width(90)
                    TableColumn("Category") { r in Text(r.node.category.displayName).foregroundStyle(Theme.muted) }.width(170)
                    TableColumn("Path") { r in Text(PathUtil.abbreviated(r.path)).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle) }
                }
                .contextMenu(forSelectionType: Int32.self) { _ in } primaryAction: { ids in
                    if let id = ids.first { model.navigate(to: id) }
                }
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
            }
        }
    }
    struct FileRow: Identifiable { var id: Int32; var node: ScanNode; var path: String }
}
