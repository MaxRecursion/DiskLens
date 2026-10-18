import Testing
import Foundation
import CoreGraphics
@testable import DiskLensCore

@Suite("Squarified treemap layout")
struct TreemapTests {
    let bounds = CGRect(x: 10, y: 20, width: 800, height: 500)

    @Test func areasAreProportionalToValues() {
        let values: [Double] = [500, 300, 120, 50, 20, 7, 3]
        let rects = SquarifiedTreemap.layout(values, in: bounds)
        let total = values.reduce(0, +)
        let area = Double(bounds.width * bounds.height)
        for (v, r) in zip(values, rects) {
            let expected = v / total * area
            #expect(abs(Double(r.width * r.height) - expected) < expected * 1e-6 + 1e-6)
        }
    }

    @Test func tilesCoverBoundsWithoutOverlap() {
        let values: [Double] = (1...40).map { Double($0 * $0 % 97 + 1) }
        let rects = SquarifiedTreemap.layout(values, in: bounds)
        let sumArea = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        #expect(abs(sumArea - Double(bounds.width * bounds.height)) < 1e-3)
        for r in rects {
            #expect(r.minX >= bounds.minX - 1e-6 && r.maxX <= bounds.maxX + 1e-6)
            #expect(r.minY >= bounds.minY - 1e-6 && r.maxY <= bounds.maxY + 1e-6)
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let inter = rects[i].intersection(rects[j])
                #expect(inter.isNull || inter.width * inter.height < 1e-6, "tiles \(i) and \(j) overlap")
            }
        }
    }

    @Test func zeroAndInvalidValuesGetEmptyTiles() {
        let rects = SquarifiedTreemap.layout([10, 0, -5, .nan, 30], in: bounds)
        #expect(rects[1] == .zero && rects[2] == .zero && rects[3] == .zero)
        #expect(rects[0].width * rects[0].height > 0)
        #expect(SquarifiedTreemap.layout([], in: bounds).isEmpty)
        #expect(SquarifiedTreemap.layout([0, 0], in: bounds) == [.zero, .zero])
    }

    @Test func singleValueFillsBounds() {
        let r = SquarifiedTreemap.layout([42], in: bounds)
        #expect(r[0] == bounds)
    }

    @Test func aspectRatiosAreReasonable() {
        let values = Array(repeating: 1.0, count: 16)
        let rects = SquarifiedTreemap.layout(values, in: CGRect(x: 0, y: 0, width: 400, height: 400))
        for r in rects {
            let ar = max(r.width / r.height, r.height / r.width)
            #expect(ar < 2.5)
        }
    }

    @Test func builderSizesTilesByAllocatedBytesAndBucketsTinyChildren() throws {
        let fx = Fixture("tm")
        fx.file("big/a.bin", bytes: 8_000_000)
        fx.file("mid/b.bin", bytes: 3_000_000)
        for i in 0..<30 { fx.file("tiny\(i)/t.bin", bytes: 1_100_000) }
        let t = try fx.scan().tree
        let root = t.rootIDs[0]
        let tiles = TreemapBuilder.tiles(tree: t, focus: root, bounds: CGRect(x: 0, y: 0, width: 300, height: 200),
                                         maxDepth: 1, minTileArea: 2000)
        let big = try #require(tiles.first { !$0.isOtherBucket && t[$0.nodeID].name == "big" })
        let mid = try #require(tiles.first { !$0.isOtherBucket && t[$0.nodeID].name == "mid" })
        let ratio = Double(big.rect.width * big.rect.height) / Double(mid.rect.width * mid.rect.height)
        let expected = Double(t[big.nodeID].allocated) / Double(t[mid.nodeID].allocated)
        #expect(abs(ratio - expected) / expected < 0.01)
        #expect(tiles.contains { $0.isOtherBucket && $0.otherCount > 0 })
    }
}
