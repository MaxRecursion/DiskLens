import Foundation

/// Storage categories. Every byte in a scan is attributed to exactly one category
/// (see `ScanTree.categoryTotals()`), so category totals always sum to the scan total.
public enum StorageCategory: String, Codable, CaseIterable, Sendable, Hashable {
    case applications
    case documentsMedia
    case developerArtifacts
    case packageCaches
    case sdkData
    case aiTools
    case downloadsArchives
    case systemManaged
    case other
    case inaccessible

    public var displayName: String {
        switch self {
        case .applications: return "Applications"
        case .documentsMedia: return "Documents & Media"
        case .developerArtifacts: return "Developer Tools & Build Artifacts"
        case .packageCaches: return "Package-Manager Caches"
        case .sdkData: return "SDKs, Runtimes & VMs"
        case .aiTools: return "AI Models & Dev-Tool Data"
        case .downloadsArchives: return "Downloads & Archives"
        case .systemManaged: return "System & App-Managed"
        case .other: return "Other Files"
        case .inaccessible: return "Unclassified / Inaccessible"
        }
    }

    /// Stable sRGB colour used by the treemap and charts (r, g, b in 0...1).
    public var rgb: (Double, Double, Double) {
        switch self {
        case .applications: return (0.30, 0.56, 0.98)
        case .documentsMedia: return (0.96, 0.62, 0.20)
        case .developerArtifacts: return (0.62, 0.42, 0.96)
        case .packageCaches: return (0.20, 0.78, 0.62)
        case .sdkData: return (0.95, 0.38, 0.55)
        case .aiTools: return (0.98, 0.80, 0.25)
        case .downloadsArchives: return (0.38, 0.80, 0.95)
        case .systemManaged: return (0.55, 0.60, 0.68)
        case .other: return (0.45, 0.70, 0.40)
        case .inaccessible: return (0.35, 0.35, 0.38)
        }
    }
}
