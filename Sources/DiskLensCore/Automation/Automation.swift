import Foundation

// MARK: - Scheduled scans (Pro)

public enum ScanFrequency: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, daily, weekly
    public var id: String { rawValue }
    public var label: String {
        switch self { case .off: return "Off"; case .daily: return "Daily"; case .weekly: return "Weekly" }
    }
    var interval: TimeInterval? {
        switch self { case .off: return nil; case .daily: return 86_400; case .weekly: return 7 * 86_400 }
    }
}

/// When background scans run. Scans are read-only; a scheduled scan never cleans anything.
public struct ScanSchedule: Codable, Sendable, Equatable {
    public var frequency: ScanFrequency
    /// Preferred local hour (0–23). A scan that is due waits for this hour unless it is overdue
    /// by more than a day (e.g. the Mac was asleep), in which case it runs at the next check.
    public var preferredHour: Int

    public init(frequency: ScanFrequency = .off, preferredHour: Int = 10) {
        self.frequency = frequency
        self.preferredHour = min(23, max(0, preferredHour))
    }

    public func isDue(lastScan: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let interval = frequency.interval else { return false }
        guard let lastScan else { return true }
        let elapsed = now.timeIntervalSince(lastScan)
        if elapsed < interval - 3600 { return false }            // tolerate small drift
        if elapsed >= interval + 86_400 { return true }          // overdue: run now
        return calendar.component(.hour, from: now) >= preferredHour
    }
}

// MARK: - Low-space alerts (Pro)

/// Decides when to alert about low free space without nagging: one alert when space drops below
/// the threshold, then silence until space recovers past threshold + margin (re-arm) or the
/// repeat interval passes while still low.
public struct LowSpaceMonitor: Codable, Sendable, Equatable {
    public var thresholdBytes: Int64
    public var rearmMarginBytes: Int64
    public var repeatInterval: TimeInterval
    public private(set) var lastAlertAt: Date?
    public private(set) var armed: Bool

    public init(thresholdBytes: Int64 = 20_000_000_000, rearmMarginBytes: Int64 = 2_000_000_000,
                repeatInterval: TimeInterval = 24 * 3600) {
        self.thresholdBytes = thresholdBytes
        self.rearmMarginBytes = rearmMarginBytes
        self.repeatInterval = repeatInterval
        self.lastAlertAt = nil
        self.armed = true
    }

    /// Feeds one free-space measurement; returns true when an alert should be shown now.
    public mutating func evaluate(availableBytes: Int64, now: Date) -> Bool {
        if availableBytes >= thresholdBytes + rearmMarginBytes { armed = true; return false }
        guard availableBytes < thresholdBytes else { return false }
        if armed || lastAlertAt.map({ now.timeIntervalSince($0) >= repeatInterval }) == true {
            armed = false
            lastAlertAt = now
            return true
        }
        return false
    }
}

// MARK: - CLI cleanup policies (Team / CI)

