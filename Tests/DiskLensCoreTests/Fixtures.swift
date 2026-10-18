import Foundation
import Darwin
@testable import DiskLensCore

/// A disposable directory tree under the system temp folder. All destructive tests run only
/// against fixtures like this — never against real user data.
final class Fixture {
    let root: String

    init(_ label: String = "fixture") {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskLensTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = PathUtil.canonical(base.path)!
    }

    deinit {
        // Restore permissions that tests may have removed, then clean up.
        _ = try? ProcessRunner.run("/bin/chmod", ["-R", "u+rwx", root], timeout: 30)
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }

    @discardableResult
    func dir(_ rel: String) -> String {
        let p = path(rel)
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// Writes a file of exactly `bytes` bytes (non-zero content so it is not sparse).
    @discardableResult
    func file(_ rel: String, bytes: Int, fill: UInt8 = 0x5A) -> String {
        let p = path(rel)
        dir(PathUtil.parent(rel) == "" ? "" : (rel as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: p, contents: Data(repeating: fill, count: bytes))
        return p
    }

    @discardableResult
    func symlink(_ rel: String, to target: String) -> String {
        let p = path(rel)
        try! FileManager.default.createSymbolicLink(atPath: p, withDestinationPath: target)
        return p
    }

    @discardableResult
    func hardlink(_ rel: String, to existing: String) -> String {
        let p = path(rel)
        precondition(link(existing, p) == 0, "link failed")
        return p
    }

    func exists(_ rel: String) -> Bool {
        var st = stat()
        return lstat(path(rel), &st) == 0
    }

    func scan(threshold: Int64 = 1 << 20, roots: [String]? = nil) throws -> ScanResult {
        try DiskScanner.scanSync(options: ScanOptions(roots: roots ?? [root], fileNodeThreshold: threshold))
    }
}

/// Builds a recommendation for executor tests.
func makeRec(_ path: String, tier: CleanupTier = .low, kind: CleanupActionKind = .deletePermanently,
             owners: [String] = [], bytes: Int64 = 1000) -> Recommendation {
    var st = stat()
    lstat(path, &st)
    let action: CleanupAction
    switch kind {
    case .deletePermanently: action = .delete(path)
    case .moveToTrash: action = .trash(path)
    case .manualReview: action = .review(path)
    case .runCommand: action = .command("/bin/echo", ["hi"], measuring: nil)
    }
    return Recommendation(id: "test:\(path)", ruleID: "test", title: PathUtil.lastComponent(path), targetPath: path,
                          category: .other, detectedAllocated: bytes, detectedLogical: bytes, fileCount: 1,
                          estimatedReclaimable: bytes, reclaimMethod: "test", reason: "test", confidence: .high,
                          risk: .low, tier: tier, dependencies: "", consequences: "", action: action, verification: "",
                          requiresElevation: false, inUseBy: [], ownerProcessHints: owners, analysisComplete: true,
                          notes: [], expectedDevice: st.st_dev, expectedInode: UInt64(st.st_ino), lastModified: nil)
}

/// Records operations and can be told to fail for specific paths.
final class FakeFileOps: FileOperations, @unchecked Sendable {
    var failPaths: Set<String> = []
    var removed: [String] = []
    var trashed: [String] = []
    struct Injected: Error, LocalizedError { var errorDescription: String? { "injected failure" } }

    /// Matches the original path or its staged copy ("<uuid>-<name>" in the staging folder).
    func shouldFail(_ path: String) -> Bool {
        failPaths.contains { path == $0 || PathUtil.lastComponent(path).hasSuffix("-" + PathUtil.lastComponent($0)) }
    }
    func moveToTrash(_ path: String) throws {
        if shouldFail(path) { throw Injected() }
        trashed.append(path)
        try FileManager.default.removeItem(atPath: path)   // simulate leaving original location
    }
    func removeItem(_ path: String) throws {
        if shouldFail(path) { throw Injected() }
        removed.append(path)
        try FileManager.default.removeItem(atPath: path)
    }
}

func testExecutor(_ fx: Fixture, ops: any FileOperations = SystemFileOperations(), running: [String]? = [],
                  measure: (@Sendable (String) -> Int64?)? = nil) -> CleanupExecutor {
    let procs = running.map { ProcessSnapshot(processes: $0.map { RunningProcess(executable: $0, commandLine: $0) }, complete: true) }
    var ex = CleanupExecutor(pathGuard: PathGuard(allowedRoots: [fx.root], protectedPaths: [fx.path("protected")], minimumDepth: 2),
                             fileOps: ops, allowedExecutables: ["/bin/echo", "/bin/sh"], volumePath: fx.root,
                             runningProcesses: { procs }, stagingDirectory: fx.path(".staging"))
    if let measure { ex.measure = measure }
    return ex
}
