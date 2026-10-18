import Foundation

/// Paywall copy built only from measured numbers of the current scan. If there is no scan (or it
/// found nothing reclaimable) the copy says so plainly instead of inventing a figure.
public struct PaywallContext: Sendable, Equatable {
    public enum Trigger: String, Sendable, Equatable {
        case cleanup, duplicates, developerRules, scheduling, reportExport, settings
    }

    public var trigger: Trigger
    /// Estimated reclaimable bytes of tier-1 (low-risk) items DiskLens would pre-select, from the
    /// current scan (clone-aware). nil when there is no scan.
    public var reclaimableEstimate: Int64?
    /// Number of tier-1 items behind that estimate.
    public var itemCount: Int
    /// Tier-2 (conditional) items not in use: reclaimable after a quick check.
    public var conditionalEstimate: Int64
    public var conditionalCount: Int
    public var scanDate: Date?

    public init(trigger: Trigger, reclaimableEstimate: Int64?, itemCount: Int, conditionalEstimate: Int64 = 0,
                conditionalCount: Int = 0, scanDate: Date?) {
        self.trigger = trigger
        self.reclaimableEstimate = reclaimableEstimate
        self.itemCount = itemCount
        self.conditionalEstimate = conditionalEstimate
        self.conditionalCount = conditionalCount
        self.scanDate = scanDate
    }

    public static func from(recommendations: [Recommendation], scanDate: Date?, trigger: Trigger) -> PaywallContext {
        // Conservative: only items DiskLens would pre-select (not high risk, fully analysed, not in
        // use, no admin rights). "Safely" is reserved for tier 1; tier 2 is quoted separately.
        let eligible = recommendations.filter(\.eligibleForAutoSelection)
        let t1 = eligible.filter { $0.tier == .low }, t2 = eligible.filter { $0.tier == .conditional }
        return PaywallContext(trigger: trigger,
                              reclaimableEstimate: scanDate == nil ? nil : t1.reduce(0) { $0 + $1.estimatedReclaimable },
                              itemCount: t1.count,
                              conditionalEstimate: scanDate == nil ? 0 : t2.reduce(0) { $0 + $1.estimatedReclaimable },
                              conditionalCount: t2.count, scanDate: scanDate)
    }

    /// Headline that quotes the measured value, e.g. "DiskLens found 8.5 GB you can safely reclaim".
    public var headline: String {
        if let bytes = reclaimableEstimate, bytes > 0 {
            return "DiskLens found \(ByteFormat.gb(bytes)) you can safely reclaim"
        }
        if reclaimableEstimate != nil, conditionalEstimate > 0 {
            return "DiskLens found \(ByteFormat.gb(conditionalEstimate)) you can reclaim after a quick check"
        }
        switch trigger {
        case .duplicates: return "Find byte-identical duplicates"
        case .scheduling: return "Keep an eye on free space automatically"
        case .reportExport: return "Export reports and keep scan history"
        default: return "Clean up in one click with DiskLens Pro"
        }
    }

    public var subheadline: String {
        let method = "Estimated from your latest scan with APFS private size, so cloned data is not counted. Every cleanup still shows a preview and needs your approval."
        if let bytes = reclaimableEstimate, bytes > 0 {
            let more = conditionalEstimate > 0
                ? " Another \(ByteFormat.gb(conditionalEstimate)) in \(conditionalCount) conditional item\(conditionalCount == 1 ? "" : "s") can go after a quick check."
                : ""
            return "\(itemCount) low-risk item\(itemCount == 1 ? "" : "s") not currently in use.\(more) " + method
        }
        if reclaimableEstimate != nil, conditionalEstimate > 0 {
            return "\(conditionalCount) conditional item\(conditionalCount == 1 ? "" : "s") not currently in use (lockfile present, update pending …). " + method
        }
        if reclaimableEstimate == 0 {
            return "Your latest scan found nothing that is safe to remove automatically right now. Scanning, recommendations, previews and dry runs stay free."
        }
        return "Run a scan to see how much space you can reclaim. Scanning, recommendations, previews and dry runs are free."
    }
}
