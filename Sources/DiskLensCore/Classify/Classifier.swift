import Foundation

/// A transparent, ordered classification rule. The rule id is stored on every node it
/// classifies so the UI can explain *why* a byte landed in a category.
public struct ClassificationRule: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Matches the node at this absolute path ("~" expanded) — and, if sticky, its subtree.
        case path(String)
        /// Matches a DIRECTORY whose name equals one of these.
        case directoryName(Set<String>)
        /// Matches a DIRECTORY whose name ends with one of these (lower-cased), e.g. ".app".
        case directorySuffix([String])
        /// Matches a FILE whose lower-cased extension is one of these.
        case fileExtension(Set<String>)
        /// Directory named `name` whose parent directory holds one of these markers
        /// (e.g. bin/obj next to a .csproj). Markers come from the scan — no extra disk I/O.
        case directoryWithSibling(name: Set<String>, parentMarkers: ProjectMarkers)
        /// Directory named `name` that itself holds one of these markers (e.g. pyvenv.cfg).
        case directoryContaining(name: Set<String>, markers: ProjectMarkers)
    }

    public var id: String
    public var description: String
    public var category: StorageCategory
    public var kind: Kind
    /// Sticky rules classify their whole subtree; non-sticky rules only set the default that
    /// more specific rules below can override.
    public var sticky: Bool

    public init(_ id: String, _ category: StorageCategory, _ kind: Kind, sticky: Bool, _ description: String) {
        self.id = id
        self.category = category
        self.kind = kind
        self.sticky = sticky
        self.description = description
    }
}

public enum Classifier {
    public static let unreadableRuleID = "unreadable"
    public static let defaultRuleID = "default"

