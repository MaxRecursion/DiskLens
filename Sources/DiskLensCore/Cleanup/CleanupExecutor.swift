import Foundation
import Darwin

public enum CleanupError: Error, Equatable, CustomStringConvertible, Sendable {
    case approvalRequired
    case approvalMismatch(expected: String, got: String)
    case emptyPlan

    public var description: String {
        switch self {
        case .approvalRequired: return "Execution requires an explicit approval bound to this plan."
        case .approvalMismatch(let e, let g): return "Approval does not match this plan (expected digest \(e.prefix(12))…, got \(g.prefix(12))…). The plan changed after approval."
        case .emptyPlan: return "The plan has no items."
        }
    }
}

/// Abstraction over destructive filesystem operations so tests can inject failures.
public protocol FileOperations: Sendable {
    func moveToTrash(_ path: String) throws
    func removeItem(_ path: String) throws
}

public struct SystemFileOperations: FileOperations {
    public init() {}
    public func moveToTrash(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }
    /// FileManager.removeItem uses removefile(3), which unlinks symbolic links rather than
    /// following them, so a link inside the target can never redirect deletion elsewhere.
    public func removeItem(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}

public struct CleanupExecutor: Sendable {
    public var pathGuard: PathGuard
    public var fileOps: any FileOperations
    /// Absolute paths of tools DiskLens may invoke for documented cleanup commands.
    public var allowedExecutables: Set<String>
    public var volumePath: String
    /// nil = the process list could not be obtained (items with owners are then skipped).
    public var runningProcesses: @Sendable () -> ProcessSnapshot?
    public var measure: @Sendable (String) -> Int64?
    public var commandTimeout: TimeInterval
    /// DiskLens-owned folder (same volume as the targets) where items are atomically moved
    /// before deletion, so a path swapped after validation can never redirect a delete.
    public var stagingDirectory: String
    /// Test hook invoked right before the destructive step (used to simulate races).
    var beforeDestructiveStep: (@Sendable (String) -> Void)?

    public init(pathGuard: PathGuard = .standard(), fileOps: any FileOperations = SystemFileOperations(),
                allowedExecutables: Set<String> = CleanupExecutor.defaultAllowedExecutables,
                volumePath: String = Platform.realHome,
                runningProcesses: @escaping @Sendable () -> ProcessSnapshot? = { ProcessProbe.snapshot() },
                measure: @escaping @Sendable (String) -> Int64? = { ReclaimEstimator.allocatedSize(of: $0) },
                commandTimeout: TimeInterval = 900,
                stagingDirectory: String = ScanStore().directory.appendingPathComponent("staging").path) {
        self.pathGuard = pathGuard
        self.fileOps = fileOps
        self.allowedExecutables = allowedExecutables
        self.volumePath = volumePath
        self.runningProcesses = runningProcesses
        self.measure = measure
        self.commandTimeout = commandTimeout
        self.stagingDirectory = stagingDirectory
    }

    public static let defaultAllowedExecutables: Set<String> = [
        "/opt/homebrew/bin/brew", "/opt/homebrew/bin/npm", "/opt/homebrew/opt/node@22/bin/npm",
        "/opt/homebrew/opt/node@22/bin/pnpm", "/opt/homebrew/bin/pnpm", "/usr/bin/xcrun",
    ]

