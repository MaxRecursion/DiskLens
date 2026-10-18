import Foundation
import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
/// Pure function: the returned rectangles are in the same order as `values`, tile `bounds`
/// exactly (up to floating-point error), never overlap, and have area proportional to value.
public enum SquarifiedTreemap {
    public static func layout(_ values: [Double], in bounds: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: values.count)
        guard bounds.width > 0, bounds.height > 0 else { return result }
        let positive = values.enumerated().filter { $0.element > 0 && $0.element.isFinite }
        guard !positive.isEmpty else { return result }
        let total = positive.reduce(0.0) { $0 + $1.element }
        let scale = Double(bounds.width * bounds.height) / total
        // Sort by value descending; keep original indices.
        let items = positive.sorted { $0.element > $1.element }.map { (index: $0.offset, area: $0.element * scale) }

        var remaining = bounds
        var row: [(index: Int, area: Double)] = []
        var i = 0
        while i < items.count {
            let side = Double(min(remaining.width, remaining.height))
            let candidate = row + [items[i]]
            if row.isEmpty || worst(candidate, side: side) <= worst(row, side: side) {
                row = candidate
                i += 1
            } else {
                remaining = place(row, in: remaining, into: &result, isLast: false)
                row = []
            }
        }
        if !row.isEmpty { _ = place(row, in: remaining, into: &result, isLast: true) }
        return result
    }

    /// Worst aspect ratio of a row laid along a side of length `side`.
    static func worst(_ row: [(index: Int, area: Double)], side: Double) -> Double {
        guard !row.isEmpty, side > 0 else { return .infinity }
        let s = row.reduce(0.0) { $0 + $1.area }
        guard s > 0 else { return .infinity }
        let rmax = row.map(\.area).max()!
        let rmin = row.map(\.area).min()!
        let s2 = s * s, w2 = side * side
        return max(w2 * rmax / s2, s2 / (w2 * rmin))
    }

    /// Lays a row along the shorter side of `rect`; returns the remaining rectangle.
    static func place(_ row: [(index: Int, area: Double)], in rect: CGRect, into result: inout [CGRect], isLast: Bool) -> CGRect {
        let s = row.reduce(0.0) { $0 + $1.area }
        if rect.width >= rect.height {
            // Column on the left.
            let w = isLast ? Double(rect.width) : min(Double(rect.width), s / Double(rect.height))
            var y = Double(rect.minY)
            for (k, item) in row.enumerated() {
                let h = k == row.count - 1 ? Double(rect.maxY) - y : item.area / w
                result[item.index] = CGRect(x: Double(rect.minX), y: y, width: w, height: max(0, h))
                y += h
            }
            return CGRect(x: Double(rect.minX) + w, y: Double(rect.minY), width: max(0, Double(rect.width) - w), height: Double(rect.height))
        } else {
            // Row on the top.
            let h = isLast ? Double(rect.height) : min(Double(rect.height), s / Double(rect.width))
            var x = Double(rect.minX)
            for (k, item) in row.enumerated() {
                let w = k == row.count - 1 ? Double(rect.maxX) - x : item.area / h
                result[item.index] = CGRect(x: x, y: Double(rect.minY), width: max(0, w), height: h)
                x += w
            }
            return CGRect(x: Double(rect.minX), y: Double(rect.minY) + h, width: Double(rect.width), height: max(0, Double(rect.height) - h))
        }
    }
}

/// A tile produced for a scan-tree node. Used by the app's Canvas renderer and tests.
public struct TreemapTile: Sendable, Hashable {
    public var nodeID: Int32
    public var rect: CGRect
    public var depth: Int
    public var isOtherBucket: Bool
    public var otherCount: Int
}

public enum TreemapBuilder {
    /// Builds tiles for `focus`'s children (and optionally grandchildren for nesting).
    /// Children smaller than `minFraction` of the focus are merged into one "other" tile so the
    /// map stays readable. Sizes use allocated bytes (what actually occupies the disk).
    public static func tiles(tree: ScanTree, focus: Int32, bounds: CGRect, maxDepth: Int = 2,
                             minTileArea: CGFloat = 36, headerHeight: CGFloat = 16, padding: CGFloat = 2,
                             include: (ScanNode) -> Bool = { _ in true }) -> [TreemapTile] {
        var out: [TreemapTile] = []
        build(tree: tree, node: focus, bounds: bounds, depth: 1, maxDepth: maxDepth, minTileArea: minTileArea,
              headerHeight: headerHeight, padding: padding, include: include, out: &out)
        return out
    }

    static func build(tree: ScanTree, node: Int32, bounds: CGRect, depth: Int, maxDepth: Int, minTileArea: CGFloat,
                      headerHeight: CGFloat, padding: CGFloat, include: (ScanNode) -> Bool, out: inout [TreemapTile]) {
        let kids = tree.nodes[Int(node)].children.filter { include(tree.nodes[Int($0)]) && tree.nodes[Int($0)].allocated > 0 }
            .sorted { tree.nodes[Int($0)].allocated > tree.nodes[Int($1)].allocated }
        guard !kids.isEmpty, bounds.width > 2, bounds.height > 2 else { return }
        let total = Double(kids.reduce(Int64(0)) { $0 + tree.nodes[Int($1)].allocated })
        guard total > 0 else { return }
        let area = Double(bounds.width * bounds.height)
        // Keep children whose tile would be at least minTileArea; merge the rest.
        var shown: [Int32] = []
        var otherBytes: Int64 = 0
        var otherCount = 0
        for k in kids {
            let a = Double(tree.nodes[Int(k)].allocated) / total * area
            if a >= Double(minTileArea) && shown.count < 400 { shown.append(k) } else {
                otherBytes += tree.nodes[Int(k)].allocated; otherCount += 1
            }
        }
        var values = shown.map { Double(tree.nodes[Int($0)].allocated) }
        if otherBytes > 0 { values.append(Double(otherBytes)) }
        let rects = SquarifiedTreemap.layout(values, in: bounds)
        for (i, k) in shown.enumerated() {
            let r = rects[i]
            out.append(TreemapTile(nodeID: k, rect: r, depth: depth, isOtherBucket: false, otherCount: 0))
            let child = tree.nodes[Int(k)]
            if depth < maxDepth && child.isDirectory && !child.children.isEmpty
                && r.width > 40 && r.height > headerHeight + 24 {
                let inner = CGRect(x: r.minX + padding, y: r.minY + headerHeight,
                                   width: r.width - padding * 2, height: r.height - headerHeight - padding)
                build(tree: tree, node: k, bounds: inner, depth: depth + 1, maxDepth: maxDepth, minTileArea: minTileArea,
                      headerHeight: headerHeight, padding: padding, include: include, out: &out)
            }
        }
        if otherBytes > 0, let r = rects.last {
            out.append(TreemapTile(nodeID: node, rect: r, depth: depth, isOtherBucket: true, otherCount: otherCount))
        }
    }
}
