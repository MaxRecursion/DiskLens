import Testing
import Foundation
@testable import DiskLensCore

@Suite("Category assignment")
struct ClassifierTests {
    func buildHome() -> Fixture {
        let fx = Fixture("home")
        fx.file(".npm/_cacache/content-v2/x.bin", bytes: 2_000_000)
        fx.file("proj/package.json", bytes: 50)
        fx.file("proj/node_modules/pkg/index.js", bytes: 1_200_000)
        fx.file("proj/node_modules/pkg/logo.png", bytes: 1_500_000)   // sticky: stays developer artifact
        fx.file("proj/src/app.ts", bytes: 2_000)
        fx.file("Downloads/Installer.dmg", bytes: 3_000_000)
        fx.file("Downloads/notes.txt", bytes: 100)
        fx.file("Documents/report.pdf", bytes: 1_100_000)
        fx.file("Documents/code/node_modules/x/y.js", bytes: 1_300_000)  // non-sticky container overridden
        fx.file("dotnetproj/App.csproj", bytes: 100)
        fx.file("dotnetproj/bin/Debug/App.dll", bytes: 1_400_000)
        fx.file("other/bin/tool", bytes: 1_100_000)                      // bin without .csproj
        fx.file("py/.venv/pyvenv.cfg", bytes: 50)
        fx.file("py/.venv/lib/big.so", bytes: 1_200_000)
        fx.file("models/llama.gguf", bytes: 1_600_000)
        fx.file("Library/Caches/com.example/cache.db", bytes: 1_000_000)
        fx.file("Applications/Foo.app/Contents/MacOS/Foo", bytes: 1_000_000)
        return fx
    }

    @Test func assignsExpectedCategories() throws {
        let fx = buildHome()
        var t = try fx.scan().tree
        Classifier.classify(&t, rules: Classifier.defaultRules(home: fx.root))
        func cat(_ rel: String) throws -> StorageCategory { t[try #require(t.find(path: fx.path(rel)))].category }
        #expect(try cat(".npm") == .packageCaches)
        #expect(try cat("proj/node_modules") == .developerArtifacts)
        #expect(try cat("proj/node_modules/pkg/logo.png") == .developerArtifacts)
        #expect(try cat("Downloads/Installer.dmg") == .downloadsArchives)
        #expect(try cat("Documents/report.pdf") == .documentsMedia)
        #expect(try cat("Documents/code/node_modules") == .developerArtifacts)
        #expect(try cat("dotnetproj/bin") == .developerArtifacts)
        #expect(try cat("other/bin") == .other)
        #expect(try cat("py/.venv") == .developerArtifacts)
        #expect(try cat("models/llama.gguf") == .aiTools)
        #expect(try cat("Library/Caches/com.example") == .systemManaged)
        #expect(try cat("Applications/Foo.app") == .applications)
        let nm = try #require(t.find(path: fx.path("proj/node_modules")))
        #expect(t[nm].categoryRule == "node-modules")
    }

    @Test func bundleSuffixRequiresBundleStructure() throws {
        let fx = Fixture("bundle")
        fx.file("Library/Caches/com.example.app/blob.bin", bytes: 1_300_000)   // cache named after a bundle id
        fx.file("Projects/notes.app/readme.txt", bytes: 1_100_000)               // folder named like an app
        fx.file("Applications/Real.app/Contents/MacOS/Real", bytes: 1_200_000)
        var t = try fx.scan().tree
        Classifier.classify(&t, rules: Classifier.defaultRules(home: fx.root))
        func cat(_ rel: String) throws -> StorageCategory { t[try #require(t.find(path: fx.path(rel)))].category }
        #expect(try cat("Applications/Real.app") == .applications)
        #expect(try cat("Library/Caches/com.example.app") != .applications)
        #expect(try cat("Projects/notes.app") != .applications)
    }

    @Test func everyByteCountedInExactlyOneCategory() throws {
        let fx = buildHome()
        var t = try fx.scan().tree
        Classifier.classify(&t, rules: Classifier.defaultRules(home: fx.root))
        let totals = t.categoryTotals()
        let sumAlloc = totals.values.reduce(Int64(0)) { $0 + $1.allocated }
        let sumLogical = totals.values.reduce(Int64(0)) { $0 + $1.logical }
        let sumFiles = totals.values.reduce(Int64(0)) { $0 + $1.files }
        #expect(sumAlloc == t.totalAllocated)
        #expect(sumLogical == t.totalLogical)
        #expect(sumFiles == t.nodes[0].fileCount)
        // Dominant category of the home root is the one with the most bytes.
        let dom = t.dominantCategories()
        let best = totals.max { $0.value.allocated < $1.value.allocated }!.key
        #expect(dom[Int(t.rootIDs[0])] == best)
        let nm = try #require(t.find(path: fx.path("proj/node_modules")))
        #expect(dom[Int(nm)] == .developerArtifacts)
        // Every node has a rule id (transparency).
        #expect(t.nodes.allSatisfy { !$0.categoryRule.isEmpty })
    }

    @Test func rootsInheritRulesAboveThem() throws {
        let fx = Fixture("rootrule")
        fx.file("Library/Caches/com.app/x.bin", bytes: 1_200_000)
        var t = try DiskScanner.scanSync(options: ScanOptions(roots: [fx.path("Library/Caches/com.app")])).tree
        Classifier.classify(&t, rules: Classifier.defaultRules(home: fx.root))
        #expect(t[t.rootIDs[0]].category == .systemManaged)
        #expect(t[t.rootIDs[0]].categoryRule == "user-caches")
    }

    @Test func explicitPathRuleBeatsInheritedStickyRule() throws {
        let fx = Fixture("sticky")
        fx.file("L/app/x.bin", bytes: 1_100_000)
        fx.file("L/Developer/sdk.bin", bytes: 1_100_000)
        var t = try fx.scan().tree
        let rules = [ClassificationRule("lib", .systemManaged, .path(fx.path("L")), sticky: true, "lib"),
                     ClassificationRule("dev", .sdkData, .path(fx.path("L/Developer")), sticky: true, "dev")]
        Classifier.classify(&t, rules: rules)
        #expect(t[try #require(t.find(path: fx.path("L/Developer")))].category == .sdkData)
        #expect(t[try #require(t.find(path: fx.path("L/app")))].category == .systemManaged)
    }
}
