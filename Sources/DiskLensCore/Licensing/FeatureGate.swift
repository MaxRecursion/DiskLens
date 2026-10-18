import Foundation

/// Distribution channel of the running binary. One codebase serves both; the edition is detected
/// at runtime from the App Sandbox (the Mac App Store build is the only sandboxed one).
public enum Edition: String, Codable, Sendable, CaseIterable {
    /// Mac App Store: sandboxed, Pro is a StoreKit 2 non-consumable.
    case appStore
    /// Developer ID download: notarized, Pro via offline-verified license keys, 7-day trial, CLI.
    case direct

    public static var current: Edition { Platform.isSandboxed ? .appStore : .direct }
}

/// Pro capabilities. Everything that is NOT listed here is free in both editions and is never
/// gated: scanning, the treemap, categories, search, the scan manifest and coverage gaps, change
/// detection, the full recommendation list with estimates and evidence, cleanup previews, dry runs,
/// every safety check, and moving a single item to the Trash by hand.
public enum Feature: String, Codable, Sendable, CaseIterable {
    /// One-click execution of approved tier-1/tier-2 cleanup plans (delete or move to Trash).
    case cleanupExecution
    /// Byte-identical duplicate finder results (SHA-256, clone- and hard-link-aware).
    case duplicates
    /// One-click cleanup of the developer rule pack (node_modules, build output, tool caches …).
    case developerRules
    /// Scheduled background scans, the menu-bar extra and low-space alerts.
    case scheduling
    /// Markdown/JSON report export and scan history.
    case reportExport
    /// Headless `disklens-cli` execution and policies (direct edition only).
    case cli

    public var displayName: String {
        switch self {
        case .cleanupExecution: return "One-click cleanup"
        case .duplicates: return "Duplicate finder"
        case .developerRules: return "Developer rule pack"
        case .scheduling: return "Scheduled scans & menu bar"
        case .reportExport: return "Reports & scan history"
        case .cli: return "Command-line tool & policies"
        }
    }

    public var summary: String {
        switch self {
        case .cleanupExecution: return "Run an approved plan in one step, with a verification report and measured free-space change."
        case .duplicates: return "Find byte-identical copies (SHA-256). APFS clones and hard links are recognised, so nothing is over-counted."
        case .developerRules: return "Clean node_modules, build output, Xcode DerivedData, Playwright browsers, package-manager caches, stale updates and superseded CLI versions in one plan."
        case .scheduling: return "Background scans on a schedule, a free-space monitor in the menu bar and alerts when space runs low."
        case .reportExport: return "Export Markdown or JSON reports and keep a history of past scans."
        case .cli: return "disklens-cli with policies, JSON output and exit codes for scripts and CI (direct edition)."
        }
    }

    public var symbol: String {
        switch self {
        case .cleanupExecution: return "bolt.fill"
        case .duplicates: return "doc.on.doc.fill"
        case .developerRules: return "hammer.fill"
        case .scheduling: return "clock.badge.checkmark"
        case .reportExport: return "square.and.arrow.up"
        case .cli: return "terminal.fill"
        }
    }
}

/// License tiers that a signed license key can carry.
public enum LicenseEdition: String, Codable, Sendable, CaseIterable {
    /// One-time Pro license (direct edition), no expiry.
    case pro
    /// Yearly per-machine Team/CI license (direct edition), always has an expiry date.
    case team
}

/// Where a Pro entitlement came from.
public enum ProSource: Codable, Sendable, Hashable {
    case appStore(productID: String)
    case licenseKey(edition: LicenseEdition, expires: Date?)

    public var label: String {
        switch self {
        case .appStore: return "App Store purchase"
        case .licenseKey(.pro, _): return "Pro license key"
        case .licenseKey(.team, _): return "Team license key"
        }
    }
}

public enum LicenseState: Codable, Sendable, Hashable {
    case free
    case trial(expires: Date)
    case pro(source: ProSource)

    public var isPaid: Bool { if case .pro = self { return true }; return false }

    public var label: String {
        switch self {
        case .free: return "Free"
        case .trial: return "Pro trial"
        case .pro(.licenseKey(.team, _)): return "Team"
        case .pro: return "Pro"
        }
    }
}

/// Which rule set a recommendation came from. The developer pack is visible to everyone (its
/// findings, estimates and evidence are part of the free recommendation list); executing it as a
/// one-click plan is Pro.
public enum RulePack: String, Codable, Sendable {
    case core
    case developer

