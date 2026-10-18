import Foundation
import Darwin

public enum PathUtil {
    /// Fully resolved absolute path (symlinks, "." and ".." removed) or nil if it does not exist.
    public static func canonical(_ path: String) -> String? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard let r = realpath(expanded, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// True when `child` is strictly inside `parent` (component-wise, not a string prefix trick).
    public static func isStrictlyInside(_ child: String, _ parent: String) -> Bool {
        if parent == "/" { return child.count > 1 && child.hasPrefix("/") }
        return child.hasPrefix(parent + "/")
    }

    public static func isSameOrInside(_ child: String, _ parent: String) -> Bool {
        child == parent || isStrictlyInside(child, parent)
    }

    /// Removes roots that are equal to or nested inside another root, so no subtree is scanned
    /// (and counted) twice. Returns (kept, dropped) preserving the original order of kept roots.
    public static func deoverlap(_ roots: [String]) -> (kept: [String], dropped: [String]) {
        var kept: [String] = []
        var dropped: [String] = []
        // Shorter paths first so ancestors are seen before descendants.
        let order = roots.enumerated().sorted { a, b in
            a.element.count != b.element.count ? a.element.count < b.element.count : a.offset < b.offset
        }
        var keptSet: [(Int, String)] = []
        for (idx, r) in order {
            if keptSet.contains(where: { isSameOrInside(r, $0.1) }) {
                dropped.append(r)
            } else {
                keptSet.append((idx, r))
            }
        }
        kept = keptSet.sorted { $0.0 < $1.0 }.map { $0.1 }
        return (kept, dropped)
    }

    /// Path components after normalising duplicate slashes. Does NOT resolve symlinks.
    public static func components(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }

    public static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    public static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Replaces the home-directory prefix with "~" for display.
    public static func abbreviated(_ path: String, home: String = Platform.realHome) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

public extension String {
    /// Decodes a NUL-terminated C buffer (e.g. from F_GETPATH or confstr) as UTF-8.
    init(cBuffer buf: [CChar]) {
        self = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
