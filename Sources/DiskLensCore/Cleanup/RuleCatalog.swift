import Foundation
import Darwin

/// The standard cleanup rule set. Rules are ordered by priority: earlier rules claim nodes first,
/// and a claimed node's ancestors/descendants can never be claimed again (no double counting).
///
/// Rules were calibrated against a read-only forensic inventory of a real developer Mac
/// (npm/pnpm caches, Sparkle/Squirrel update leftovers, Electron caches, Claude Code worktrees,
/// VM disks, APFS-cloned build outputs…) but are expressed generically.
public enum RuleCatalog {
    static let gib: Int64 = 1 << 30
    static let mib: Int64 = 1 << 20

    public static func standard(home: String = Platform.realHome) -> [CleanupRule] {
        var r: [CleanupRule] = []
        r += packageCaches()
        r += updaterLeftovers()
        r += appCaches()
        r += versionedInstalls()
        r += projectArtifacts(home: home)
        r += aiToolData()
        r += manualReview(home: home)
        return r
    }

    // MARK: - Package-manager & tool caches (tier 1)

    static func simpleCache(_ id: String, _ path: String, min: Int64 = 20 << 20, title: String, reason: String,
                            consequences: String, owners: [String] = [], tier: CleanupTier = .low,
                            confidence: Confidence = .high) -> CleanupRule {
        CleanupRule(id: id, matcher: .path(path), minBytes: min) { i in
            i.make(title: title, tier: tier, risk: .low, confidence: confidence, action: .delete(i.path),
                   reason: reason, consequences: consequences, owners: owners)
        }
    }

    static func packageCaches() -> [CleanupRule] {
        let npmBusy = ["npm-cli.js install", "npm-cli.js ci", "npm-cli.js i ", "npm-cli.js update", "npm-cli.js exec", "npx-cli.js"]
        return [
            simpleCache("npm-cache", "~/.npm/_cacache", title: "npm download cache",
                        reason: "npm's content-addressable package download cache. npm re-fetches any package it needs; this is exactly what `npm cache clean --force` removes. Installed node_modules folders do not depend on it.",
                        consequences: "The next npm install of uncached packages downloads them again (needs network, slower once).",
                        owners: npmBusy),
            CleanupRule(id: "npx-package", matcher: .childrenOf("~/.npm/_npx"), minBytes: 10 << 20) { i in
                i.make(title: "npx on-demand package \(PathUtil.lastComponent(i.path))", tier: .low, risk: .low, confidence: .high,
                       action: .delete(i.path),
                       reason: "A package that `npx` installed on demand. npx reinstalls it automatically the next time the same command runs.",
                       consequences: "The next `npx` invocation of this package re-downloads it. Skipped automatically while any running process was launched from it.",
                       owners: [i.path + "/"])
            },
            simpleCache("npm-logs", "~/.npm/_logs", min: 5 << 20, title: "npm debug logs",
                        reason: "npm debug log files; never read by npm after writing.", consequences: "Old npm error logs are no longer available."),
            simpleCache("pnpm-metadata", "~/Library/Caches/pnpm", title: "pnpm metadata cache",
                        reason: "pnpm's registry metadata cache (not the package store). Rebuilt on the next install.",
                        consequences: "Next pnpm install refreshes metadata from the registry.", owners: ["pnpm.cjs", "/pnpm "]),
            simpleCache("node-gyp", "~/Library/Caches/node-gyp", min: 10 << 20, title: "node-gyp headers cache",
                        reason: "Node.js headers downloaded by node-gyp for native addon builds; re-downloaded when needed.",
                        consequences: "The next native addon build downloads Node headers again."),
            simpleCache("typescript-cache", "~/Library/Caches/typescript", min: 10 << 20, title: "TypeScript typings cache",
                        reason: "Automatic type acquisition cache used by editors; rebuilt on demand.", consequences: "Editors re-download @types packages when needed."),
            simpleCache("yarn-cache", "~/Library/Caches/Yarn", title: "Yarn cache",
                        reason: "Yarn's global package cache (equivalent to `yarn cache clean`).", consequences: "Next yarn install re-downloads packages."),
            simpleCache("pip-cache", "~/Library/Caches/pip", title: "pip cache",
                        reason: "pip's wheel and HTTP cache (equivalent to `pip cache purge`).", consequences: "Next pip install re-downloads wheels."),
            simpleCache("pip-cache-xdg", "~/.cache/pip", title: "pip cache (~/.cache)",
                        reason: "pip's wheel and HTTP cache.", consequences: "Next pip install re-downloads wheels."),
            simpleCache("python-bytecode-cache", "~/Library/Caches/com.apple.python", min: 10 << 20, title: "Python bytecode cache",
                        reason: "Compiled .pyc files for the system Python, regenerated automatically on import.", consequences: "First imports are slightly slower once."),
            simpleCache("swiftpm-cache", "~/Library/Caches/org.swift.swiftpm", title: "SwiftPM cache",
                        reason: "Swift Package Manager repository and manifest cache; refetched on next resolve.", consequences: "Next package resolve re-clones dependencies."),
            simpleCache("xcode-deriveddata", "~/Library/Developer/Xcode/DerivedData", title: "Xcode DerivedData",
                        reason: "Xcode build products and indexes; rebuilt on next build.", consequences: "Next Xcode build and indexing are slower once.",
                        owners: ["/Xcode.app/"]),
            CleanupRule(id: "homebrew-cleanup", matcher: .path("~/Library/Caches/Homebrew"), minBytes: 50 << 20) { i in
                let brew = "/opt/homebrew/bin/brew"
                guard FileManager.default.isExecutableFile(atPath: brew) || Platform.isSandboxed else { return nil }
                guard Platform.canRunExternalTools else {
                    // The sandboxed edition cannot run Homebrew; give the exact command instead.
                    var r = review(i, "Homebrew cache and outdated downloads",
                                   "Homebrew's download cache and outdated versions. Homebrew must clean these itself so its own records stay consistent, and the App Store edition cannot run other programs.",
                                   "Run the command below in Terminal.", risk: .low)
                    r.suggestedCommand = "brew cleanup --prune=all"
                    return r
                }
                return i.make(title: "Homebrew cache and outdated downloads", tier: .low, risk: .low, confidence: .high,
                              action: .command(brew, ["cleanup", "--prune=all"], measuring: i.path),
                              reason: "Homebrew's documented cleanup: removes cached downloads and outdated versions of installed formulae/casks. Uses `brew cleanup` instead of deleting files so Homebrew's own bookkeeping stays consistent.",
                              consequences: "Old formula versions and cached bottles are removed; reinstalling an old version would require a download.",
                              dependencies: "Homebrew (\(brew)).",
                              owners: ["Library/Homebrew/brew.rb"],
                              notes: ["The estimate is refined from `brew cleanup -n --prune=all` (dry run)."])
            },
            CleanupRule(id: "clang-module-cache", matcher: .path(darwinUserDir(_CS_DARWIN_USER_CACHE_DIR) + "clang/ModuleCache"), minBytes: 50 << 20) { i in
                i.make(title: "Clang/Swift module cache", tier: .low, risk: .low, confidence: .high, action: .delete(i.path),
                       reason: "Precompiled module cache used by clang/swiftc; compilers regenerate it automatically.",
                       consequences: "The next Swift/C build recompiles system modules once (slower first build).",
                       owners: ["swift-frontend", "/clang"])
            },
            CleanupRule(id: "playwright-browser", matcher: .childrenOf("~/Library/Caches/ms-playwright"), minBytes: 50 << 20) { i in
                let recent = i.ageDays >= 0 && i.ageDays < 14
                return i.make(title: "Playwright browser build \(PathUtil.lastComponent(i.path))", tier: .conditional,
                              risk: recent ? .medium : .low, confidence: recent ? .medium : .high, action: .delete(i.path),
                              reason: "A browser binary downloaded by Playwright. Projects reinstall it with `npx playwright install` when they need it.",
                              consequences: "Playwright tests or scripts that use this browser revision must re-download it (~150–300 MB).",
                              owners: [i.path + "/"],
                              notes: recent ? ["Modified within the last 14 days — likely still in use by a project."] : [])
            },
        ]
    }