    /// Rule ids (or `prefix:` families) that make up the developer rule pack.
    static let developerRuleIDs: Set<String> = [
        "npm-cache", "npx-package", "npm-logs", "pnpm-metadata", "node-gyp", "typescript-cache", "yarn-cache",
        "pip-cache", "pip-cache-xdg", "python-bytecode-cache", "swiftpm-cache", "xcode-deriveddata", "homebrew-cleanup",
        "clang-module-cache", "playwright-browser", "sparkle-update", "squirrel-shipit", "old-tool-version",
        "node-modules", "js-framework-cache", "js-build-output", "dotnet-build-output", "python-venv",
        "python-tool-cache", "project-tool-cache", "vendored-toolchain", "chromium-profile-cache",
        "codex-runtimes", "tool-logs", "codex-tmp",
    ]
    static let developerRulePrefixes = ["app-cache:"]

    public static func of(ruleID: String) -> RulePack {
        if developerRuleIDs.contains(ruleID) || developerRulePrefixes.contains(where: { ruleID.hasPrefix($0) }) { return .developer }
        return .core
    }
}

public extension Recommendation {
    var pack: RulePack { RulePack.of(ruleID: ruleID) }
}

/// The free tier's single taste of one-click cleanup: one run, capped by estimated reclaimable size.
public struct FreeCleanupAllowance: Codable, Sendable, Equatable {
    public static let runsIncluded = 1
    /// 2 GB (decimal, as Finder shows it) of estimated reclaimable space.
    public static let capBytes: Int64 = 2_000_000_000

    public var runsUsed: Int
    public init(runsUsed: Int = 0) { self.runsUsed = runsUsed }
    public var remaining: Int { max(0, Self.runsIncluded - runsUsed) }
}

/// Decides what the current license allows. Pure value type: no StoreKit, no Keychain, no clock
/// of its own — everything is injected, so every combination is unit-tested.
public struct FeatureGate: Sendable, Equatable {
    public var state: LicenseState
    public var edition: Edition
    public var now: Date
    public var freeAllowance: FreeCleanupAllowance

    public init(state: LicenseState, edition: Edition = .current, now: Date = Date(),
                freeAllowance: FreeCleanupAllowance = FreeCleanupAllowance()) {
        self.state = state
        self.edition = edition
        self.now = now
        self.freeAllowance = freeAllowance
    }

    public static let free = FeatureGate(state: .free)

    public func isEnabled(_ feature: Feature) -> Bool {
        switch state {
        case .free:
            return false
        case .trial(let expires):
            guard now < expires else { return false }
            return feature != .cli || edition == .direct
        case .pro(let source):
            switch source {
            case .appStore:
                // The CLI ships only with the direct edition.
                return feature != .cli
            case .licenseKey(_, let expires):
                if let expires, now >= expires { return false }
                return feature != .cli || edition == .direct
            }
        }
    }

    /// Safety and visibility are never paywalled. This is a constant on purpose (and tested):
    /// the UI and CLI call it instead of `isEnabled` for these actions so they can never be gated.
    public func allowsDryRun() -> Bool { true }
    public func allowsPreview() -> Bool { true }
    public func allowsSingleItemTrash() -> Bool { true }

    public enum ExecutionDecision: Equatable, Sendable {
        /// Pro/trial: run it.
        case allowed
        /// Free tier: this plan qualifies for the one included cleanup run.
        case allowedAsFreeRun(capBytes: Int64)
        /// Free tier, run already used (or never available): Pro is required.
        case requiresPro(Feature)
        /// Free tier, run available, but the plan's estimate is larger than the cap.
        case exceedsFreeRunCap(planBytes: Int64, capBytes: Int64)
        /// Nothing executable (tier-3/manual items only, or empty).
        case nothingExecutable
    }

    /// Whether `plan` may be executed in one click. Tier-3/manual items are never executable for
    /// anyone; the executor skips them regardless of what this returns.
    public func executionDecision(for plan: CleanupPlan) -> ExecutionDecision {
        let executable = plan.items.filter { !$0.requiresManualReview }
        guard !executable.isEmpty else { return .nothingExecutable }
        let needsDeveloperPack = executable.contains { $0.pack == .developer }
        if isEnabled(.cleanupExecution) && (!needsDeveloperPack || isEnabled(.developerRules)) { return .allowed }
        if isEnabled(.cleanupExecution) { return .requiresPro(.developerRules) }
        guard freeAllowance.remaining > 0 else { return .requiresPro(needsDeveloperPack ? .developerRules : .cleanupExecution) }
        let bytes = executable.reduce(Int64(0)) { $0 + $1.estimatedReclaimable }
        guard bytes <= FreeCleanupAllowance.capBytes else {
            return .exceedsFreeRunCap(planBytes: bytes, capBytes: FreeCleanupAllowance.capBytes)
        }
        return .allowedAsFreeRun(capBytes: FreeCleanupAllowance.capBytes)
    }
}
