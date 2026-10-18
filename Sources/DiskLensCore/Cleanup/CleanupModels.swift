import Foundation
import CryptoKit

public enum CleanupTier: Int, Codable, Sendable, CaseIterable, Comparable {
    /// Low risk: disposable temp files, verified build outputs, auto-recreated tool caches.
    case low = 1
    /// Conditional: package caches, browser/app caches, unused dev components, project build dirs.
    case conditional = 2
    /// Manual review only: personal files, archives, models, databases, VM disks. Never executed.
    case manualReview = 3

    public static func < (a: CleanupTier, b: CleanupTier) -> Bool { a.rawValue < b.rawValue }
    public var label: String {
        switch self {
        case .low: return "Tier 1 · Low risk"
        case .conditional: return "Tier 2 · Conditional"
        case .manualReview: return "Tier 3 · Manual review"
        }
    }
}

public enum RiskLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case low, medium, high
    var order: Int { self == .low ? 0 : self == .medium ? 1 : 2 }
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.order < b.order }
}

public enum Confidence: String, Codable, Sendable, CaseIterable {
    case high, medium, low
}

public enum CleanupActionKind: String, Codable, Sendable {
    /// Move to the user's Trash (reversible; space is freed only when the Trash is emptied).
    case moveToTrash
    /// Delete permanently (frees space immediately; not reversible).
    case deletePermanently
    /// Run a documented tool command with an argument vector (never through a shell).
    case runCommand
    /// No automated action: the user reviews the item themselves (Reveal in Finder).
    case manualReview
}

public struct CleanupAction: Codable, Sendable, Hashable {
    public var kind: CleanupActionKind
    public var targetPath: String?
    public var executable: String?
    public var arguments: [String]
    /// Directory re-measured to verify a command's effect.
    public var measuredPath: String?

    public init(kind: CleanupActionKind, targetPath: String? = nil, executable: String? = nil,
                arguments: [String] = [], measuredPath: String? = nil) {
        self.kind = kind
        self.targetPath = targetPath
        self.executable = executable
        self.arguments = arguments
        self.measuredPath = measuredPath
    }

    public static func trash(_ p: String) -> CleanupAction { .init(kind: .moveToTrash, targetPath: p) }
    public static func delete(_ p: String) -> CleanupAction { .init(kind: .deletePermanently, targetPath: p) }
    public static func review(_ p: String) -> CleanupAction { .init(kind: .manualReview, targetPath: p) }
    public static func command(_ exe: String, _ args: [String], measuring: String?) -> CleanupAction {
        .init(kind: .runCommand, executable: exe, arguments: args, measuredPath: measuring)
    }

    /// Exact human-readable description of what will happen (shown in the preview).
    public var displayString: String {
        switch kind {
        case .moveToTrash: return "Move to Trash: \(targetPath ?? "?")"
        case .deletePermanently: return "Delete permanently: \(targetPath ?? "?")"
        case .manualReview: return "No automatic action — review manually: \(targetPath ?? "?")"
        case .runCommand:
            let quoted = arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
            return "Run: \(executable ?? "?") \(quoted)"
        }
    }
}

public struct Recommendation: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var ruleID: String
    public var title: String
    public var targetPath: String
    public var category: StorageCategory
    public var detectedAllocated: Int64
    public var detectedLogical: Int64
    public var fileCount: Int64
    /// Estimated bytes freed. Always <= detectedAllocated. See `reclaimMethod`.
    public var estimatedReclaimable: Int64
    public var reclaimMethod: String
    public var reason: String
    public var confidence: Confidence
    public var risk: RiskLevel
    public var tier: CleanupTier
    public var dependencies: String
    public var consequences: String
    public var action: CleanupAction
    public var verification: String
    public var requiresElevation: Bool
    /// Running processes that use this target (cleanup is skipped while they run).
    public var inUseBy: [String]
    public var ownerProcessHints: [String]
    public var analysisComplete: Bool
    public var notes: [String]
    public var expectedDevice: Int32
    public var expectedInode: UInt64
    public var lastModified: Date?
    /// A command the user can run themselves (manual-review items); never executed by DiskLens.
    public var suggestedCommand: String? = nil

    /// Eligible to be pre-selected: tier 1/2, low/medium risk, fully analysed, not in use.
    /// Pre-selection never executes anything — the preview + explicit approval still apply.
    public var eligibleForAutoSelection: Bool {
        tier != .manualReview && risk != .high && analysisComplete && inUseBy.isEmpty
            && action.kind != .manualReview && !requiresElevation
    }

    public var requiresManualReview: Bool { tier == .manualReview || action.kind == .manualReview }
}