    // MARK: - App updater leftovers

    static func updaterLeftovers() -> [CleanupRule] {
        [
            CleanupRule(id: "sparkle-update", matcher: .glob("~/Library/Caches/*/org.sparkle-project.Sparkle/Installation/*"), minBytes: 50 << 20) { i in
                // ~/Library/Caches/<bundle-id>/org.sparkle-project.Sparkle/Installation/<random>
                let comps = i.path.split(separator: "/").map(String.init)
                guard let cachesIdx = comps.firstIndex(of: "Caches"), cachesIdx + 1 < comps.count else { return nil }
                let bundleID = comps[cachesIdx + 1]
                let installed = i.facts.installedApps[bundleID]
                let installedVersion = installed.flatMap { i.facts.appVersion(at: $0) }
                let staged = findApps(under: i.path, depth: 3).compactMap { i.facts.appVersion(at: $0) }.first
                let stale: Bool
                if let s = staged, let v = installedVersion { stale = compareVersions(s, v) <= 0 } else { stale = staged == nil }
                let appName = installed.map { PathUtil.lastComponent($0) } ?? bundleID
                if stale {
                    return i.make(title: "Stale \(appName) update download", tier: .low, risk: .low, confidence: staged == nil ? .medium : .high,
                                  action: .delete(i.path),
                                  reason: "Sparkle update payload whose version (\(staged ?? "unknown")) is not newer than the installed \(appName) (\(installedVersion ?? "not installed")). It was left behind after the update was applied.",
                                  consequences: "None for the installed app. The updater downloads future updates fresh.",
                                  notes: ["Staged version \(staged ?? "?") vs installed \(installedVersion ?? "?")."])
                }
                return i.make(title: "Pending \(appName) update (\(staged ?? "?"))", tier: .conditional, risk: .low, confidence: .high,
                              action: .delete(i.path),
                              reason: "Sparkle has downloaded \(appName) \(staged ?? "?") (installed: \(installedVersion ?? "?")) and will install it when the app quits. Deleting it cancels that pending install.",
                              consequences: "The app re-downloads the update later. Installing the update instead (quit and relaunch the app) also frees most of this space.",
                              owners: installed.map { [$0 + "/"] } ?? [])
            },
            CleanupRule(id: "squirrel-shipit", matcher: .glob("~/Library/Caches/*.ShipIt"), minBytes: 50 << 20) { i in
                let bundleID = String(PathUtil.lastComponent(i.path).dropLast(".ShipIt".count))
                let app = i.facts.installedApps[bundleID]
                let name = app.map { PathUtil.lastComponent($0) } ?? bundleID
                return i.make(title: "\(name) staged update (ShipIt)", tier: .conditional, risk: .low, confidence: .high, action: .delete(i.path),
                              reason: "Squirrel/ShipIt staging folder for a downloaded \(name) update that is applied on quit.",
                              consequences: "A pending update is cancelled and re-downloaded later. Quitting and relaunching \(name) applies it instead.",
                              owners: (app.map { [$0 + "/"] } ?? []) + ["ShipIt"])
            },
            CleanupRule(id: "google-updater-cache", matcher: .path("~/Library/Application Support/Google/GoogleUpdater/crx_cache"), minBytes: 50 << 20) { i in
                i.make(title: "Google Updater download cache", tier: .conditional, risk: .low, confidence: .high, action: .delete(i.path),
                       reason: "Cached Chrome update packages kept by GoogleUpdater for differential updates.",
                       consequences: "The next Chrome update downloads a full package; the cache regrows to a similar size after updates.",
                       owners: ["GoogleUpdater"])
            },
        ]
    }

