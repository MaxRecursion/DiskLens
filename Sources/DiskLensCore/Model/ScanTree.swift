import Foundation

public struct NodeFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let directory     = NodeFlags(rawValue: 1 << 0)
    /// The directory could not be opened (EPERM/EACCES/TCC). Its size is UNKNOWN, not zero.
    public static let unreadable    = NodeFlags(rawValue: 1 << 1)
    /// Synthetic node aggregating files below the per-file node threshold.
    public static let aggregate     = NodeFlags(rawValue: 1 << 2)
    /// A directory on another device (mount point) that was deliberately not crossed.
    public static let mountBoundary = NodeFlags(rawValue: 1 << 3)
    /// A bundle directory such as Foo.app.
    public static let package       = NodeFlags(rawValue: 1 << 4)
    /// Some entry below this node could not be read or stat'ed.
    public static let partial       = NodeFlags(rawValue: 1 << 5)
    /// Virtual root that holds the scan roots.
    public static let virtualRoot   = NodeFlags(rawValue: 1 << 6)
    /// A file whose logical size is much larger than its allocation (VM disks, databases).
    public static let sparse        = NodeFlags(rawValue: 1 << 7)
    /// Dataless File Provider / iCloud placeholder (content not on this disk).
    public static let dataless      = NodeFlags(rawValue: 1 << 8)
}

/// Marker files seen directly inside a directory during the scan (recorded from directory entries
/// fts already visits, so classification and rules never need extra disk I/O).
public struct ProjectMarkers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let packageJSON     = ProjectMarkers(rawValue: 1 << 0)
    public static let npmLock         = ProjectMarkers(rawValue: 1 << 1)
    public static let pnpmLock        = ProjectMarkers(rawValue: 1 << 2)
    public static let yarnLock        = ProjectMarkers(rawValue: 1 << 3)
    public static let bunLock         = ProjectMarkers(rawValue: 1 << 4)
    public static let dotnetProject   = ProjectMarkers(rawValue: 1 << 5)
    public static let pyvenvCfg       = ProjectMarkers(rawValue: 1 << 6)
    public static let pythonManifest  = ProjectMarkers(rawValue: 1 << 7)
    public static let cargoToml       = ProjectMarkers(rawValue: 1 << 8)
    public static let chromiumProfile = ProjectMarkers(rawValue: 1 << 9)
    public static let gitRepo         = ProjectMarkers(rawValue: 1 << 10)
    public static let swiftPackage    = ProjectMarkers(rawValue: 1 << 11)
    public static let pnpmVirtualStore = ProjectMarkers(rawValue: 1 << 12)

    public static let anyLockfile: ProjectMarkers = [.npmLock, .pnpmLock, .yarnLock, .bunLock]

    /// Marker contributed by a file name, if any.
    public static func forFile(_ name: String) -> ProjectMarkers {
        switch name {
        case "package.json": return .packageJSON
        case "package-lock.json", "npm-shrinkwrap.json": return .npmLock
        case "pnpm-lock.yaml": return .pnpmLock
        case "yarn.lock": return .yarnLock
        case "bun.lockb", "bun.lock": return .bunLock
        case "pyvenv.cfg": return .pyvenvCfg
        case "requirements.txt", "pyproject.toml", "poetry.lock", "uv.lock", "Pipfile.lock", "setup.py": return .pythonManifest
        case "Cargo.toml": return .cargoToml
        case "Preferences", "Cookies": return .chromiumProfile
        case "Package.swift": return .swiftPackage
        default:
            if name.hasSuffix(".csproj") || name.hasSuffix(".fsproj") || name.hasSuffix(".vbproj") || name.hasSuffix(".sln") { return .dotnetProject }
            return []
        }
    }

    /// Marker contributed by a sub-directory name, if any.
    public static func forDirectory(_ name: String) -> ProjectMarkers {
        switch name {
        case ".git": return .gitRepo
        case ".pnpm": return .pnpmVirtualStore
        default: return []
        }
    }

    /// The lockfile file name for display/commands.
    public var lockfileName: String? {
        if contains(.pnpmLock) { return "pnpm-lock.yaml" }
        if contains(.yarnLock) { return "yarn.lock" }
        if contains(.bunLock) { return "bun.lock" }
        if contains(.npmLock) { return "package-lock.json" }
        return nil
    }
}