    public static func defaultRules(home: String = Platform.realHome) -> [ClassificationRule] {
        let h = home
        typealias R = ClassificationRule
        let archiveExt: Set<String> = ["dmg", "pkg", "mpkg", "zip", "iso", "xip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst"]
        let mediaExt: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "raw", "cr2", "nef", "arw", "dng",
                                     "mov", "mp4", "m4v", "avi", "mkv", "webm", "mp3", "m4a", "wav", "aiff", "flac", "aac",
                                     "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "psd", "ai", "sketch", "fig"]
        let modelExt: Set<String> = ["gguf", "safetensors", "ckpt", "pt", "pth", "onnx", "mlmodel", "tflite", "h5"]
        return [
            // --- Applications
            R("applications", .applications, .path("/Applications"), sticky: true, "Installed applications in /Applications"),
            R("user-applications", .applications, .path("\(h)/Applications"), sticky: true, "Applications installed in ~/Applications"),

            // --- Package-manager caches (sticky)
            R("npm-cache", .packageCaches, .path("\(h)/.npm"), sticky: true, "npm cache (~/.npm)"),
            R("pnpm-store", .packageCaches, .path("\(h)/Library/pnpm"), sticky: true, "pnpm content-addressable store"),
            R("pnpm-cache", .packageCaches, .path("\(h)/Library/Caches/pnpm"), sticky: true, "pnpm metadata cache"),
            R("homebrew-cache", .packageCaches, .path("\(h)/Library/Caches/Homebrew"), sticky: true, "Homebrew download cache"),
            R("pip-cache", .packageCaches, .path("\(h)/Library/Caches/pip"), sticky: true, "pip wheel/http cache"),
            R("playwright", .packageCaches, .path("\(h)/Library/Caches/ms-playwright"), sticky: true, "Playwright browser binaries"),
            R("node-gyp", .packageCaches, .path("\(h)/Library/Caches/node-gyp"), sticky: true, "node-gyp headers cache"),
            R("yarn-cache", .packageCaches, .path("\(h)/Library/Caches/Yarn"), sticky: true, "Yarn cache"),
            R("nuget-packages", .packageCaches, .path("\(h)/.nuget"), sticky: true, "NuGet global packages folder"),
            R("nuget-v3-cache", .packageCaches, .path("\(h)/.local/share/NuGet"), sticky: true, "NuGet HTTP/plugin caches"),
            R("dot-cache", .packageCaches, .path("\(h)/.cache"), sticky: false, "XDG cache directory (~/.cache)"),
            R("swiftpm-cache", .packageCaches, .path("\(h)/Library/Caches/org.swift.swiftpm"), sticky: true, "SwiftPM cache"),
            R("colima-cache", .packageCaches, .path("\(h)/Library/Caches/colima"), sticky: true, "Colima downloaded VM images"),

            // --- SDKs, runtimes, VMs (sticky)
            R("dotnet-sdk", .sdkData, .path("\(h)/.dotnet"), sticky: true, ".NET SDKs, runtimes, workloads (~/.dotnet)"),
            R("dotnet-system", .sdkData, .path("/usr/local/share/dotnet"), sticky: true, "System-wide .NET install"),
            R("homebrew", .sdkData, .path("/opt/homebrew"), sticky: true, "Homebrew prefix (formulae, casks, kegs)"),
            R("usr-local", .sdkData, .path("/usr/local"), sticky: true, "/usr/local tools"),
            R("clt", .sdkData, .path("/Library/Developer"), sticky: true, "Xcode Command Line Tools / developer SDKs"),
            R("user-developer", .sdkData, .path("\(h)/Library/Developer"), sticky: true, "Xcode DerivedData, simulators, device support"),
            R("android-sdk", .sdkData, .path("\(h)/Library/Android"), sticky: true, "Android SDK"),
            R("colima-vm", .sdkData, .path("\(h)/.colima"), sticky: true, "Colima/Lima VM disks (Docker images, containers, volumes)"),
            R("docker-desktop", .sdkData, .path("\(h)/Library/Containers/com.docker.docker"), sticky: true, "Docker Desktop VM data"),
            R("local-bin", .sdkData, .path("\(h)/.local"), sticky: false, "~/.local user-installed tools"),
            R("gradle", .sdkData, .path("\(h)/.gradle"), sticky: true, "Gradle caches/wrappers"),
            R("rustup", .sdkData, .path("\(h)/.rustup"), sticky: true, "Rust toolchains"),
            R("cargo", .packageCaches, .path("\(h)/.cargo"), sticky: true, "Cargo registry/cache"),

            // --- AI tools & dev-tool data (sticky)
            R("claude-code", .aiTools, .path("\(h)/.claude"), sticky: true, "Claude Code data (history, caches, plugins)"),
            R("codex", .aiTools, .path("\(h)/.codex"), sticky: true, "OpenAI Codex CLI data"),
            R("openclaw", .aiTools, .path("\(h)/.openclaw"), sticky: true, "OpenClaw data"),
            R("cursor-home", .aiTools, .path("\(h)/.cursor"), sticky: true, "Cursor extensions/config"),
            R("copilot", .aiTools, .path("\(h)/.copilot"), sticky: true, "GitHub Copilot CLI data"),
            R("vscode-home", .aiTools, .path("\(h)/.vscode"), sticky: true, "VS Code extensions"),
            R("ollama", .aiTools, .path("\(h)/.ollama"), sticky: true, "Ollama models"),
            R("lmstudio", .aiTools, .path("\(h)/.lmstudio"), sticky: true, "LM Studio models"),
            R("huggingface", .aiTools, .path("\(h)/.cache/huggingface"), sticky: true, "Hugging Face model cache"),
            R("claude-desktop", .aiTools, .path("\(h)/Library/Application Support/Claude"), sticky: true, "Claude desktop app data (incl. VM bundle)"),
            R("cursor-support", .aiTools, .path("\(h)/Library/Application Support/Cursor"), sticky: true, "Cursor application data"),
            R("vscode-support", .aiTools, .path("\(h)/Library/Application Support/Code"), sticky: true, "VS Code application data"),
            R("chatgpt-support", .aiTools, .path("\(h)/Library/Application Support/com.openai.chat"), sticky: true, "ChatGPT desktop data"),
            R("codex-support", .aiTools, .path("\(h)/Library/Application Support/Codex"), sticky: true, "Codex desktop data"),
            R("jetbrains-support", .aiTools, .path("\(h)/Library/Application Support/JetBrains"), sticky: true, "JetBrains IDE data"),
            R("model-files", .aiTools, .fileExtension(modelExt), sticky: false, "Machine-learning model weight files"),

            // --- System & app-managed
            R("user-caches", .systemManaged, .path("\(h)/Library/Caches"), sticky: false, "Per-app caches (~/Library/Caches)"),
            R("user-library", .systemManaged, .path("\(h)/Library"), sticky: false, "App-managed data (~/Library)"),
            R("system-library", .systemManaged, .path("/Library"), sticky: true, "System-wide app data (/Library)"),
            R("var-folders", .systemManaged, .path("/private/var/folders"), sticky: true, "Per-user temp & cache folders (/var/folders)"),
            R("private-var", .systemManaged, .path("/private/var"), sticky: true, "System data (/private/var)"),
            R("system", .systemManaged, .path("/System"), sticky: true, "macOS system data"),
            R("trash", .systemManaged, .path("\(h)/.Trash"), sticky: true, "Trash"),
            R("users-shared", .other, .path("/Users/Shared"), sticky: false, "Shared user folder"),

            // --- Developer artifacts (name-based, sticky)
            R("node-modules", .developerArtifacts, .directoryName(["node_modules"]), sticky: true, "JavaScript dependencies (node_modules)"),
            R("js-build-cache", .developerArtifacts, .directoryName([".next", ".turbo", ".parcel-cache", ".vite", ".svelte-kit", ".nuxt", ".angular", ".expo"]), sticky: true, "Front-end framework build output / cache"),
            R("python-bytecode", .developerArtifacts, .directoryName(["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox"]), sticky: true, "Python bytecode / tool caches"),
            R("python-venv", .developerArtifacts, .directoryContaining(name: [".venv", "venv", "env", ".env"], markers: .pyvenvCfg), sticky: true, "Python virtual environment"),
            R("dotnet-build", .developerArtifacts, .directoryWithSibling(name: ["bin", "obj", "TestResults"], parentMarkers: .dotnetProject), sticky: true, ".NET build output (bin/obj next to a project file)"),
            R("js-dist", .developerArtifacts, .directoryWithSibling(name: ["dist", "build", "out", "coverage"], parentMarkers: .packageJSON), sticky: true, "JS build output next to package.json"),
            R("xcode-derived", .developerArtifacts, .directoryName(["DerivedData", ".build"]), sticky: true, "Swift/Xcode build output"),
            R("rust-target", .developerArtifacts, .directoryWithSibling(name: ["target"], parentMarkers: .cargoToml), sticky: true, "Rust build output"),
            R("git-data", .developerArtifacts, .directoryName([".git"]), sticky: true, "Git repository data (history — never auto-deleted)"),
            R("app-bundle", .applications, .directorySuffix([".app"]), sticky: true, "Application bundle"),

            // --- User content (non-sticky containers + extension rules)
            R("downloads", .downloadsArchives, .path("\(h)/Downloads"), sticky: false, "Downloads folder"),
            R("archives", .downloadsArchives, .fileExtension(archiveExt), sticky: false, "Archives and installers"),
            R("documents", .documentsMedia, .path("\(h)/Documents"), sticky: false, "Documents folder"),
            R("desktop", .documentsMedia, .path("\(h)/Desktop"), sticky: false, "Desktop folder"),
            R("pictures", .documentsMedia, .path("\(h)/Pictures"), sticky: false, "Pictures folder"),
            R("movies", .documentsMedia, .path("\(h)/Movies"), sticky: false, "Movies folder"),
            R("music", .documentsMedia, .path("\(h)/Music"), sticky: false, "Music folder"),
            R("media-files", .documentsMedia, .fileExtension(mediaExt), sticky: false, "Media and document files"),
            R("home", .other, .path(h), sticky: false, "Home folder (unclassified files)"),
        ]
    }

