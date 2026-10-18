import SwiftUI
import DiskLensCore

struct ExplorerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ExplorerToolbar()
                ZStack(alignment: .top) {
                    TreemapView()
                        .padding(10)
                    if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        SearchResultsView()
                            .padding(.horizontal, 10).padding(.top, 4)
                    }
                }
                LegendBar()
            }
            Divider().opacity(0.4)
            InspectorView()
                .frame(width: 370)
        }
    }
}

struct ExplorerToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { model.zoomOut() } label: { Image(systemName: "chevron.left") }
                    .help("Go up one level (⌘↑)")
                    .accessibilityLabel("Go up one level")
                    .disabled(model.focus == ScanTree.root)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Breadcrumbs()
                Spacer()
                TextField("Search files & folders", text: $model.searchText)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
            HStack(spacing: 12) {
                Text("Min size").font(.caption).foregroundStyle(Theme.muted)
                if model.renderStaticTreemap {
                    // Offscreen capture cannot draw AppKit's slider track; draw an equivalent for snapshots.
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15)).frame(height: 4)
                        Circle().fill(.white).shadow(radius: 1).frame(width: 14, height: 14)
                            .offset(x: CGFloat(model.minSizeMB / 2000) * 146)
                    }
                    .frame(width: 160)
                } else {
                    Slider(value: $model.minSizeMB, in: 0...2000, step: 10).frame(width: 160)
                        .accessibilityLabel("Minimum size")
                }
                Text(model.minSizeMB == 0 ? "all" : ByteFormat.string(Int64(model.minSizeMB) * 1_000_000))
                    .font(.caption.monospacedDigit()).frame(width: 64, alignment: .leading)
                Menu {
                    ForEach(StorageCategory.allCases, id: \.self) { c in
                        Button {
                            if model.hiddenCategories.contains(c) { model.hiddenCategories.remove(c) } else { model.hiddenCategories.insert(c) }
                        } label: {
                            Label(c.displayName, systemImage: model.hiddenCategories.contains(c) ? "circle" : "checkmark.circle.fill")
                        }
                    }
                    Divider()
                    Button("Show all") { model.hiddenCategories = [] }
                } label: {
                    Label(model.hiddenCategories.isEmpty ? "All categories" : "\(StorageCategory.allCases.count - model.hiddenCategories.count) categories",
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Text("Double-click a folder to zoom · ⌘↑ to go up").font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panel.opacity(0.6))
    }
}

struct Breadcrumbs: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let tree = model.tree {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach([ScanTree.root] + tree.ancestry(of: model.focus), id: \.self) { id in
                        let n = tree.nodes[Int(id)]
                        Button {
                            model.focus = id; model.selection = nil
                        } label: {
                            Text(id == ScanTree.root ? "All scanned locations" : (n.parent == ScanTree.root ? PathUtil.abbreviated(n.name) : n.name))
                                .lineLimit(1)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(id == model.focus ? Theme.accent.opacity(0.25) : Theme.card))
                        }
                        .buttonStyle(.plain)
                        if id != model.focus { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.muted) }
                    }
                }
            }
        }
    }
}

