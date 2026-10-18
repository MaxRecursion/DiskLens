import Foundation
import AppKit

/// Runs an executable with an argument vector (never via a shell, so no injection is possible).
public enum ProcessRunner {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
    }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30,
                           environment: [String: String]? = nil, currentDirectory: String? = nil) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        if let currentDirectory { p.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }

        // Capture output via private temp files rather than pipes: with concurrent launches a
        // sibling child can inherit a pipe's write end and EOF never arrives (observed deadlock).
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("disklens-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("disklens-\(UUID().uuidString).err")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        p.standardOutput = outHandle
        p.standardError = errHandle
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch {
            try? outHandle.close(); try? errHandle.close()
            throw error
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning {
            if Date() > deadline { timedOut = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if timedOut {
            // SIGTERM, a short grace period, then SIGKILL; never wait unboundedly.
            p.terminate()
            let grace = Date().addingTimeInterval(5)
            while p.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            let hard = Date().addingTimeInterval(5)
            while p.isRunning && Date() < hard { Thread.sleep(forTimeInterval: 0.05) }
        } else {
            p.waitUntilExit()
        }
        try? outHandle.close()
        try? errHandle.close()
        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        return Output(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self),
                      timedOut: timedOut)
    }
}

/// A running process. `commandLine` is used only for in-memory matching against path hints
/// (e.g. a node process started from ~/.npm/_npx) and is never logged, stored or displayed,
/// because command lines can contain secrets.
public struct RunningProcess: Sendable, Hashable {
    public var executable: String
    public var commandLine: String
    public init(executable: String, commandLine: String) {
        self.executable = executable
        self.commandLine = commandLine
    }
    public var displayName: String { PathUtil.lastComponent(executable) }
}

/// What could be observed about running processes.
public struct ProcessSnapshot: Sendable {
    public var processes: [RunningProcess]
    /// False when only GUI apps are visible (App Sandbox): command-line tools cannot be seen.
    public var complete: Bool
    public init(processes: [RunningProcess], complete: Bool) {
        self.processes = processes
        self.complete = complete
    }
}

public enum ProcessProbe {
    /// Running processes as seen from this edition: the full `ps` list outside the sandbox, GUI
    /// apps via NSWorkspace inside it. nil if nothing could be determined.
    public static func snapshot() -> ProcessSnapshot? {
        if Platform.isSandboxed {
            let apps = NSWorkspace.shared.runningApplications.compactMap { app -> RunningProcess? in
                guard let exe = app.executableURL?.path ?? app.bundleURL?.path else { return nil }
                return RunningProcess(executable: exe, commandLine: app.bundleURL?.path ?? exe)
            }
            return ProcessSnapshot(processes: apps, complete: false)
        }
        return running().map { ProcessSnapshot(processes: $0, complete: true) }
    }

    /// Hints that refer to an app bundle can be checked even from the sandbox.
    public static func isAppHint(_ hint: String) -> Bool { hint.lowercased().contains(".app") }

    public static let unverifiedMarker = "(unverified: this edition cannot see every running app or tool)"
    public static let unavailableMarker = "(unknown: process list unavailable)"

    /// All running processes (via `ps`; metadata only), or nil if the list could not be obtained —
    /// callers must then treat "in use" as unknown, never as "not in use".
    public static func running() -> [RunningProcess]? {
        func table(_ field: String) -> [Int: String]? {
            guard let o = try? ProcessRunner.run("/bin/ps", ["-axww", "-o", "pid=", "-o", "\(field)="], timeout: 15),
                  o.status == 0, !o.timedOut else { return nil }
            var map: [Int: String] = [:]
            for line in o.stdout.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let sp = t.firstIndex(of: " "), let pid = Int(t[..<sp]) else { continue }
                map[pid] = String(t[sp...]).trimmingCharacters(in: .whitespaces)
            }
            return map
        }
        guard let comm = table("comm"), !comm.isEmpty, let args = table("args") else { return nil }
        return comm.map { RunningProcess(executable: $0.value, commandLine: args[$0.key] ?? $0.value) }
    }

    /// Display names of running processes whose executable path or command line contains any
    /// hint (e.g. "/Cursor.app/" or "/.npm/_npx/").
    public static func matches(hints: [String], running: [RunningProcess]) -> [String] {
        guard !hints.isEmpty else { return [] }
        // Case-insensitive: APFS is case-insensitive and app/folder names differ in case
        // (e.g. "~/Library/Application Support/obsidian" vs "/Applications/Obsidian.app").
        let folded = hints.map { $0.lowercased() }
        var hits = Set<String>()
        for r in running {
            let exe = r.executable.lowercased(), cmd = r.commandLine.lowercased()
            if folded.contains(where: { exe.contains($0) || cmd.contains($0) }) { hits.insert(r.displayName) }
        }
        return hits.sorted()
    }
}