    /// Executes (or dry-runs) a plan. Dry runs perform every validation but never mutate.
    /// Real runs require an approval whose digest matches the plan exactly.
    public func execute(plan: CleanupPlan, approval: CleanupApproval?, dryRun: Bool,
                        progress: ((Int, Int, String) -> Void)? = nil) throws -> CleanupReport {
        guard !plan.items.isEmpty else { throw CleanupError.emptyPlan }
        if !dryRun {
            guard let approval else { throw CleanupError.approvalRequired }
            let digest = plan.digest
            guard approval.planID == plan.id, approval.planDigest == digest else {
                throw CleanupError.approvalMismatch(expected: digest, got: approval.planDigest)
            }
        }
        let startedAt = Date()
        let before = VolumeInfo.snapshot(for: volumePath)
        let running = runningProcesses()
        try? FileManager.default.createDirectory(atPath: stagingDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory)) ?? []).filter { !$0.hasPrefix(".") }
        var results: [CleanupItemResult] = []
        for (i, item) in plan.items.enumerated() {
            progress?(i, plan.items.count, item.title)
            let r = process(item, dryRun: dryRun, running: running)
            Log.cleanup.info("\(dryRun ? "dry-run" : "execute", privacy: .public) \(r.status.rawValue, privacy: .public): \(item.targetPath, privacy: .private)")
            results.append(r)
        }
        let after = VolumeInfo.snapshot(for: volumePath)
        var report = CleanupReport(planID: plan.id, planDigest: plan.digest, dryRun: dryRun, startedAt: startedAt,
                                   finishedAt: Date(), volumeBefore: before, volumeAfter: after, results: results,
                                   unexpected: [], followUp: [])
        analyse(&report, plan: plan)
        if !leftovers.isEmpty {
            report.unexpected.append("\(leftovers.count) item(s) from an interrupted earlier cleanup remain in \(stagingDirectory). DiskLens never removes them automatically — review them yourself.")
        }
        return report
    }

    func result(_ item: Recommendation, _ status: CleanupItemStatus, _ message: String, start: Date,
                before: Int64? = nil, after: Int64? = nil, output: String? = nil) -> CleanupItemResult {
        CleanupItemResult(id: item.id, title: item.title, action: item.action.displayString, status: status,
                          message: message, bytesBefore: before, bytesAfter: after,
                          estimatedReclaimable: item.estimatedReclaimable, commandOutput: output,
                          durationSeconds: Date().timeIntervalSince(start))
    }

    func process(_ item: Recommendation, dryRun: Bool, running: ProcessSnapshot?) -> CleanupItemResult {
        let start = Date()
        if item.requiresManualReview {
            return result(item, .skipped, "Manual review only — DiskLens never removes tier-3 items automatically.", start: start)
        }
        if item.requiresElevation {
            return result(item, .skipped, "Requires administrator privileges — not performed. Run it yourself if you agree.", start: start)
        }
        guard let running else {
            if !item.ownerProcessHints.isEmpty {
                return result(item, .skipped, "Could not determine which apps are running — skipped for safety.", start: start)
            }
            return process(item, dryRun: dryRun, running: ProcessSnapshot(processes: [], complete: true))
        }
        let users = ProcessProbe.matches(hints: item.ownerProcessHints, running: running.processes)
        if !users.isEmpty {
            return result(item, .skipped, "In use by running process(es): \(users.joined(separator: ", ")). Quit them and retry.", start: start)
        }

        switch item.action.kind {
        case .manualReview:
            return result(item, .skipped, "Manual review only.", start: start)

        case .moveToTrash, .deletePermanently:
            guard let target = item.action.targetPath, target == item.targetPath else {
                return result(item, .failed, "Action target does not match the recommendation target — refusing.", start: start)
            }
            // Measure first: the (possibly long) size walk must not sit between validation and removal.
            let bytesBefore = measure(target)
            let validated: PathGuard.Validated
            switch pathGuard.validate(target) {
            case .failure(let e):
                if case .doesNotExist = e {
                    return result(item, .skipped, "Target no longer exists (already removed or moved since the scan).", start: start)
                }
                return result(item, .skipped, "Safety check failed: \(e.description)", start: start)
            case .success(let v):
                validated = v
            }
            if item.expectedInode != 0 && (validated.inode != item.expectedInode || validated.device != item.expectedDevice) {
                return result(item, .skipped, "Target was replaced since the scan (different inode). Rescan before cleaning.", start: start)
            }
            if dryRun {
                return result(item, .wouldExecute, "Dry run — would \(item.action.displayString)", start: start, before: bytesBefore)
            }
            beforeDestructiveStep?(target)
            let parent = PathUtil.parent(target), name = PathUtil.lastComponent(target)
            guard let parentFD = SafeRemoval.openVerifiedDirectory(parent) else {
                return result(item, .skipped, SafeRemoval.Failure.parentChanged(parent).description + " Nothing was removed.", start: start, before: bytesBefore)
            }
            defer { close(parentFD) }

            if item.action.kind == .moveToTrash {
                // Trash is reversible; re-verify identity through the verified parent right before moving.
                guard let id = SafeRemoval.identity(dirfd: parentFD, name: name), !id.isLink,
                      id.dev == validated.device, id.ino == validated.inode else {
                    return result(item, .skipped, SafeRemoval.Failure.targetChanged.description + " Nothing was moved.", start: start, before: bytesBefore)
                }
                do { try fileOps.moveToTrash(target) } catch {
                    return result(item, .failed, "Failed to move to Trash: \(error.localizedDescription). Nothing was moved.", start: start, before: bytesBefore)
                }
                if SafeRemoval.exists(dirfd: parentFD, name: name) {
                    return result(item, .failed, "Move to Trash reported success but the item is still in place.", start: start, before: bytesBefore)
                }
                return result(item, .succeeded, "Moved to Trash. Space is freed only after the Trash is emptied.", start: start, before: bytesBefore, after: 0)
            }

            // Permanent delete: atomically stage, then remove the staged item.
            guard let stagingFD = SafeRemoval.openVerifiedDirectory(stagingDirectory) else {
                return result(item, .skipped, SafeRemoval.Failure.stagingUnavailable("cannot open \(stagingDirectory)").description, start: start, before: bytesBefore)
            }
            defer { close(stagingFD) }
            let staged: String
            do {
                staged = try SafeRemoval.stage(parentFD: parentFD, name: name, expectedDev: validated.device,
                                               expectedIno: validated.inode, stagingFD: stagingFD)
            } catch {
                return result(item, .skipped, "\(error) Nothing was removed.", start: start, before: bytesBefore)
            }
            let stagedPath = stagingDirectory + "/" + staged
            do {
                try fileOps.removeItem(stagedPath)
            } catch {
                // Put whatever is left back where it was, so a failure never leaves data displaced.
                let remaining = SafeRemoval.exists(dirfd: stagingFD, name: staged) ? measure(stagedPath) : 0
                let restored = SafeRemoval.exists(dirfd: stagingFD, name: staged)
                    ? SafeRemoval.unstage(stagingFD: stagingFD, stagedName: staged, parentFD: parentFD, name: name) : false
                let where_ = restored ? "The remainder was restored to its original location." : (SafeRemoval.exists(dirfd: stagingFD, name: staged) ? "The remainder is in \(stagedPath)." : "")
                if let remaining, let bytesBefore, remaining > 0, remaining < bytesBefore {
                    return result(item, .partiallySucceeded, "Partially removed: \(ByteFormat.string(bytesBefore - remaining)) freed, \(ByteFormat.string(remaining)) remain. Error: \(error.localizedDescription). \(where_)", start: start, before: bytesBefore, after: remaining)
                }
                if remaining == 0 {
                    return result(item, .succeeded, "Removed (with a non-fatal error: \(error.localizedDescription)).", start: start, before: bytesBefore, after: 0)
                }
                return result(item, .failed, "Failed: \(error.localizedDescription). Nothing was removed. \(where_)", start: start, before: bytesBefore, after: remaining)
            }
            // Verify through the same descriptors: gone from the original place and from staging.
            if SafeRemoval.exists(dirfd: parentFD, name: name) && SafeRemoval.identity(dirfd: parentFD, name: name)?.ino == validated.inode {
                return result(item, .failed, "Verification failed: the original item is still present.", start: start, before: bytesBefore)
            }
            if SafeRemoval.exists(dirfd: stagingFD, name: staged) {
                let remaining = measure(stagedPath)
                return result(item, .partiallySucceeded, "Operation returned but \(ByteFormat.string(remaining ?? 0)) remain in \(stagedPath).", start: start, before: bytesBefore, after: remaining)
            }
            return result(item, .succeeded, "Deleted and verified absent.", start: start, before: bytesBefore, after: 0)

        case .runCommand:
            guard let exe = item.action.executable, allowedExecutables.contains(exe),
                  FileManager.default.isExecutableFile(atPath: exe) else {
                return result(item, .skipped, "Command executable is not in DiskLens's allowlist or not installed — refusing.", start: start)
            }
            let measured = item.action.measuredPath
            let bytesBefore = measured.flatMap { measure($0) }
            if dryRun {
                return result(item, .wouldExecute, "Dry run — would \(item.action.displayString)", start: start, before: bytesBefore)
            }
            do {
                let o = try ProcessRunner.run(exe, item.action.arguments, timeout: commandTimeout)
                let after = measured.flatMap { measure($0) }
                let out = String((o.stdout + (o.stderr.isEmpty ? "" : "\n[stderr]\n" + o.stderr)).suffix(4000))
                if o.timedOut { return result(item, .failed, "Command timed out and was terminated.", start: start, before: bytesBefore, after: after, output: out) }
                if o.status != 0 { return result(item, .failed, "Command exited with status \(o.status).", start: start, before: bytesBefore, after: after, output: out) }
                let freed = (bytesBefore ?? 0) - (after ?? 0)
                return result(item, .succeeded, "Command succeeded. Measured change in target: \(ByteFormat.string(freed)).", start: start, before: bytesBefore, after: after, output: out)
            } catch {
                return result(item, .failed, "Could not launch command: \(error.localizedDescription)", start: start, before: bytesBefore)
            }
        }
    }

    func analyse(_ report: inout CleanupReport, plan: CleanupPlan) {
        if report.dryRun {
            report.followUp.append("This was a dry run: nothing was modified. Approve the plan to execute it.")
            return
        }
        let trashed = report.results.filter { $0.status == .succeeded && $0.action.hasPrefix("Move to Trash") }
        if !trashed.isEmpty {
            report.unexpected.append("\(trashed.count) item(s) were moved to the Trash. That is reversible, but their space (\(ByteFormat.string(trashed.reduce(0) { $0 + $1.estimatedReclaimable }))) is only released when you empty the Trash.")
        }
        let permanent = report.results.filter { ($0.status == .succeeded || $0.status == .partiallySucceeded) && !$0.action.hasPrefix("Move to Trash") }
        let expected = permanent.reduce(Int64(0)) { $0 + $1.estimatedReclaimable }
        if let delta = report.measuredFreeSpaceDelta, expected > 100 << 20 {
            if Double(delta) < Double(expected) * 0.5 {
                report.unexpected.append("Measured free space grew by \(ByteFormat.string(delta)), less than half of the \(ByteFormat.string(expected)) estimate. Likely causes: blocks shared with APFS clones, a local snapshot still referencing the data, or other processes writing concurrently.")
            } else if Double(delta) > Double(expected) * 1.5 {
                report.unexpected.append("Measured free space grew by \(ByteFormat.string(delta)), more than the \(ByteFormat.string(expected)) estimate — macOS or other apps likely freed space concurrently.")
            }
        }
        if !report.failed.isEmpty { report.followUp.append("Review the \(report.failed.count) failed item(s); nothing was rolled back because failed deletions leave the target intact.") }
        if !report.skipped.isEmpty { report.followUp.append("\(report.skipped.count) item(s) were skipped for safety (see messages).") }
        report.followUp.append("Run a fresh scan to refresh the treemap and recommendations.")
    }
}