struct LegendBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let tree = model.tree {
            let totals = tree.categoryTotals(under: model.focus)
            let total = max(1, totals.values.reduce(Int64(0)) { $0 + $1.allocated })
            FlowLayout(spacing: 12, lineSpacing: 4) {
                ForEach(StorageCategory.allCases.filter { (totals[$0]?.allocated ?? 0) > 0 }, id: \.self) { c in
                    let pct = Int((Double(totals[c]!.allocated) / Double(total) * 100).rounded())
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(c.color).frame(width: 10, height: 10)
                        Text("\(c.shortName) \(pct)%")
                            .font(.caption2).lineLimit(1).fixedSize()
                            .foregroundStyle(model.hiddenCategories.contains(c) ? Theme.muted.opacity(0.5) : Theme.muted)
                    }
                    .help(c.displayName)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(c.displayName), \(pct) percent")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

/// Canvas-rendered squarified treemap of the focused folder (two levels deep).
struct TreemapView: View {
    @Environment(AppModel.self) private var model
    @State private var tiles: [TreemapTile] = []
    @State private var hovered: TreemapTile?
    @State private var hoverPoint: CGPoint = .zero
    @State private var size: CGSize = .zero

    struct LayoutKey: Equatable { var focus: Int32; var size: CGSize; var minMB: Double; var scan: UUID? }

    var body: some View {
        GeometryReader { geo in
            let key = LayoutKey(focus: model.focus, size: geo.size, minMB: model.minSizeMB, scan: model.scan?.manifest.scanID)
            ZStack(alignment: .topLeading) {
                treemapSurface(size: geo.size)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Treemap of \(model.tree.map { model.focus == ScanTree.root ? "all scanned locations" : PathUtil.abbreviated($0.path(of: model.focus)) } ?? "")")
                    .accessibilityChildren {
                        ForEach(tiles.filter { $0.depth == 1 }, id: \.self) { t in
                            Rectangle()
                                .frame(width: t.rect.width, height: t.rect.height)
                                .position(x: t.rect.midX, y: t.rect.midY)
                                .accessibilityLabel(accessibilityText(t))
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { openTile(t) }
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hoverPoint = p; hovered = tile(at: p)
                        case .ended: hovered = nil
                        }
                    }
                    .gesture(
                        SpatialTapGesture(count: 2).onEnded { v in
                            if let t = tile(at: v.location) { openTile(t) }
                        }
                        .exclusively(before: SpatialTapGesture(count: 1).onEnded { v in
                            if let t = tile(at: v.location), !t.isOtherBucket { model.selection = t.nodeID }
                        })
                    )
                if let h = hovered, let tree = model.tree {
                    TileTooltip(tile: h, tree: tree, reclaim: h.isOtherBucket ? 0 : model.reclaimable(under: h.nodeID))
                        .offset(x: min(hoverPoint.x + 14, max(0, geo.size.width - 300)), y: min(hoverPoint.y + 14, max(0, geo.size.height - 120)))
                        .allowsHitTesting(false)
                }
            }
            .onAppear { relayout(key) }
            .onChange(of: key) { _, k in relayout(k) }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.treemapBackground))
    }

    @ViewBuilder
    func treemapSurface(size: CGSize) -> some View {
        if model.renderStaticTreemap, let tree = model.tree {
            // Offscreen capture (store screenshots) cannot see Canvas drawing; render it to an image.
            let t = TreemapBuilder.tiles(tree: tree, focus: model.focus, bounds: CGRect(origin: .zero, size: size), maxDepth: 2,
                                         minTileArea: 70, headerHeight: 18, padding: 3)
            let dom = model.dominant
            let renderer = ImageRenderer(content: Canvas { ctx, _ in
                TreemapView.drawTiles(ctx, tiles: t, tree: tree, selection: nil, hovered: nil, hidden: [], dominant: dom)
            }.frame(width: size.width, height: size.height))
            let _ = renderer.scale = 2
            if let img = renderer.nsImage { Image(nsImage: img).resizable().frame(width: size.width, height: size.height) }
        } else {
            Canvas { ctx, _ in draw(ctx) }
        }
    }

    func accessibilityText(_ t: TreemapTile) -> String {
        guard let tree = model.tree else { return "" }
        if t.isOtherBucket { return "\(t.otherCount) smaller items" }
        let n = tree.nodes[Int(t.nodeID)]
        return "\(n.parent == ScanTree.root ? PathUtil.abbreviated(n.name) : n.name), \(ByteFormat.string(n.allocated)), \(n.category.displayName)"
    }

    func relayout(_ k: LayoutKey) {
        guard let tree = model.tree, k.size.width > 10, k.size.height > 10 else { tiles = []; return }
        model.ensureDominant()
        let minBytes = Int64(k.minMB * 1_000_000)
        tiles = TreemapBuilder.tiles(tree: tree, focus: k.focus, bounds: CGRect(origin: .zero, size: k.size), maxDepth: 2,
                                     minTileArea: 70, headerHeight: 18, padding: 3,
                                     include: { $0.allocated >= minBytes })
        if ProcessInfo.processInfo.environment["DISKLENS_DEBUG"] != nil {
            FileHandle.standardError.write(Data("treemap relayout focus=\(k.focus) size=\(k.size) tiles=\(tiles.count)\n".utf8))
        }
    }

    func tile(at p: CGPoint) -> TreemapTile? {
        // Deepest tile containing the point (tiles are emitted parent-first).
        tiles.last { $0.rect.contains(p) }
    }

    func openTile(_ t: TreemapTile) {
        guard !t.isOtherBucket else { return }
        model.zoom(into: t.nodeID)
        if model.focus != t.nodeID { model.selection = t.nodeID }
    }

    func draw(_ ctx: GraphicsContext) {
        guard let tree = model.tree else { return }
        TreemapView.drawTiles(ctx, tiles: tiles, tree: tree, selection: model.selection, hovered: hovered, hidden: model.hiddenCategories,
                              dominant: model.dominant)
    }

    /// Shared tile renderer (used by the live Canvas and by snapshot verification).
    static func drawTiles(_ ctx: GraphicsContext, tiles: [TreemapTile], tree: ScanTree, selection: Int32?, hovered: TreemapTile?,
                          hidden: Set<StorageCategory>, dominant: [StorageCategory] = []) {
        for t in tiles {
            var n = tree.nodes[Int(t.nodeID)]
            if Int(t.nodeID) < dominant.count { n.category = dominant[Int(t.nodeID)] }
            let r = t.rect.insetBy(dx: 0.75, dy: 0.75)
            guard r.width > 1, r.height > 1 else { continue }
            let dimmed = !t.isOtherBucket && hidden.contains(n.category)
            var base = t.isOtherBucket ? Color.gray : n.category.color
            if n.flags.contains(.unreadable) { base = .gray }
            let shade = t.depth == 1 ? 0.55 : 0.85
            let path = Path(roundedRect: r, cornerRadius: t.depth == 1 ? 5 : 3)
            ctx.fill(path, with: .linearGradient(Gradient(colors: [base.opacity(dimmed ? 0.12 : shade), base.opacity(dimmed ? 0.08 : shade * 0.72)]),
                                                 startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)))
            let isSel = selection == t.nodeID && !t.isOtherBucket
            let isHover = hovered == t
            ctx.stroke(path, with: .color(isSel ? .white : (isHover ? .white.opacity(0.8) : .black.opacity(0.35))), lineWidth: isSel ? 2.5 : (isHover ? 1.5 : 0.75))
            if n.flags.contains(.unreadable) {
                ctx.stroke(Path { p in p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)) }, with: .color(.white.opacity(0.3)))
            }
            let name = t.isOtherBucket ? "\(t.otherCount) smaller items" : (n.parent == ScanTree.root ? PathUtil.abbreviated(n.name) : n.name)
            if r.width > 54 && r.height > 15 {
                let hasChildrenDrawn = t.depth == 1 && tiles.contains { $0.depth == 2 && r.contains($0.rect.origin) }
                let size = t.isOtherBucket ? "" : ByteFormat.string(n.allocated)
                let label = Text("\(name)  ").font(.system(size: t.depth == 1 ? 11 : 10, weight: t.depth == 1 ? .semibold : .regular))
                    + Text(size).font(.system(size: 9.5).monospacedDigit()).foregroundColor(.white.opacity(0.7))
                ctx.draw(label.foregroundColor(.white), in: CGRect(x: r.minX + 5, y: r.minY + 2, width: r.width - 8, height: hasChildrenDrawn ? 16 : min(r.height - 4, 30)))
            }
        }
    }
}

