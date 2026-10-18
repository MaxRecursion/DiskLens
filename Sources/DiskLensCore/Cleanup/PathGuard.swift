import Foundation
import Darwin

public enum PathGuardError: Error, Equatable, CustomStringConvertible, Sendable {
    case notAbsolute(String)
    case invalidCharacters(String)
    case traversalComponent(String)
    case doesNotExist(String)
    case notCanonical(path: String, canonical: String)
    case symbolicLink(String)
    case outsideAllowedScope(String)
    case isScopeRoot(String)
    case protectedLocation(path: String, protected: String)
    case containsProtectedLocation(path: String, protected: String)
    case protectedComponent(path: String, component: String)
    case notOwnedByUser(path: String, uid: UInt32)
    case tooShallow(String)

    public var description: String {
        switch self {
        case .notAbsolute(let p): return "Path is not absolute: \(p)"
        case .invalidCharacters(let p): return "Path contains invalid characters: \(p)"
        case .traversalComponent(let p): return "Path contains '.' or '..' components: \(p)"
        case .doesNotExist(let p): return "Path no longer exists: \(p)"
        case .notCanonical(let p, let c): return "Path resolves elsewhere (symlinked ancestor): \(p) -> \(c)"
        case .symbolicLink(let p): return "Target is a symbolic link (refusing to act on links): \(p)"
        case .outsideAllowedScope(let p): return "Path is outside the approved cleanup scope: \(p)"
        case .isScopeRoot(let p): return "Refusing to remove a scope root itself: \(p)"
        case .protectedLocation(let p, let prot): return "Path is inside protected location \(prot): \(p)"
        case .containsProtectedLocation(let p, let prot): return "Path contains protected location \(prot): \(p)"
        case .protectedComponent(let p, let c): return "Path contains protected component '\(c)': \(p)"
        case .notOwnedByUser(let p, let uid): return "Path is owned by another user (uid \(uid)): \(p)"
        case .tooShallow(let p): return "Path is too close to the filesystem root: \(p)"
        }
    }
}

/// Validates every cleanup target immediately before any action. A target must be absolute,
/// canonical (no symlinked ancestors, no ./.. tricks), exist, not be a symlink, be owned by the
/// current user, lie strictly inside an allowed root, and neither be inside nor contain a
/// protected location.
public struct PathGuard: Sendable {
    public var allowedRoots: [String]
    public var protectedPaths: [String]
    /// Personal-content folders (Documents, Desktop…). Inside them only directories whose name is
    /// in `regenerableArtifactNames` may be targeted (e.g. a node_modules in ~/Documents/project).
    public var softProtectedPaths: [String]
    public var regenerableArtifactNames: Set<String>
    public var protectedComponents: Set<String>
    public var protectedSuffixes: [String]
    public var minimumDepth: Int
    public var currentUID: UInt32
    /// Manual single-item Trash: the user picked the item themselves, so anything inside a
    /// soft-protected content folder may be moved to the Trash (the folders themselves may not).
    public var allowAnyContentInSoftProtected = false

    public init(allowedRoots: [String], protectedPaths: [String], softProtectedPaths: [String] = [],
                regenerableArtifactNames: Set<String> = PathGuard.defaultRegenerableArtifactNames,
                protectedComponents: Set<String> = PathGuard.defaultProtectedComponents,
                protectedSuffixes: [String] = PathGuard.defaultProtectedSuffixes, minimumDepth: Int = 3, currentUID: UInt32 = getuid()) {
        // Canonicalise roots so /var vs /private/var etc. compare correctly.
        self.allowedRoots = allowedRoots.map { PathUtil.canonical($0) ?? $0 }
        self.protectedPaths = protectedPaths.map { PathUtil.canonical($0) ?? $0 }
        self.softProtectedPaths = softProtectedPaths.map { PathUtil.canonical($0) ?? $0 }
        self.regenerableArtifactNames = regenerableArtifactNames
        self.protectedComponents = protectedComponents
        self.protectedSuffixes = protectedSuffixes
        self.minimumDepth = minimumDepth
        self.currentUID = currentUID
    }

    public static let defaultProtectedComponents: Set<String> = [
        ".git", ".ssh", ".gnupg", "Keychains", ".password-store", ".aws", ".kube", ".docker-credentials",
    ]
    public static let defaultRegenerableArtifactNames: Set<String> = [
        "node_modules", ".next", ".turbo", ".parcel-cache", ".vite", ".svelte-kit", ".nuxt", ".angular", ".expo",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".venv", "venv", "DerivedData", ".build",
        "dist", "build", "out", "coverage", ".prerender", "obj", "bin", "TestResults",
    ]
    public static let defaultProtectedSuffixes: [String] = [".photoslibrary", ".keychain", ".keychain-db", ".musiclibrary"]

