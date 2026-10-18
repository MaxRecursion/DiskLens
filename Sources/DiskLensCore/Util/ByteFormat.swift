import Foundation

public enum ByteFormat {
    /// Decimal units (GB = 10^9), matching Finder and `diskutil`.
    public static func string(_ bytes: Int64) -> String {
        let neg = bytes < 0
        let b = Double(abs(bytes))
        let s: String
        switch b {
        case ..<1_000: s = "\(Int(b)) B"
        case ..<1_000_000: s = String(format: "%.1f KB", b / 1e3)
        case ..<1_000_000_000: s = String(format: "%.1f MB", b / 1e6)
        case ..<1_000_000_000_000: s = String(format: "%.2f GB", b / 1e9)
        default: s = String(format: "%.2f TB", b / 1e12)
        }
        return neg ? "−" + s : s
    }

    public static func gb(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }
}