    // MARK: - Chromium/Electron app caches

    static let chromiumCacheNames = ["Cache", "Code Cache", "GPUCache", "CachedData", "DawnGraphiteCache", "DawnWebGPUCache", "ShaderCache", "GrShaderCache", "CachedExtensionVSIXs"]
    /// App Support folder name -> app bundle names that own it.
    static let folderOwners: [String: [String]] = [
        "Code": ["Visual Studio Code"], "Code - Insiders": ["Visual Studio Code - Insiders"], "Codex": ["ChatGPT", "Codex"],
        "com.openai.chat": ["ChatGPT"], "discord": ["Discord"], "Slack": ["Slack"],
    ]

    static func appOwners(for supportPath: String) -> [String] {
        // supportPath = ~/Library/Application Support/<Folder>/...
        let comps = supportPath.split(separator: "/").map(String.init)
        guard let idx = comps.firstIndex(of: "Application Support"), idx + 1 < comps.count else { return [] }
        let folder = comps[idx + 1]
        return ([folder] + (folderOwners[folder] ?? [])).map { "/\($0).app/" }
    }

    static func appCaches() -> [CleanupRule] {
        var rules: [CleanupRule] = []
        for name in chromiumCacheNames {
            for pattern in ["~/Library/Application Support/*/\(name)", "~/Library/Application Support/*/Partitions/*/\(name)"] {
                rules.append(CleanupRule(id: "app-cache:\(name)", matcher: .glob(pattern), minBytes: 30 << 20) { i in
                    let comps = i.path.split(separator: "/").map(String.init)
                    let folder = comps.firstIndex(of: "Application Support").flatMap { $0 + 1 < comps.count ? comps[$0 + 1] : nil } ?? ""
                    let installed = ([folder] + (folderOwners[folder] ?? [])).flatMap { i.facts.installedApps(matching: $0) }
                    let owners = appOwners(for: i.path) + installed.map { $0 + "/" }
                    let app = installed.first.map { (PathUtil.lastComponent($0) as NSString).deletingPathExtension } ?? folder
                    guard !installed.isEmpty else {
                        // Owner not identified: cannot reliably tell whether it is running.
                        return i.make(title: "\(folder) \(name) (owning app not identified)", tier: .conditional, risk: .medium,
                                      confidence: .medium, action: .delete(i.path),
                                      reason: "Chromium/Electron \(name) in Application Support/\(folder). No installed app could be matched to this folder, so DiskLens cannot verify it is not in use.",
                                      consequences: "If the owning app is running, it may misbehave until restarted. Quit it first.",
                                      owners: owners, notes: ["Make sure the app that owns \(folder) is not running."])
                    }
                    return i.make(title: "\(app) \(name)", tier: .low, risk: .low, confidence: .high, action: .delete(i.path),
                                  reason: "Chromium/Electron \(name) of \(app): HTTP, compiled-code or GPU shader cache that the app rebuilds automatically.",
                                  consequences: "\(app) may start a little slower and re-download web assets once. No settings, sessions or history are stored here.",
                                  owners: owners,
                                  notes: ["Skipped automatically while \(app) is running — quit it first."])
                })
            }
        }
        return rules
    }

    // MARK: - Versioned tool installs (keep newest)

    static func versionedInstalls() -> [CleanupRule] {
        let globs = [
            "~/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/share/cursor-agent/versions/*",
            "~/.local/share/claude/versions/*",
            "~/.local/share/cursor-agent/versions/*",
        ]
        return globs.map { g in
            CleanupRule(id: "old-tool-version", matcher: .glob(g), minBytes: 50 << 20) { i in
                let versionsDir = PathUtil.parent(i.path)
                let siblings = ((try? FileManager.default.contentsOfDirectory(atPath: versionsDir)) ?? []).filter { !$0.hasPrefix(".") }
                guard let newest = siblings.max(by: { compareVersions($0, $1) < 0 }) else { return nil }
                let me = PathUtil.lastComponent(i.path)
                guard newest != me else { return nil }
                let tool = PathUtil.lastComponent(PathUtil.parent(versionsDir))
                // The version a launcher actually points to may not be the newest (rollback, stable
                // channel). Resolve the launchers in the matching .local/bin; keep whatever they use.
                let active = activeVersions(versionsDir: versionsDir)
                guard let active else {
                    return review(i, "Older \(tool) version \(me) (active version unknown)",
                                  "Could not determine which version the \(tool) launcher uses, so this is not offered for automatic removal.",
                                  "Remove it yourself only if \(tool) runs from a newer version.", risk: .medium)
                }
                guard !active.contains(me) else { return nil }
                return i.make(title: "Superseded version \(me) of \(tool)",
                              tier: .conditional, risk: .low, confidence: .high, action: .delete(i.path),
                              reason: "An older self-updating CLI build. The launcher uses \(active.sorted().joined(separator: ", ")) and the newest is \(newest); both are kept.",
                              consequences: "Rolling back to this exact version would require a re-download.",
                              owners: [i.path])
            }
        }
    }