    /// The default guard for this user: cleanup is only ever allowed inside the home folder,
    /// and never inside personal-content or security-sensitive locations.
    /// - Parameter allowedRoots: in the App Store edition, the folders the user granted access to.
    public static func standard(home: String = Platform.realHome, allowedRoots: [String]? = nil) -> PathGuard {
        let h = home
        let protected = [
            "/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/private/etc", "/private/var/db",
            "/Library/Keychains", "/Library/Security",
            "\(h)/Library/Keychains", "\(h)/.ssh", "\(h)/.gnupg",
            "\(h)/Pictures", "\(h)/Movies", "\(h)/Music", "\(h)/Library/Containers", "\(h)/Library/Preferences",
            "\(h)/Library/LaunchAgents", "\(h)/Library/Application Support/Claude/vm_bundles", "\(h)/.colima",
            "\(h)/Library/Mobile Documents", "\(h)/Library/CloudStorage", "\(h)/Library/Mail", "\(h)/Library/Messages",
            "\(h)/Library/Photos", "\(h)/Library/Application Support/AddressBook", "\(h)/Library/Calendars",
            "\(h)/Library/Safari", "\(h)/Library/Cookies", "\(h)/Library/Accounts", "\(h)/Library/Group Containers",
            "\(h)/.mcp-auth", "\(h)/.claude.json", "\(h)/.config/gh", "\(h)/.Trash",
        ]
        let soft = ["\(h)/Documents", "\(h)/Desktop", "\(h)/Downloads", "\(h)/Public"]
        let roots = allowedRoots ?? ([h] + RuleCatalog.userTempRoots())
        return PathGuard(allowedRoots: roots, protectedPaths: protected, softProtectedPaths: soft)
    }

    /// Guard for "Move to Trash" on one item the user selected by hand. Every hard protection
    /// (Keychains, .ssh, Photos/Music libraries, Mail, Messages, Containers, ~/.Trash, .git …) and
    /// every structural check still applies; only the artifact-name restriction inside
    /// Documents/Desktop/Downloads is lifted, because the user chose the item and Trash is reversible.
    public static func manualTrash(home: String = Platform.realHome, allowedRoots: [String]? = nil) -> PathGuard {
        var g = standard(home: home, allowedRoots: allowedRoots)
        g.allowAnyContentInSoftProtected = true
        return g
    }

    public struct Validated: Sendable, Hashable {
        public var path: String
        public var device: Int32
        public var inode: UInt64
        public var isDirectory: Bool
    }

    public func validate(_ path: String) -> Result<Validated, PathGuardError> {
        guard path.hasPrefix("/") else { return .failure(.notAbsolute(path)) }
        if path.contains("\0") || path.contains("\n") { return .failure(.invalidCharacters(path)) }
        let comps = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        if comps.contains(where: { $0 == "." || $0 == ".." }) { return .failure(.traversalComponent(path)) }
        if comps.contains(where: { $0.isEmpty }) && path != "/" { return .failure(.traversalComponent(path)) }
        if comps.count < minimumDepth { return .failure(.tooShallow(path)) }

        var st = stat()
        guard lstat(path, &st) == 0 else { return .failure(.doesNotExist(path)) }
        if (st.st_mode & S_IFMT) == S_IFLNK { return .failure(.symbolicLink(path)) }

        // Canonical check on the parent (the target itself is not a link, checked above).
        let parent = PathUtil.parent(path)
        guard let canonParent = PathUtil.canonical(parent) else { return .failure(.doesNotExist(path)) }
        let canonical = (canonParent == "/" ? "" : canonParent) + "/" + PathUtil.lastComponent(path)
        guard canonical == path else { return .failure(.notCanonical(path: path, canonical: canonical)) }

        // APFS volumes are normally case-insensitive: compare case-folded paths so
        // "~/documents/x" cannot slip past a "~/Documents" protection.
        func fold(_ p: String) -> String { p.folding(options: [.caseInsensitive], locale: nil) }
        let fpath = fold(path)
        let foldedComponents = Set(protectedComponents.map(fold))
        for comp in comps where foldedComponents.contains(fold(String(comp))) {
            return .failure(.protectedComponent(path: path, component: String(comp)))
        }
        for suf in protectedSuffixes.map(fold) where fpath.contains(suf + "/") || fpath.hasSuffix(suf) {
            return .failure(.protectedComponent(path: path, component: suf))
        }
        for p in protectedPaths {
            let fp = fold(p)
            if PathUtil.isSameOrInside(fpath, fp) { return .failure(.protectedLocation(path: path, protected: p)) }
            if PathUtil.isStrictlyInside(fp, fpath) { return .failure(.containsProtectedLocation(path: path, protected: p)) }
        }
        for p in softProtectedPaths {
            let fp = fold(p)
            if PathUtil.isStrictlyInside(fp, fpath) || fpath == fp { return .failure(.containsProtectedLocation(path: path, protected: p)) }
            if PathUtil.isStrictlyInside(fpath, fp) && !allowAnyContentInSoftProtected
                && !regenerableArtifactNames.contains(PathUtil.lastComponent(path)) {
                return .failure(.protectedLocation(path: path, protected: p))
            }
        }
        if allowedRoots.contains(where: { fold($0) == fpath }) { return .failure(.isScopeRoot(path)) }
        guard allowedRoots.contains(where: { PathUtil.isStrictlyInside(fpath, fold($0)) }) else {
            return .failure(.outsideAllowedScope(path))
        }
        guard st.st_uid == currentUID else { return .failure(.notOwnedByUser(path: path, uid: st.st_uid)) }
        return .success(Validated(path: path, device: st.st_dev, inode: UInt64(st.st_ino),
                                  isDirectory: (st.st_mode & S_IFMT) == S_IFDIR))
    }
}