public struct CleanupPlan: Codable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var scanID: UUID?
    public var items: [Recommendation]

    public init(id: UUID = UUID(), createdAt: Date = Date(), scanID: UUID?, items: [Recommendation]) {
        self.id = id
        self.createdAt = createdAt
        self.scanID = scanID
        self.items = items
    }

    public var totalSelectedBytes: Int64 { items.reduce(0) { $0 + $1.detectedAllocated } }
    public var totalEstimatedReclaimable: Int64 { items.reduce(0) { $0 + $1.estimatedReclaimable } }

    /// SHA-256 over the exact actions, targets and identity of every item. Approval is bound to
    /// this digest, so editing the plan after approval invalidates the approval.
    /// Every field the executor acts on, canonically encoded.
    struct DigestItem: Encodable {
        var id: String
        var targetPath: String
        var action: CleanupAction
        var ownerProcessHints: [String]
        var requiresElevation: Bool
        var tier: Int
        var expectedDevice: Int32
        var expectedInode: UInt64
    }

    public var digest: String {
        let items = self.items.sorted { $0.id < $1.id }.map {
            DigestItem(id: $0.id, targetPath: $0.targetPath, action: $0.action, ownerProcessHints: $0.ownerProcessHints,
                       requiresElevation: $0.requiresElevation, tier: $0.tier.rawValue,
                       expectedDevice: $0.expectedDevice, expectedInode: $0.expectedInode)
        }
        struct Payload: Encodable { var planID: String; var items: [DigestItem] }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(Payload(planID: id.uuidString, items: items))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Items that would require administrator privileges.
    public var elevatedItems: [Recommendation] { items.filter(\.requiresElevation) }
    public var incompletelyAnalyzed: [Recommendation] { items.filter { !$0.analysisComplete } }
}

/// Explicit user approval bound to one exact plan.
public struct CleanupApproval: Codable, Sendable, Hashable {
    public var planID: UUID
    public var planDigest: String
    public var approvedAt: Date
    public var approver: String

    public init(plan: CleanupPlan, approver: String, approvedAt: Date = Date()) {
        self.planID = plan.id
        self.planDigest = plan.digest
        self.approvedAt = approvedAt
        self.approver = approver
    }
}

public enum CleanupItemStatus: String, Codable, Sendable {
    case succeeded, partiallySucceeded, skipped, failed, wouldExecute
}

public struct CleanupItemResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var action: String
    public var status: CleanupItemStatus
    public var message: String
    public var bytesBefore: Int64?
    public var bytesAfter: Int64?
    public var estimatedReclaimable: Int64
    public var commandOutput: String?
    public var durationSeconds: Double
}

public struct CleanupReport: Codable, Sendable {
    public var planID: UUID
    public var planDigest: String
    public var dryRun: Bool
    public var startedAt: Date
    public var finishedAt: Date
    public var volumeBefore: VolumeSnapshot?
    public var volumeAfter: VolumeSnapshot?
    public var results: [CleanupItemResult]
    public var unexpected: [String]
    public var followUp: [String]

    /// Measured change in free space (statfs). Positive = space recovered.
    public var measuredFreeSpaceDelta: Int64? {
        guard let b = volumeBefore, let a = volumeAfter else { return nil }
        return a.availableBytes - b.availableBytes
    }
    public var estimatedTotal: Int64 { results.filter { $0.status == .succeeded || $0.status == .partiallySucceeded || $0.status == .wouldExecute }.reduce(0) { $0 + $1.estimatedReclaimable } }
    public var succeeded: [CleanupItemResult] { results.filter { $0.status == .succeeded || $0.status == .partiallySucceeded } }
    public var skipped: [CleanupItemResult] { results.filter { $0.status == .skipped } }
    public var failed: [CleanupItemResult] { results.filter { $0.status == .failed } }
}

public extension Recommendation {
    /// A one-item "Move to Trash" request for something the user picked by hand (free feature).
    /// Validated by `PathGuard.manualTrash` and executed by the same executor as every cleanup,
    /// including the same-inode check against the scan.
    static func manualTrash(path: String, node: ScanNode) -> Recommendation {
        Recommendation(
            id: "manual-trash:\(path)", ruleID: "manual-trash", title: node.name, targetPath: path, category: node.category,
            detectedAllocated: node.allocated, detectedLogical: node.logical, fileCount: node.fileCount,
            estimatedReclaimable: node.allocated, reclaimMethod: "allocated size (measured at scan time)",
            reason: "Selected by you.", confidence: .high, risk: .medium, tier: .conditional, dependencies: "None.",
            consequences: "Moved to the Trash; you can put it back from the Trash.", action: .trash(path),
            verification: "Confirm the item is no longer at its original location; space is released when the Trash is emptied.",
            requiresElevation: false, inUseBy: [], ownerProcessHints: [], analysisComplete: !node.flags.contains(.partial),
            notes: [], expectedDevice: node.device, expectedInode: node.inode,
            lastModified: node.mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(node.mtime)) : nil)
    }
}