struct TileTooltip: View {
    var tile: TreemapTile
    var tree: ScanTree
    var reclaim: Int64
    var body: some View {
        let n = tree.nodes[Int(tile.nodeID)]
        VStack(alignment: .leading, spacing: 3) {
            if tile.isOtherBucket {
                Text("\(tile.otherCount) smaller items in \(n.name)").font(.caption.bold())
            } else {
                Text(PathUtil.abbreviated(tree.path(of: tile.nodeID))).font(.caption.bold()).lineLimit(2)
                Text("\(ByteFormat.string(n.allocated)) on disk · \(ByteFormat.string(n.logical)) logical").font(.caption2.monospacedDigit())
                Text("\(n.fileCount.formatted()) files · \(n.category.displayName)").font(.caption2).foregroundStyle(Theme.muted)
                if reclaim > 0 { Text("≈ \(ByteFormat.string(reclaim)) reclaimable (estimate)").font(.caption2).foregroundStyle(Theme.good) }
                if n.flags.contains(.unreadable) { Text("Unreadable — size unknown").font(.caption2).foregroundStyle(Theme.warn) }
            }
        }
        .padding(8)
        .frame(maxWidth: 290, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThickMaterial))
    }
}

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let tree = model.tree {
            let hits = tree.search(model.searchText, limit: 200, minAllocated: Int64(model.minSizeMB * 1_000_000))
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("\(hits.count == 200 ? "200+" : String(hits.count)) matches (files ≥ 1 MB and all folders are indexed)").font(.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Close") { model.searchText = "" }.buttonStyle(.link)
                }
                .padding(8)
                List(hits, id: \.self) { id in
                    let n = tree.nodes[Int(id)]
                    Button { model.navigate(to: id); model.searchText = "" } label: {
                        HStack {
                            Image(systemName: n.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(n.category.color)
                            VStack(alignment: .leading) {
                                Text(n.name).lineLimit(1)
                                Text(PathUtil.abbreviated(tree.path(of: id))).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(ByteFormat.string(n.allocated)).font(.caption.monospacedDigit())
                        }
                    }
                    .buttonStyle(.plain)
                }
                .scrollContentBackground(.hidden)
            }
            .frame(maxHeight: 380)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel).shadow(radius: 12))
        }
    }
}

/// Left-aligned layout that wraps its children onto new lines when they do not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