    /// Assigns `category` and `categoryRule` to every node, top-down, in one pass.
    /// Every node ends up with exactly one category (tested).
    public static func classify(_ tree: inout ScanTree, rules: [ClassificationRule] = defaultRules()) {
        // Resolve path rules to node ids once.
        var pathRule: [Int32: Int] = [:]
        for (i, r) in rules.enumerated() {
            if case .path(let p) = r.kind, let id = tree.find(path: p), pathRule[id] == nil {
                pathRule[id] = i
            }
        }
        let nameRules = rules.enumerated().filter {
            switch $0.element.kind {
            case .directoryName, .directorySuffix, .directoryWithSibling, .directoryContaining: return true
            default: return false
            }
        }
        let extRules = rules.enumerated().filter { if case .fileExtension = $0.element.kind { return true }; return false }

        struct Ctx { var id: Int32; var category: StorageCategory; var rule: String; var sticky: Bool }
        // A scan root may lie inside a rule's path (e.g. the user's /var/folders/… inside
        // "/private/var/folders"): seed it from the most specific such rule.
        var stack: [Ctx] = []
        for r in tree.rootIDs.reversed() {
            let rootPath = tree.nodes[Int(r)].name
            let enclosing = rules.enumerated().compactMap { (i, rule) -> (Int, Int)? in
                if case .path(let p) = rule.kind, PathUtil.isStrictlyInside(rootPath, p) { return (i, p.count) }
                return nil
            }.max { $0.1 < $1.1 }
            if let (ri, _) = enclosing {
                stack.append(Ctx(id: r, category: rules[ri].category, rule: rules[ri].id, sticky: rules[ri].sticky))
            } else {
                stack.append(Ctx(id: r, category: .other, rule: defaultRuleID, sticky: false))
            }
        }
        tree.nodes[0].category = .other
        tree.nodes[0].categoryRule = defaultRuleID
        while let ctx = stack.popLast() {
            var node = tree.nodes[Int(ctx.id)]
            if node.parent == ScanTree.root { node.name = PathUtil.lastComponent(node.name) }   // name rules see a component
            var cat = ctx.category
            var rule = ctx.rule
            var sticky = ctx.sticky

            if node.flags.contains(.unreadable) {
                cat = .inaccessible; rule = unreadableRuleID
            } else if let ri = pathRule[ctx.id] {
                // An explicit path rule is more specific than anything inherited, sticky or not.
                cat = rules[ri].category; rule = rules[ri].id; sticky = rules[ri].sticky
            } else if !sticky && ctx.id != ScanTree.root {
                if node.isDirectory {
                    if let m = nameRules.first(where: { matches($0.element.kind, node: node, id: ctx.id, tree: tree) }) {
                        cat = m.element.category; rule = m.element.id; sticky = m.element.sticky
                    }
                } else if !node.isAggregate {
                    let ext = (node.name as NSString).pathExtension.lowercased()
                    if !ext.isEmpty, let m = extRules.first(where: {
                        if case .fileExtension(let set) = $0.element.kind { return set.contains(ext) }
                        return false
                    }) {
                        cat = m.element.category; rule = m.element.id
                    }
                }
            }
            tree.nodes[Int(ctx.id)].category = cat
            tree.nodes[Int(ctx.id)].categoryRule = rule
            for c in tree.nodes[Int(ctx.id)].children {
                stack.append(Ctx(id: c, category: cat, rule: rule, sticky: sticky))
            }
        }
    }