    /// Version folder names that launchers (symlinks in the sibling .local/bin) resolve into, or nil
    /// if no launcher could be found.
    static func activeVersions(versionsDir: String) -> Set<String>? {
        // .../<root>/.local/share/<tool>/versions -> .../<root>/.local/bin
        let shareTool = PathUtil.parent(versionsDir)              // .../.local/share/<tool>
        let local = PathUtil.parent(PathUtil.parent(shareTool))   // .../.local
        let bin = local + "/bin"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: bin) else { return nil }
        var active = Set<String>()
        var sawLauncher = false
        for e in entries {
            guard let real = PathUtil.canonical(bin + "/" + e) else { continue }
            let canonVersions = PathUtil.canonical(versionsDir) ?? versionsDir
            if PathUtil.isStrictlyInside(real, canonVersions) {
                sawLauncher = true
                let rel = real.dropFirst(canonVersions.count + 1)
                if let first = rel.split(separator: "/").first { active.insert(String(first)) }
            }
        }
        return sawLauncher ? active : nil
    }

    // MARK: - Project build artifacts

    /// Locations where node_modules etc. belong to tools, not projects.
    static func isToolInstall(_ path: String, home: String) -> Bool {
        let toolRoots = ["/Library/", "/.cache/", "/.npm/", "/.nvm/", "/.vscode/", "/.cursor/", "/.codex/", "/.claude/projects",
                         "/.openclaw/", "/.dotnet/", "/.local/", "/.toolchain/", "/.Trash/", "/node_modules/"]
        let rel = path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
        return !path.hasPrefix(home + "/") || toolRoots.contains { rel.contains($0) }
    }


    static func projectArtifacts(home: String) -> [CleanupRule] {
        [
            CleanupRule(id: "node-modules", matcher: .directoryNamed(["node_modules"]), minBytes: 50 << 20) { i in
                let project = PathUtil.parent(i.path)
                guard !isToolInstall(i.path, home: home), i.parentMarkers.contains(.packageJSON) else { return nil }
                let lock = i.parentMarkers.lockfileName
                let agents = i.facts.launchAgentReferences(under: project)
                var notes: [String] = []
                if i.path.contains("/.claude/worktrees/") {
                    notes.append("Inside a Claude Code worktree (\(PathUtil.lastComponent(project))). The worktree itself may hold uncommitted work and is not touched.")
                }
                if i.markers.contains(.pnpmVirtualStore) {
                    notes.append("Installed by pnpm: files may be APFS clones/hard links of the pnpm store, so little space may be freed (see estimate).")
                }
                if let ignored = gitIgnored(i.path, in: project) { notes.append(ignored ? "Git-ignored (not part of the repository)." : "NOT git-ignored — check before removing.") }
                if !i.facts.launchAgentsReadable {
                    notes.append("Background services (LaunchAgents) could not be checked; make sure no service runs this project.")
                }
                if !agents.isEmpty {
                    return i.make(title: "node_modules of \(PathUtil.abbreviated(project, home: home)) (background service)", tier: .manualReview,
                                  risk: .high, confidence: .high, action: .review(i.path),
                                  reason: "Dependencies of a project started by a LaunchAgent (\(agents.joined(separator: ", "))). Removing them would break that background service until reinstalled.",
                                  consequences: "The service fails to start until `npm ci` is run.", notes: notes)
                }
                guard let lock else {
                    return i.make(title: "node_modules of \(PathUtil.abbreviated(project, home: home)) (no lockfile)", tier: .manualReview,
                                  risk: .medium, confidence: .medium, action: .review(i.path),
                                  reason: "Installed dependencies, but the project has no lockfile, so the exact versions cannot be restored reproducibly.",
                                  consequences: "A reinstall may resolve different dependency versions.", notes: notes)
                }
                let recent = i.ageDays >= 0 && i.ageDays < 7
                return i.make(title: "node_modules of \(PathUtil.abbreviated(project, home: home))", tier: .conditional,
                              risk: recent || !i.facts.launchAgentsReadable ? .medium : .low, confidence: .high, action: .delete(i.path),
                              reason: "Installed npm dependencies. The project has \(lock), so they can be restored exactly with `\(installCommand(lock))`.",
                              consequences: "The project will not build or run until dependencies are reinstalled (`\(installCommand(lock))` in \(PathUtil.abbreviated(project, home: home))).",
                              dependencies: "Lockfile \(lock) in the project folder.",
                              owners: [project + "/"],
                              notes: notes + (recent ? ["Modified within the last 7 days — an active project."] : []))
            },
            CleanupRule(id: "js-framework-cache", matcher: .directoryNamed([".next", ".turbo", ".parcel-cache", ".vite", ".svelte-kit", ".nuxt", ".angular", ".expo"]), minBytes: 20 << 20) { i in
                let project = PathUtil.parent(i.path)
                guard !isToolInstall(i.path, home: home), i.parentMarkers.contains(.packageJSON) else { return nil }
                return i.make(title: "\(PathUtil.lastComponent(i.path)) build cache of \(PathUtil.abbreviated(project, home: home))", tier: .low,
                              risk: .low, confidence: .high, action: .delete(i.path),
                              reason: "Framework build output/cache generated by the dev server or build; recreated by the next build.",
                              consequences: "The next dev-server start or build is slower once.", owners: [project + "/"])
            },
            CleanupRule(id: "js-build-output", matcher: .directoryNamed(["dist", "build", "out", "coverage", ".prerender"]), minBytes: 30 << 20) { i in
                let project = PathUtil.parent(i.path)
                guard !isToolInstall(i.path, home: home), i.parentMarkers.contains(.packageJSON) else { return nil }
                let ignored = gitIgnored(i.path, in: project)
                guard ignored != false else { return nil }   // tracked output is never a candidate
                return i.make(title: "\(PathUtil.lastComponent(i.path))/ output of \(PathUtil.abbreviated(project, home: home))", tier: .conditional,
                              risk: .low, confidence: .medium, action: .delete(i.path),
                              reason: "Generated build output next to package.json\(ignored == true ? " (git-ignored)" : "").",
                              consequences: "Rebuild with the project's build script before deploying or serving these files.", owners: [project + "/"])
            },
            CleanupRule(id: "dotnet-build-output", matcher: .directoryNamed(["bin", "obj", "TestResults"]), minBytes: 20 << 20) { i in
                let project = PathUtil.parent(i.path)
                guard i.parentMarkers.contains(.dotnetProject), !isToolInstall(i.path, home: home) else { return nil }
                return i.make(title: "\(PathUtil.lastComponent(i.path))/ of \(PathUtil.abbreviated(project, home: home))", tier: .conditional,
                              risk: .low, confidence: .high, action: .delete(i.path),
                              reason: ".NET build output next to a project file; `dotnet build` recreates it.",
                              consequences: "Next build/restore is slower once.", owners: [project + "/"])
            },
            CleanupRule(id: "python-venv", matcher: .directoryNamed([".venv", "venv", "env"]), minBytes: 50 << 20) { i in
                let project = PathUtil.parent(i.path)
                guard i.markers.contains(.pyvenvCfg), !isToolInstall(i.path, home: home) else { return nil }
                let manifest: String? = i.parentMarkers.contains(.pythonManifest) ? "the project's requirements/pyproject file" : nil
                guard let manifest else {
                    return i.make(title: "Python venv \(PathUtil.abbreviated(i.path, home: home)) (no requirements file)", tier: .manualReview,
                                  risk: .medium, confidence: .medium, action: .review(i.path),
                                  reason: "Virtual environment without a requirements/lock file next to it, so its packages cannot be restored reproducibly.",
                                  consequences: "Packages would have to be reinstalled by hand.")
                }
                return i.make(title: "Python venv of \(PathUtil.abbreviated(project, home: home))", tier: .conditional, risk: .low, confidence: .medium,
                              action: .delete(i.path),
                              reason: "Python virtual environment; recreate with `python3 -m venv \(PathUtil.lastComponent(i.path))` and install from \(manifest).",
                              consequences: "Scripts using this venv fail until it is recreated.", owners: [i.path + "/"])
            },
            CleanupRule(id: "python-tool-cache", matcher: .directoryNamed(["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox"]), minBytes: 20 << 20) { i in
                guard !isToolInstall(i.path, home: home) else { return nil }
                return i.make(title: "\(PathUtil.lastComponent(i.path)) in \(PathUtil.abbreviated(PathUtil.parent(i.path), home: home))", tier: .low, risk: .low,
                              confidence: .high, action: .delete(i.path),
                              reason: "Python bytecode/tool cache regenerated automatically.", consequences: "Slightly slower first run.")
            },
            CleanupRule(id: "project-tool-cache", matcher: .directoryNamed([".cache"]), minBytes: 50 << 20) { i in
                let project = PathUtil.parent(i.path)
                guard i.path.hasPrefix(home + "/"), PathUtil.parent(i.path) != home, !isToolInstall(i.path, home: home),
                      !i.parentMarkers.isDisjoint(with: [.packageJSON, .pythonManifest]) else { return nil }
                return i.make(title: ".cache of \(PathUtil.abbreviated(project, home: home))", tier: .conditional, risk: .low, confidence: .medium,
                              action: .delete(i.path),
                              reason: "Project-local tool cache (build/pipeline cache) next to a project manifest.",
                              consequences: "The project's tools rebuild or re-download cached data on the next run.", owners: [project + "/"])
            },
            CleanupRule(id: "vendored-toolchain", matcher: .directoryNamed([".toolchain"]), minBytes: 200 << 20) { i in
                let project = PathUtil.parent(i.path)
                guard i.path.hasPrefix(home + "/") else { return nil }
                let ignored = gitIgnored(i.path, in: project)
                return i.make(title: "Project-local toolchain in \(PathUtil.abbreviated(project, home: home))", tier: .conditional, risk: .medium,
                              confidence: .medium, action: .delete(i.path),
                              reason: "A toolchain (e.g. emsdk) installed into the project by a setup script\(ignored == true ? "; git-ignored" : "").",
                              consequences: "Builds that need it fail until the project's toolchain setup script is re-run (large download).",
                              owners: [i.path + "/"])
            },
            CleanupRule(id: "chromium-profile-cache", matcher: .directoryNamed(["Cache", "Code Cache", "GPUCache"]), minBytes: 50 << 20) { i in
                let profile = PathUtil.parent(i.path)
                guard i.path.hasPrefix(home + "/"), !i.path.hasPrefix(home + "/Library/"),
                      i.parentMarkers.contains(.chromiumProfile) else { return nil }
                let userData = PathUtil.parent(profile)
                return i.make(title: "Browser-automation profile \(PathUtil.lastComponent(i.path)) (\(PathUtil.abbreviated(userData, home: home)))",
                              tier: .conditional, risk: .low, confidence: .high, action: .delete(i.path),
                              reason: "Chromium HTTP/code cache inside a browser profile used by a project (e.g. Playwright/Puppeteer --user-data-dir). Cookies and logins live elsewhere in the profile and are untouched.",
                              consequences: "Pages re-download assets on the next automated run.",
                              owners: [userData])
            },
        ]
    }

    static func installCommand(_ lock: String) -> String {
        switch lock {
        case "pnpm-lock.yaml": return "pnpm install --frozen-lockfile"
        case "yarn.lock": return "yarn install --frozen-lockfile"
        case "bun.lockb", "bun.lock": return "bun install --frozen-lockfile"
        default: return "npm ci"
        }
    }

    // MARK: - AI & developer tool data

    static func aiToolData() -> [CleanupRule] {
        [
            CleanupRule(id: "codex-runtimes", matcher: .path("~/.cache/codex-runtimes"), minBytes: 100 << 20) { i in
                i.make(title: "Codex downloaded runtimes", tier: .conditional, risk: .medium, confidence: .medium, action: .delete(i.path),
                       reason: "Runtime bundles (Node/Python environments) that the Codex app downloads on demand.",
                       consequences: "Codex re-downloads the runtimes the next time a task needs them.",
                       owners: ["/ChatGPT.app/", "/Codex.app/", "codex-runtimes"])
            },
            CleanupRule(id: "tool-logs", matcher: .glob("~/.*/logs"), minBytes: 50 << 20) { i in
                // Explicit allowlist: a wildcard would also match ~/.Trash/logs (user data) or ~/.git/logs.
                let toolDirs: Set<String> = [".openclaw", ".codex", ".cursor", ".copilot", ".gemini", ".continue", ".aider", ".ollama", ".lmstudio"]
                let dotDir = PathUtil.lastComponent(PathUtil.parent(i.path))
                guard toolDirs.contains(dotDir), PathUtil.parent(PathUtil.parent(i.path)) == i.facts.home else { return nil }
                let tool = String(dotDir.dropFirst())
                return i.make(title: "\(tool) logs", tier: .conditional, risk: .low, confidence: .medium, action: .delete(i.path),
                              reason: "Log files written by \(tool). They are diagnostic output, not configuration or history.",
                              consequences: "Past \(tool) logs are no longer available for troubleshooting.",
                              owners: ["/." + tool + "/", tool + " "])
            },
            CleanupRule(id: "codex-tmp", matcher: .path("~/.codex/.tmp"), minBytes: 50 << 20) { i in
                i.make(title: "Codex temporary files", tier: .conditional, risk: .low, confidence: .medium, action: .delete(i.path),
                       reason: "Temporary working files of the Codex CLI.", consequences: "None expected when Codex is not running.",
                       owners: ["codex", "/ChatGPT.app/"])
            },
        ]
    }

    // MARK: - Manual review only (tier 3 — never executed)

    static func review(_ i: RuleInput, _ title: String, _ reason: String, _ consequences: String,
                       risk: RiskLevel = .high, elevation: Bool = false, notes: [String] = []) -> Recommendation {
        i.make(title: title, tier: .manualReview, risk: risk, confidence: .high, action: .review(i.path),
               reason: reason, consequences: consequences, notes: notes, requiresElevation: elevation)
    }

    static func manualReview(home: String) -> [CleanupRule] {
        [
            CleanupRule(id: "vm-disk", matcher: .path("~/.colima"), minBytes: 500 << 20) { i in
                var r = review(i, "Colima/Docker VM disks",
                       "Virtual-machine disks holding Docker images, containers, build cache AND volumes (persistent data). The data disk is sparse, so its logical size is much larger than what it occupies.",
                       "Never delete the files directly. Start Colima, inspect `docker system df`, prune selectively (`docker image prune -a`, `docker builder prune`), then `colima ssh -- sudo fstrim -av` to return freed blocks to macOS. `colima delete` removes everything including volumes.")
                r.suggestedCommand = "colima start && docker system df"
                return r
            },
            CleanupRule(id: "docker-desktop-vm", matcher: .path("~/Library/Containers/com.docker.docker"), minBytes: 500 << 20) { i in
                review(i, "Docker Desktop VM data", "Docker Desktop's VM disk with images, containers and volumes.",
                       "Use Docker Desktop → Troubleshoot → Clean/Purge data, or `docker system prune` for unused objects.")
            },
            CleanupRule(id: "claude-vm-bundle", matcher: .path("~/Library/Application Support/Claude/vm_bundles"), minBytes: 500 << 20) { i in
                review(i, "Claude desktop VM bundle",
                       "Disk images for the Claude desktop app's sandboxed VM (root filesystem and session data). Managed by the app; contents include session state.",
                       "Deleting it would force a large re-download and may discard VM session data. Manage it from within the Claude app.")
            },
            CleanupRule(id: "cloud-storage", matcher: .childrenOf("~/Library/CloudStorage"), minBytes: 500 << 20) { i in
                review(i, "Locally downloaded cloud files: \(PathUtil.lastComponent(i.path))",
                       "Files from a cloud-storage provider that are downloaded to this Mac. Deleting here would delete them from the cloud too.",
                       "Use Finder → right-click → \"Remove Download\" to free local space while keeping the cloud copy.")
            },
            CleanupRule(id: "dotnet-superseded-preview-sdk", matcher: .childrenOf("~/.dotnet/sdk"), minBytes: 100 << 20) { i in
                let ver = PathUtil.lastComponent(i.path)
                guard ver.contains("-preview") || ver.contains("-rc") else { return nil }
                let major = ver.split(separator: ".").first.map(String.init) ?? ""
                let siblings = (try? FileManager.default.contentsOfDirectory(atPath: PathUtil.parent(i.path))) ?? []
                guard let newer = siblings.filter({ $0 != ver && $0.hasPrefix(major + ".") && compareVersions($0, ver) > 0 })
                        .max(by: { compareVersions($0, $1) < 0 }) else { return nil }
                return review(i, "Superseded .NET preview SDK \(ver)",
                              "A newer SDK of the same major version (\(newer)) is installed; projects without a global.json use the newest SDK. The old preview's runtimes, templates and workload packs also remain on disk (often 1 GB+ more than this folder).",
                              "Check that no global.json pins \(ver). Then remove ~/.dotnet/sdk/\(ver) and the matching shared/*/ and templates/ runtime folders yourself, and run `~/.dotnet/dotnet workload clean` to drop its orphaned workload packs.",
                              risk: .medium)
            },
            CleanupRule(id: "global-npm-package", matcher: .childrenOf("/opt/homebrew/lib/node_modules"), minBytes: 100 << 20) { i in
                let name = PathUtil.lastComponent(i.path)
                return review(i, "Global npm package \(name)",
                              "Globally installed npm CLI. Outside DiskLens's cleanup scope (Homebrew prefix).",
                              "If unused, remove with `npm uninstall -g \(name)`.", risk: .medium,
                              notes: i.facts.isRunning(hints: [i.path + "/"]).isEmpty ? [] : ["Currently running."])
            },
            CleanupRule(id: "rarely-used-app", matcher: .childrenOf("/Applications"), minBytes: 150 << 20) { i in
                guard i.path.hasSuffix(".app"), i.facts.isRunning(hints: [i.path + "/"]).isEmpty else { return nil }
                let lastUsed = spotlightDate(i.path, "kMDItemLastUsedDate")
                let days = lastUsed.map { Int(i.facts.now.timeIntervalSince($0) / 86_400) }
                guard days == nil || days! > 45 else { return nil }
                // Never-launched but recently installed apps are not "rarely used". Use the bundle's
                // birth time: Spotlight's kMDItemDateAdded is reset when macOS upgrades re-register apps.
                var bst = stat()
                if lastUsed == nil, lstat(i.path, &bst) == 0,
                   i.facts.now.timeIntervalSince1970 - Double(bst.st_birthtimespec.tv_sec) < 30 * 86_400 { return nil }
                var st = stat()
                let rootOwned = lstat(i.path, &st) == 0 && st.st_uid == 0
                return review(i, "Rarely used app: \(PathUtil.lastComponent(i.path))",
                              days.map { "Last opened \($0) days ago (Spotlight)." } ?? "No recorded launch (Spotlight).",
                              "Delete from Launchpad or Finder if you no longer need it; App Store apps can be re-downloaded from Purchased. Its data in ~/Library is not removed by deleting the app.",
                              risk: .medium, elevation: rootOwned)
            },
            CleanupRule(id: "installer-download", matcher: .filesUnder("~/Downloads", extensions: ["dmg", "pkg", "mpkg", "xip", "iso", "zip"]), minBytes: 50 << 20) { i in
                let stem = (PathUtil.lastComponent(i.path) as NSString).deletingPathExtension.lowercased()
                let installed = i.facts.installedApps.values.first { app in
                    let n = (PathUtil.lastComponent(app) as NSString).deletingPathExtension.lowercased()
                    return n.count >= 4 && (stem.hasPrefix(n) || stem.hasPrefix(n.replacingOccurrences(of: " ", with: "")) || stem.hasPrefix(n.replacingOccurrences(of: " ", with: "-")))
                }
                return review(i, "Installer/archive in Downloads: \(PathUtil.lastComponent(i.path))",
                              installed.map { "Installer for an app that is already installed (\(PathUtil.lastComponent($0)))." } ?? "Downloaded installer or archive.",
                              "Personal download — review and delete it yourself if no longer needed.", risk: .medium)
            },
            CleanupRule(id: "backup-folder", matcher: .directoryNamePattern(["*backup*", "*Backup*", "*backups*", "*Backups*"]), minBytes: 200 << 20) { i in
                guard i.path.hasPrefix(home + "/"), !i.path.hasPrefix(home + "/Library/") else { return nil }
                return review(i, "Backup folder \(PathUtil.abbreviated(i.path, home: home))",
                              "Backups are user data. Older backups may be redundant, but only you can decide which to keep.",
                              "Review the dates and keep at least the most recent good backup.", risk: .high)
            },
            CleanupRule(id: "large-git-history", matcher: .directoryNamed([".git"]), minBytes: 500 << 20) { i in
                review(i, "Large Git history: \(PathUtil.abbreviated(PathUtil.parent(i.path), home: home))",
                       "Repository history (packfiles). `git gc` only removes unreachable/loose objects; large blobs committed in history can only be removed by rewriting history.",
                       "Never removed automatically. Inspect with `git count-objects -vH`.")
            },
            CleanupRule(id: "large-file", matcher: .largeFiles(minBytes: 1 << 30, under: home), minBytes: 1 << 30) { i in
                review(i, "Large file \(PathUtil.abbreviated(i.path, home: home))",
                       "A single file of \(ByteFormat.string(i.node.allocated)) on disk\(i.node.flags.contains(.sparse) ? " (sparse: logical \(ByteFormat.string(i.node.logical)))" : "").",
                       "Review whether you still need it.", risk: .high)
            },
        ]
    }

    // MARK: - Helpers

    static func darwinUserDir(_ name: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(name, &buf, buf.count)
        guard n > 0 else { return "/nonexistent/" }
        let s = String(cBuffer: buf)
        return (PathUtil.canonical(s) ?? s).hasSuffix("/") ? (PathUtil.canonical(s) ?? s) : (PathUtil.canonical(s) ?? s) + "/"
    }

    /// Per-user temp and cache directories (owned by the user) where cleanup is also allowed.
    public static func userTempRoots() -> [String] {
        [darwinUserDir(_CS_DARWIN_USER_CACHE_DIR), darwinUserDir(_CS_DARWIN_USER_TEMP_DIR)]
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { $0 != "/nonexistent" }
    }

    static func findApps(under path: String, depth: Int) -> [String] {
        guard depth > 0, let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        var out: [String] = []
        for it in items {
            let p = path + "/" + it
            if it.hasSuffix(".app") { out.append(p) } else {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                    out += findApps(under: p, depth: depth - 1)
                }
            }
        }
        return out
    }

    /// Numeric-aware version comparison ("26.1007.21159" vs "26.1005.1"; "2026.10.01-e373342").
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        let r = a.compare(b, options: [.numeric])
        return r == .orderedAscending ? -1 : (r == .orderedDescending ? 1 : 0)
    }

    /// true/false if git answered, nil if not a repository or git unavailable.
    static func gitIgnored(_ path: String, in repoDir: String) -> Bool? {
        guard Platform.canRunExternalTools else { return nil }   // unknown in the sandboxed edition
        guard let o = try? ProcessRunner.run("/usr/bin/git", ["-C", repoDir, "--no-optional-locks", "check-ignore", "-q", path], timeout: 10) else { return nil }
        switch o.status {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    static func spotlightDate(_ appPath: String, _ attribute: String) -> Date? {
        Platform.spotlightDate(appPath, attribute: attribute as CFString)
    }

    // MARK: - Command estimates & reporting

    /// Replaces the allocated-size estimate of command-based items with the tool's own dry-run figure.
    public static func refineCommandEstimates(_ recs: [Recommendation]) async -> [Recommendation] {
        var out = recs
        guard Platform.canRunExternalTools else { return out }
        for (idx, r) in recs.enumerated() where r.ruleID == "homebrew-cleanup" {
            guard let exe = r.action.executable,
                  let o = try? ProcessRunner.run(exe, ["cleanup", "-n", "--prune=all"], timeout: 120), o.status == 0 else { continue }
            if let bytes = parseBrewFreed(o.stdout + o.stderr) {
                // brew also removes outdated versions under /opt/homebrew, outside the cache folder.
                out[idx].detectedAllocated = max(out[idx].detectedAllocated, bytes)
                out[idx].estimatedReclaimable = bytes
                out[idx].reclaimMethod = "`brew cleanup -n --prune=all` dry-run report"
                out[idx].notes.append("Homebrew dry run reports approximately \(ByteFormat.string(bytes)) would be freed.")
            }
        }
        return out
    }

    /// Parses "This operation would free approximately 400.2MB of disk space."
    public static func parseBrewFreed(_ text: String) -> Int64? {
        guard let r = text.range(of: #"would free approximately ([0-9.]+)\s*([KMGT]?B)"#, options: .regularExpression) else { return nil }
        let m = String(text[r])
        let parts = m.replacingOccurrences(of: "would free approximately ", with: "")
        let num = Double(parts.prefix { "0123456789.".contains($0) }) ?? 0
        let unit = parts.drop { "0123456789. ".contains($0) }
        let mult: Double = unit.hasPrefix("K") ? 1e3 : unit.hasPrefix("M") ? 1e6 : unit.hasPrefix("G") ? 1e9 : unit.hasPrefix("T") ? 1e12 : 1
        return Int64(num * mult)
    }

    public static func markdown(_ recs: [Recommendation], scan: ScanResult) -> String {
        var s = "# DiskLens cleanup plan\n\nScan \(scan.manifest.scanID) · \(scan.manifest.finishedAt)\n\n"
        for tier in CleanupTier.allCases {
            let items = recs.filter { $0.tier == tier }.sorted { $0.estimatedReclaimable > $1.estimatedReclaimable }
            let total = items.reduce(Int64(0)) { $0 + $1.estimatedReclaimable }
            s += "## \(tier.label) — \(items.count) items, est. \(ByteFormat.gb(total))\n\n"
            s += "| Est. reclaim | On disk | Risk | Conf. | Item | Action | In use |\n|---:|---:|---|---|---|---|---|\n"
            for r in items {
                s += "| \(ByteFormat.gb(r.estimatedReclaimable)) | \(ByteFormat.gb(r.detectedAllocated)) | \(r.risk.rawValue) | \(r.confidence.rawValue) | \(r.title.replacingOccurrences(of: "|", with: "/")) | `\(r.action.displayString.replacingOccurrences(of: "|", with: "/"))` | \(r.inUseBy.joined(separator: ", ")) |\n"
            }
            s += "\n"
        }
        return s
    }
}