/// One node of the scan tree. Directories always get a node; regular files get a node only
/// when they are at least `ScanOptions.fileNodeThreshold`; smaller files are accumulated into a
/// single synthetic `aggregate` child per directory. Invariant (tested): for every directory,
/// `allocated == sum(children.allocated)` and the same for `logical` and `fileCount`.
public struct ScanNode: Codable, Sendable, Hashable {
    public var name: String
    public var parent: Int32
    public var children: [Int32]
    public var flags: NodeFlags
    public var logical: Int64
    public var allocated: Int64
    public var fileCount: Int64
    public var errorCount: Int32
    public var mtime: Int64
    public var device: Int32
    public var inode: UInt64
    public var category: StorageCategory
    /// Identifier of the classification rule that assigned `category` (transparency).
    public var categoryRule: String
    /// Marker files/sub-directories found directly inside this directory.
    public var markers: ProjectMarkers = []

    public var isDirectory: Bool { flags.contains(.directory) }
    public var isAggregate: Bool { flags.contains(.aggregate) }

    public init(name: String, parent: Int32, flags: NodeFlags, logical: Int64 = 0, allocated: Int64 = 0,
                fileCount: Int64 = 0, errorCount: Int32 = 0, mtime: Int64 = 0, device: Int32 = 0,
                inode: UInt64 = 0, category: StorageCategory = .other, categoryRule: String = "") {
        self.name = name
        self.parent = parent
        self.children = []
        self.flags = flags
        self.logical = logical
        self.allocated = allocated
        self.fileCount = fileCount
        self.errorCount = errorCount
        self.mtime = mtime
        self.device = device
        self.inode = inode
        self.category = category
        self.categoryRule = categoryRule
    }
}

/// Arena-backed scan tree. Node 0 is a virtual root whose children are the scan roots; a scan
/// root's `name` is its absolute canonical path, every other node's `name` is one path component.
public struct ScanTree: Codable, Sendable {
    public var nodes: [ScanNode]

    public init() {
        nodes = [ScanNode(name: "/", parent: -1, flags: [.directory, .virtualRoot])]
    }

    public static let root: Int32 = 0

    public subscript(_ i: Int32) -> ScanNode {
        get { nodes[Int(i)] }
        set { nodes[Int(i)] = newValue }
    }

    public var count: Int { nodes.count }
    public var rootIDs: [Int32] { nodes[0].children }
    public var totalAllocated: Int64 { nodes[0].allocated }
    public var totalLogical: Int64 { nodes[0].logical }

    @discardableResult
    public mutating func append(_ node: ScanNode) -> Int32 {
        let id = Int32(nodes.count)
        nodes.append(node)
        if node.parent >= 0 { nodes[Int(node.parent)].children.append(id) }
        return id
    }

    /// Absolute path of a node. Aggregate nodes return their directory path + "/<name>".
    public func path(of id: Int32) -> String {
        if id == ScanTree.root { return "/" }
        var parts: [Substring] = []
        var cur = id
        while cur > 0 {
            let n = nodes[Int(cur)]
            if n.parent == ScanTree.root {
                // scan root: absolute path
                var p = n.name
                for part in parts.reversed() { p += (p.hasSuffix("/") ? "" : "/") + part }
                return p
            }
            parts.append(Substring(n.name))
            cur = n.parent
        }
        return "/" + parts.reversed().joined(separator: "/")
    }

    /// Chain of node ids from the virtual root (exclusive) to `id` (inclusive).
    public func ancestry(of id: Int32) -> [Int32] {
        var chain: [Int32] = []
        var cur = id
        while cur > 0 {
            chain.append(cur)
            cur = nodes[Int(cur)].parent
        }
        return chain.reversed()
    }

    public func depth(of id: Int32) -> Int { ancestry(of: id).count }