    static func matches(_ kind: ClassificationRule.Kind, node: ScanNode, id: Int32, tree: ScanTree) -> Bool {
        switch kind {
        case .directoryName(let names):
            return names.contains(node.name)
        case .directorySuffix(let suffixes):
            // Require bundle structure: cache folders named after bundle ids ("com.foo.app") are not apps.
            let lower = node.name.lowercased()
            return suffixes.contains { lower.hasSuffix($0) }
                && node.children.contains { tree.nodes[Int($0)].name == "Contents" && tree.nodes[Int($0)].isDirectory }
        case .directoryWithSibling(let names, let parentMarkers):
            guard names.contains(node.name), node.parent >= 0 else { return false }
            return !tree.nodes[Int(node.parent)].markers.isDisjoint(with: parentMarkers)
        case .directoryContaining(let names, let markers):
            return names.contains(node.name) && !node.markers.isDisjoint(with: markers)
        case .path, .fileExtension:
            return false
        }
    }


    /// Category totals with the rule ids that contributed, for the transparency table.
    public static func ruleTotals(_ tree: ScanTree) -> [String: Int64] {
        var out: [String: Int64] = [:]
        tree.walk { _, n in
            if n.children.isEmpty { out[n.categoryRule, default: 0] += n.allocated }
            return true
        }
        return out
    }
}