/// A declarative cleanup policy for `disklens-cli policy`, e.g. "when free space < 20 GB, clean
/// tier-1 caches". Tier 3 can never be part of a policy. Dry run unless `--execute` is given.
public struct CleanupPolicy: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case delete, trash }

    public var name: String
    /// Trigger: run only when available space is below this many GB (decimal). nil = always.
    public var whenFreeBelowGB: Double?
    /// Allowed tiers (1 and/or 2).
    public var tiers: [Int]
    /// Optional allowlist of rule ids; an entry ending in ":" or "*" matches a rule family.
    public var rules: [String]?
    /// Skip items whose estimated reclaimable size is below this many MB.
    public var minItemMB: Double?
    public var action: Action
    /// Upper bound for the plan's total estimate in GB (optional); larger items are skipped.
    public var maxTotalGB: Double?

    public init(name: String, whenFreeBelowGB: Double? = nil, tiers: [Int] = [1], rules: [String]? = nil,
                minItemMB: Double? = nil, action: Action = .delete, maxTotalGB: Double? = nil) {
        self.name = name; self.whenFreeBelowGB = whenFreeBelowGB; self.tiers = tiers; self.rules = rules
        self.minItemMB = minItemMB; self.action = action; self.maxTotalGB = maxTotalGB
    }

    public enum PolicyError: Error, Equatable, CustomStringConvertible {
        case invalidTier(Int)
        case emptyTiers
        case invalidThreshold
        public var description: String {
            switch self {
            case .invalidTier(let t): return "Policy tier \(t) is not allowed. Policies may contain tiers 1 and 2 only; tier 3 is never executed."
            case .emptyTiers: return "Policy must list at least one tier (1 or 2)."
            case .invalidThreshold: return "whenFreeBelowGB must be a positive number."
            }
        }
    }

    public func validate() throws {
        guard !tiers.isEmpty else { throw PolicyError.emptyTiers }
        for t in tiers where t != 1 && t != 2 { throw PolicyError.invalidTier(t) }
        if let g = whenFreeBelowGB, !(g > 0) { throw PolicyError.invalidThreshold }
    }

    public static func load(from url: URL) throws -> CleanupPolicy {
        let p = try JSONDecoder().decode(CleanupPolicy.self, from: Data(contentsOf: url))
        try p.validate()
        return p
    }

    func matchesRule(_ id: String) -> Bool {
        guard let rules, !rules.isEmpty else { return true }
        return rules.contains { r in
            if r.hasSuffix("*") { return id.hasPrefix(String(r.dropLast())) }
            if r.hasSuffix(":") { return id.hasPrefix(r) }
            return id == r
        }
    }

    public struct Exclusion: Codable, Sendable, Equatable {
        public var id: String
        public var reason: String
    }

    public struct Evaluation: Sendable {
        public var triggered: Bool
        public var availableBytes: Int64?
        public var thresholdBytes: Int64?
        public var plan: CleanupPlan?
        /// Matching items left out (in use, needs elevation, incomplete analysis, over budget).
        public var excluded: [Exclusion]
    }

    /// Selects the recommendations this policy would clean. Only items eligible for automatic
    /// selection qualify (tier 1/2, not high risk, fully analysed, not in use, no elevation).
    public func evaluate(recommendations: [Recommendation], availableBytes: Int64?, scanID: UUID?) throws -> Evaluation {
        try validate()
        let threshold = whenFreeBelowGB.map { Int64($0 * 1e9) }
        if let threshold {
            guard let availableBytes else {
                return Evaluation(triggered: false, availableBytes: nil, thresholdBytes: threshold, plan: nil,
                                  excluded: [Exclusion(id: "*", reason: "Free space could not be measured; policy not triggered.")])
            }
            if availableBytes >= threshold {
                return Evaluation(triggered: false, availableBytes: availableBytes, thresholdBytes: threshold, plan: nil, excluded: [])
            }
        }
        var chosen: [Recommendation] = []
        var excluded: [Exclusion] = []
        var total: Int64 = 0
        let budget = maxTotalGB.map { Int64($0 * 1e9) }
        let minItem = Int64((minItemMB ?? 0) * 1e6)
        for r in recommendations.sorted(by: { $0.estimatedReclaimable > $1.estimatedReclaimable }) {
            guard tiers.contains(r.tier.rawValue), matchesRule(r.ruleID) else { continue }
            if !r.eligibleForAutoSelection {
                let why = !r.inUseBy.isEmpty ? "in use or unverifiable (\(r.inUseBy.joined(separator: ", ")))"
                    : r.requiresElevation ? "needs administrator rights"
                    : !r.analysisComplete ? "not fully analysed" : r.risk == .high ? "high risk" : "manual review"
                excluded.append(Exclusion(id: r.id, reason: why)); continue
            }
            if r.estimatedReclaimable < minItem { excluded.append(Exclusion(id: r.id, reason: "below minItemMB")); continue }
            if let budget, total + r.estimatedReclaimable > budget { excluded.append(Exclusion(id: r.id, reason: "would exceed maxTotalGB")); continue }
            var item = r
            if action == .trash && item.action.kind == .deletePermanently { item.action = .trash(item.targetPath) }
            chosen.append(item)
            total += item.estimatedReclaimable
        }
        let plan = chosen.isEmpty ? nil : CleanupPlan(scanID: scanID, items: chosen)
        return Evaluation(triggered: true, availableBytes: availableBytes, thresholdBytes: threshold, plan: plan, excluded: excluded)
    }
}

/// `disklens-cli` exit codes (documented in README and `--help`).
public enum CLIExitCode: Int32, Sendable {
    case ok = 0
    case error = 1
    case usage = 2
    case approvalRefused = 3
    case licenseRequired = 4
    /// Execution finished but at least one item failed.
    case partialFailure = 5
    /// A policy executed but free space is still below its threshold.
    case stillBelowThreshold = 6
}