    /// Looks up a node by absolute path (walks from the matching scan root). O(depth * fanout).
    public func find(path: String) -> Int32? {
        let target = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        for r in rootIDs {
            let rootPath = nodes[Int(r)].name
            if target == rootPath { return r }
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            guard target.hasPrefix(prefix) else { continue }
            let rest = target.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true)
            var cur = r
            var ok = true
            for comp in rest {
                guard let next = nodes[Int(cur)].children.first(where: { nodes[Int($0)].name == comp }) else {
                    ok = false; break
                }
                cur = next
            }
            if ok { return cur }
        }
        return nil
    }

    /// Children sorted by allocated size, descending.
    public func sortedChildren(of id: Int32) -> [Int32] {
        nodes[Int(id)].children.sorted { nodes[Int($0)].allocated > nodes[Int($1)].allocated }
    }

    /// Visits every node below (and including) `id` in pre-order. Return false from `body` to
    /// skip the node's descendants.
    public func walk(from id: Int32 = ScanTree.root, _ body: (Int32, ScanNode) -> Bool) {
        var stack: [Int32] = [id]
        while let cur = stack.popLast() {
            let n = nodes[Int(cur)]
            if body(cur, n) { stack.append(contentsOf: n.children.reversed()) }
        }
    }

    /// Per-category totals computed from LEAF nodes only (files, aggregate buckets, unreadable
    /// directories), so each byte is counted exactly once regardless of nesting.
    public func categoryTotals(under id: Int32 = ScanTree.root) -> [StorageCategory: (allocated: Int64, logical: Int64, files: Int64)] {
        var out: [StorageCategory: (allocated: Int64, logical: Int64, files: Int64)] = [:]
        walk(from: id) { _, n in
            if n.children.isEmpty {
                var t = out[n.category] ?? (0, 0, 0)
                t.allocated += n.allocated
                t.logical += n.logical
                t.files += n.fileCount
                out[n.category] = t
            }
            return true
        }
        return out
    }

    /// For every node, the category holding the most bytes beneath it (leaves: their own
    /// category). One bottom-up pass; relies on parents always preceding children in `nodes`.
    public func dominantCategories() -> [StorageCategory] {
        let cats = StorageCategory.allCases
        let k = cats.count
        let index = Dictionary(uniqueKeysWithValues: cats.enumerated().map { ($0.element, $0.offset) })
        var totals = [Int64](repeating: 0, count: nodes.count * k)
        for i in stride(from: nodes.count - 1, through: 0, by: -1) {
            let n = nodes[i]
            if n.children.isEmpty { totals[i * k + index[n.category]!] += max(n.allocated, 1) }
            if n.parent >= 0 {
                let p = Int(n.parent)
                for c in 0..<k { totals[p * k + c] += totals[i * k + c] }
            }
        }
        return (0..<nodes.count).map { i in
            var best = index[nodes[i].category]!, bestV: Int64 = -1
            for c in 0..<k where totals[i * k + c] > bestV { best = c; bestV = totals[i * k + c] }
            return cats[best]
        }
    }

    /// Recomputes directory totals bottom-up from leaves. Used after deserialisation checks
    /// and in tests to assert the aggregation invariant.
    public func recomputedTotals(of id: Int32) -> (allocated: Int64, logical: Int64, files: Int64) {
        let n = nodes[Int(id)]
        if n.children.isEmpty { return (n.allocated, n.logical, n.fileCount) }
        var a: Int64 = 0, l: Int64 = 0, f: Int64 = 0
        for c in n.children {
            let t = recomputedTotals(of: c)
            a += t.allocated; l += t.logical; f += t.files
        }
        return (a, l, f)
    }

    /// Case-insensitive substring search over node names. Results sorted by size.
    public func search(_ query: String, limit: Int = 500, minAllocated: Int64 = 0) -> [Int32] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var hits: [Int32] = []
        for (i, n) in nodes.enumerated() where i > 0 && !n.isAggregate && n.allocated >= minAllocated {
            if n.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                hits.append(Int32(i))
            }
        }
        hits.sort { nodes[Int($0)].allocated > nodes[Int($1)].allocated }
        return Array(hits.prefix(limit))
    }

    /// Largest individual files (non-aggregate leaves) in the tree.
    public func largestFiles(limit: Int = 100, under id: Int32 = ScanTree.root) -> [Int32] {
        var files: [Int32] = []
        walk(from: id) { i, n in
            if !n.isDirectory && !n.isAggregate { files.append(i) }
            return true
        }
        files.sort { nodes[Int($0)].allocated > nodes[Int($1)].allocated }
        return Array(files.prefix(limit))
    }
}
