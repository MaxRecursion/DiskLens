import SwiftUI
import AppKit
import Darwin
import DiskLensCore

/// Folder access for the sandboxed (Mac App Store) edition. The user grants folders through the
/// standard Open panel; DiskLens keeps security-scoped bookmarks so access survives relaunches.
/// In the direct-download edition this is unused (the app is not sandboxed).
@MainActor
@Observable
final class FolderAccess {
    struct Grant: Codable, Identifiable, Hashable {
        var id: String { path }
        var path: String
        var bookmark: Data
    }

    /// Every grant the user made (persisted), including ones that are currently unavailable.
    private(set) var grants: [Grant] = []
    /// Grants whose security scope is active right now, keyed by canonical path (one start each).
    private var active: [String: URL] = [:]
    private static let defaultsKey = "DiskLens.folderGrants.v1"

    init() {
        load()
        startAll()
    }

    /// Paths DiskLens can use now (active grants only).
    var paths: [String] { grants.map(\.path).filter { active[$0] != nil } }
    /// Grants that exist but could not be activated (volume not mounted, bookmark broken…).
    var unavailable: [String] { grants.map(\.path).filter { active[$0] == nil } }
    var hasHomeAccess: Bool { paths.contains { PathUtil.isSameOrInside(Platform.realHome, $0) } }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let g = try? JSONDecoder().decode([Grant].self, from: data) else { return }
        grants = g
    }

    private func save() {
        if let data = try? JSONEncoder().encode(grants) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    private func startAll() {
        for (i, g) in grants.enumerated() {
            var stale = false
            // Never drop a grant just because it cannot be resolved right now (e.g. an unmounted
            // volume); it stays listed as unavailable until the user removes or re-grants it.
            guard let url = try? URL(resolvingBookmarkData: g.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            guard url.startAccessingSecurityScopedResource() else { continue }
            let path = Self.normalized(url.path)
            active[path] = url
            if stale || path != g.path,
               let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                grants[i] = Grant(path: path, bookmark: fresh)
            }
        }
        save()
    }

    /// Canonical path through an open descriptor: resolves symlinks and firmlinked aliases such
    /// as /System/Volumes/Data/Users/x → /Users/x, so PathGuard comparisons match scan paths.
    static func normalized(_ path: String) -> String {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 {
            defer { close(fd) }
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(fd, F_GETPATH, &buf) != -1 { return String(cBuffer: buf) }
        }
        return PathUtil.canonical(path) ?? path
    }

    /// Shows the Open panel pointed at `suggested`. Returns true if access was granted.
    @discardableResult
    func requestFolder(suggested: String, message: String) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: suggested)
        panel.prompt = "Grant Access"
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil),
              url.startAccessingSecurityScopedResource() else { return false }
        let path = Self.normalized(url.path)
        active[path]?.stopAccessingSecurityScopedResource()   // re-grant: keep starts balanced
        active[path] = url
        grants.removeAll { $0.path == path }
        grants.append(Grant(path: path, bookmark: data))
        save()
        return true
    }

    func remove(_ path: String) {
        active[path]?.stopAccessingSecurityScopedResource()
        active[path] = nil
        grants.removeAll { $0.path == path }
        save()
    }
}
