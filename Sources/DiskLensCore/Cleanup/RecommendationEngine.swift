import Foundation

/// Facts about the machine that rules use to judge safety. Probed once per analysis.
public struct EnvironmentFacts: Sendable {
    public var home: String
    public var running: [RunningProcess]
    /// bundle identifier -> application path, from /Applications and ~/Applications Info.plists.
    public var installedApps: [String: String]
    /// LaunchAgent label -> paths referenced by its Program/ProgramArguments/WorkingDirectory.
    /// (EnvironmentVariables are deliberately never read: they can hold secrets.)
    public var launchAgents: [String: [String]]
    /// False when ~/Library/LaunchAgents exists but could not be read (e.g. not granted).
    public var launchAgentsReadable: Bool = true
    /// False when the process list could not be read; in-use status is then unknown.
    public var processListAvailable: Bool
    /// False when only GUI apps are visible (sandbox); command-line tools cannot be checked.
    public var processListComplete: Bool
    public var now: Date

    public init(home: String, running: [RunningProcess], installedApps: [String: String],
                launchAgents: [String: [String]] = [:], processListAvailable: Bool = true,
                processListComplete: Bool = true, now: Date = Date()) {
        self.home = home
        self.running = running
        self.installedApps = installedApps
        self.launchAgents = launchAgents
        self.processListAvailable = processListAvailable
        self.processListComplete = processListComplete
        self.now = now
    }

    public static func probe(home: String = Platform.realHome) -> EnvironmentFacts {
        let snap = ProcessProbe.snapshot()
        let agents = userLaunchAgents(home: home)
        var facts = EnvironmentFacts(home: home, running: snap?.processes ?? [],
                                     installedApps: installedApplications(home: home),
                                     launchAgents: agents ?? [:], processListAvailable: snap != nil,
                                     processListComplete: snap?.complete ?? false)
        facts.launchAgentsReadable = agents != nil
        return facts
    }

    /// nil when the folder exists but cannot be read (unknown), [:] when there are no agents.
    public static func userLaunchAgents(home: String) -> [String: [String]]? {
        let dir = home + "/Library/LaunchAgents"
        let files: [String]
        do { files = try FileManager.default.contentsOfDirectory(atPath: dir) } catch {
            let code = (error as NSError).underlyingErrors.first.map { ($0 as NSError).code } ?? (error as NSError).code
            return (code == ENOENT || (error as NSError).code == NSFileReadNoSuchFileError) ? [:] : nil
        }
        var out: [String: [String]] = [:]
        for f in files where f.hasSuffix(".plist") {
            guard let d = NSDictionary(contentsOfFile: dir + "/" + f) else { continue }
            var refs: [String] = []
            if let p = d["Program"] as? String { refs.append(p) }
            if let a = d["ProgramArguments"] as? [String] { refs += a.filter { $0.hasPrefix("/") || $0.hasPrefix("~") } }
            if let w = d["WorkingDirectory"] as? String { refs.append(w) }
            out[(d["Label"] as? String) ?? f] = refs.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        }
        return out
    }

    /// Labels of LaunchAgents that reference `dir` or anything inside it.
    public func launchAgentReferences(under dir: String) -> [String] {
        launchAgents.filter { $0.value.contains { PathUtil.isSameOrInside($0, dir) } }.map(\.key).sorted()
    }

    /// Reads CFBundleIdentifier/CFBundleShortVersionString of installed apps (Info.plist metadata only).
    public static func installedApplications(home: String) -> [String: String] {
        var map: [String: String] = [:]
        for dir in ["/Applications", "/Applications/Utilities", home + "/Applications"] {
            guard let apps = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for a in apps where a.hasSuffix(".app") {
                let p = dir + "/" + a
                if let info = NSDictionary(contentsOfFile: p + "/Contents/Info.plist"),
                   let bid = info["CFBundleIdentifier"] as? String {
                    map[bid] = p
                }
            }
        }
        return map
    }

    public func appVersion(at appPath: String) -> String? {
        (NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String)
    }

    public func isRunning(hints: [String]) -> [String] {
        if !processListAvailable && !hints.isEmpty { return [ProcessProbe.unavailableMarker] }
        let hits = ProcessProbe.matches(hints: hints, running: running)
        // With only LaunchServices apps visible, "not found" is not proof of "not running"
        // (helpers, agents and command-line tools are invisible): report it as unverified.
        if hits.isEmpty && !processListComplete && !hints.isEmpty {
            return [ProcessProbe.unverifiedMarker]
        }
        return hits
    }

    /// Installed app paths whose bundle name or identifier matches `name` case-insensitively.
    public func installedApps(matching name: String) -> [String] {
        let n = name.lowercased()
        return installedApps.compactMap { bid, path in
            let app = (PathUtil.lastComponent(path) as NSString).deletingPathExtension.lowercased()
            return app == n || bid.lowercased() == n || bid.lowercased().hasSuffix("." + n) ? path : nil
        }
    }
}

/// A candidate produced by a rule before reclaim estimation.
public struct RuleMatch: Sendable {
    public var nodeID: Int32
    public var recommendation: Recommendation
}

/// A cleanup rule: where to look and how to judge what it finds.
public struct CleanupRule: Sendable {
    public enum Matcher: Sendable {
        /// Exact path ("~" = home).
        case path(String)
        /// Glob over path components; "*" matches exactly one component.
        case glob(String)
        /// Every directory with one of these names anywhere under the scan (not inside another match).
        case directoryNamed(Set<String>)
        /// Each immediate child of `parent` (files or directories).
        case childrenOf(String)
        /// Files under `parent` (any depth) with one of these extensions.
        case filesUnder(String, extensions: Set<String>)
        /// Directories whose name matches one of these globs ("*backup*").
        case directoryNamePattern([String])
        /// Individual files of at least `minBytes` under `under`.
        case largeFiles(minBytes: Int64, under: String)
    }

    public var id: String
    public var matcher: Matcher
    public var minBytes: Int64
    /// Judges a matched node. Returns nil to reject the match (e.g. bin/ without a .csproj).
    public var judge: @Sendable (RuleInput) -> Recommendation?

    public init(id: String, matcher: Matcher, minBytes: Int64, judge: @escaping @Sendable (RuleInput) -> Recommendation?) {
        self.id = id
        self.matcher = matcher
        self.minBytes = minBytes
        self.judge = judge
    }
}

public struct RuleInput: Sendable {
    public var ruleID: String
    public var path: String
    public var node: ScanNode
    public var facts: EnvironmentFacts
    /// Markers (package.json, lockfiles, .csproj …) of the node itself and of its parent folder,
    /// recorded during the scan — rules use these instead of touching the disk again.
    public var markers: ProjectMarkers = []
    public var parentMarkers: ProjectMarkers = []
    public var childNames: Set<String> = []

    /// Builds a recommendation pre-filled with the node's measurements.
    public func make(title: String, tier: CleanupTier, risk: RiskLevel, confidence: Confidence, action: CleanupAction,
                     reason: String, consequences: String, dependencies: String = "None.",
                     verification: String? = nil, owners: [String] = [], notes: [String] = [],
                     requiresElevation: Bool = false) -> Recommendation {
        let inUse = facts.isRunning(hints: owners)
        return Recommendation(
            id: "\(ruleID):\(path)", ruleID: ruleID, title: title, targetPath: path, category: node.category,
            detectedAllocated: node.allocated, detectedLogical: node.logical, fileCount: node.fileCount,
            estimatedReclaimable: tier == .manualReview ? node.allocated : node.allocated,
            reclaimMethod: "allocated size (upper bound; refined by APFS private-size walk)",
            reason: reason, confidence: confidence, risk: risk, tier: tier, dependencies: dependencies,
            consequences: consequences, action: action,
            verification: verification ?? defaultVerification(action),
            requiresElevation: requiresElevation, inUseBy: inUse, ownerProcessHints: owners,
            analysisComplete: !node.flags.contains(.partial) && !node.flags.contains(.unreadable),
            notes: notes + (node.flags.contains(.partial) ? ["Part of this folder could not be read; size may be understated."] : []),
            expectedDevice: node.device, expectedInode: node.inode,
            lastModified: node.mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(node.mtime)) : nil)
    }

    func defaultVerification(_ a: CleanupAction) -> String {
        switch a.kind {
        case .deletePermanently: return "Confirm the path no longer exists (lstat → ENOENT) and compare free space before/after (statfs)."
        case .moveToTrash: return "Confirm the path no longer exists at its original location; space is released only after emptying the Trash."
        case .runCommand: return "Check the command's exit status and re-measure \(a.measuredPath ?? "the target") before/after; compare free space."
        case .manualReview: return "Not applicable — no automatic action."
        }
    }

    public var exists: (String) -> Bool { { FileManager.default.fileExists(atPath: $0) } }
    public func sibling(_ name: String) -> String { PathUtil.parent(path) + "/" + name }
    public func child(_ name: String) -> String { path + "/" + name }
    public var ageDays: Int { node.mtime > 0 ? Int(facts.now.timeIntervalSince1970 - Double(node.mtime)) / 86_400 : -1 }
}

public struct AnalysisResult: Sendable {
    public var recommendations: [Recommendation]
    /// Rules that matched nothing or were skipped, for transparency.
    public var notes: [String]
}

public enum RecommendationEngine {
    /// Matches rules against the scan tree. Matches never overlap: once a node is claimed, its
    /// ancestors and descendants cannot be claimed by later rules (rules are ordered by priority).
    public static func analyze(tree: ScanTree, rules: [CleanupRule], facts: EnvironmentFacts) -> AnalysisResult {
        var claimed = Set<Int32>()
        var hasClaimedDescendant = Set<Int32>()
        var recs: [Recommendation] = []
        var notes: [String] = []

        func canClaim(_ id: Int32) -> Bool {
            if claimed.contains(id) || hasClaimedDescendant.contains(id) { return false }
            var cur = tree.nodes[Int(id)].parent
            while cur > 0 {
                if claimed.contains(cur) { return false }
                cur = tree.nodes[Int(cur)].parent
            }
            return true
        }
        func claim(_ id: Int32) {
            claimed.insert(id)
            var cur = tree.nodes[Int(id)].parent
            while cur > 0 { hasClaimedDescendant.insert(cur); cur = tree.nodes[Int(cur)].parent }
        }

        for rule in rules {
            let ids = candidates(for: rule.matcher, tree: tree, home: facts.home)
            var matched = 0
            for id in ids {
                let n = tree.nodes[Int(id)]
                guard !n.isAggregate, n.allocated >= rule.minBytes, canClaim(id) else { continue }
                var input = RuleInput(ruleID: rule.id, path: tree.path(of: id), node: n, facts: facts)
                input.markers = n.markers
                input.parentMarkers = n.parent > 0 ? tree.nodes[Int(n.parent)].markers : []
                input.childNames = Set(n.children.lazy.map { tree.nodes[Int($0)] }.filter { !$0.isAggregate }.map(\.name))
                guard var rec = rule.judge(input) else { continue }
                rec.estimatedReclaimable = min(rec.estimatedReclaimable, rec.detectedAllocated)
                claim(id)
                recs.append(rec)
                matched += 1
            }
            if matched == 0 { notes.append("Rule \(rule.id): no qualifying matches.") }
        }
        recs.sort { ($0.tier, -$0.estimatedReclaimable) < ($1.tier, -$1.estimatedReclaimable) }
        return AnalysisResult(recommendations: recs, notes: notes)
    }

    static func expand(_ p: String, home: String) -> String {
        p == "~" ? home : (p.hasPrefix("~/") ? home + p.dropFirst(1) : p)
    }

    static func candidates(for m: CleanupRule.Matcher, tree: ScanTree, home: String) -> [Int32] {
        switch m {
        case .path(let p):
            return tree.find(path: expand(p, home: home)).map { [$0] } ?? []
        case .glob(let g):
            let full = expand(g, home: home)
            let comps = full.split(separator: "/").map(String.init)
            // Find the longest literal prefix that exists, then expand wildcards.
            var prefix: [String] = []
            for c in comps { if c.contains("*") { break }; prefix.append(c) }
            guard let start = tree.find(path: "/" + prefix.joined(separator: "/")) else { return [] }
            var frontier = [start]
            for c in comps.dropFirst(prefix.count) {
                var next: [Int32] = []
                for f in frontier {
                    for ch in tree.nodes[Int(f)].children {
                        let name = tree.nodes[Int(ch)].name
                        if !tree.nodes[Int(ch)].isAggregate && globMatch(c, name) { next.append(ch) }
                    }
                }
                frontier = next
            }
            return frontier
        case .directoryNamed(let names):
            var out: [Int32] = []
            tree.walk { id, n in
                if n.isDirectory && names.contains(n.name) && id != ScanTree.root { out.append(id); return false }
                return true
            }
            return out.sorted { tree.nodes[Int($0)].allocated > tree.nodes[Int($1)].allocated }
        case .childrenOf(let p):
            guard let id = tree.find(path: expand(p, home: home)) else { return [] }
            return tree.sortedChildren(of: id).filter { !tree.nodes[Int($0)].isAggregate }
        case .directoryNamePattern(let patterns):
            var out: [Int32] = []
            tree.walk { id, n in
                if id != ScanTree.root && n.isDirectory && !n.isAggregate && patterns.contains(where: { globMatch($0, n.name) }) {
                    out.append(id); return false
                }
                return true
            }
            return out.sorted { tree.nodes[Int($0)].allocated > tree.nodes[Int($1)].allocated }
        case .largeFiles(let minBytes, let under):
            guard let id = tree.find(path: expand(under, home: home)) else { return [] }
            var out: [Int32] = []
            tree.walk(from: id) { cid, n in
                if n.isDirectory { return n.allocated >= minBytes }
                if !n.isAggregate && n.allocated >= minBytes { out.append(cid) }
                return false
            }
            return out.sorted { tree.nodes[Int($0)].allocated > tree.nodes[Int($1)].allocated }
        case .filesUnder(let p, let exts):
            guard let id = tree.find(path: expand(p, home: home)) else { return [] }
            var out: [Int32] = []
            tree.walk(from: id) { cid, n in
                if !n.isDirectory && !n.isAggregate && exts.contains((n.name as NSString).pathExtension.lowercased()) { out.append(cid) }
                return !n.flags.contains(.package)
            }
            return out.sorted { tree.nodes[Int($0)].allocated > tree.nodes[Int($1)].allocated }
        }
    }

    /// Minimal glob: "*" matches any run of characters within one component.
    static func globMatch(_ pattern: String, _ name: String) -> Bool {
        if pattern == "*" { return true }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 { return pattern == name }
        var rest = Substring(name)
        guard rest.hasPrefix(parts[0]) else { return false }
        rest = rest.dropFirst(parts[0].count)
        for (i, part) in parts.enumerated().dropFirst() {
            if i == parts.count - 1 { return part.isEmpty || rest.hasSuffix(part) }
            guard let r = rest.range(of: part) else { return false }
            rest = rest[r.upperBound...]
        }
        return true
    }

    /// Refines reclaimable estimates with the APFS private-size walk for actionable items.
    /// Tier-3 items keep allocated size (they are never executed automatically).
    public static func refineEstimates(_ recs: [Recommendation], maxConcurrent: Int = 4,
                                       isCancelled: @escaping @Sendable () -> Bool = { false },
                                       progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [Recommendation] {
        var out = recs
        let indices = recs.indices.filter {
            let k = recs[$0].action.kind
            // Duplicate items already carry exact per-copy estimates (the folder also holds originals).
            return (k == .deletePermanently || k == .moveToTrash || k == .manualReview) && recs[$0].fileCount < 400_000
                && recs[$0].ruleID != "duplicates"
        }
        await withTaskGroup(of: (Int, ReclaimEstimate).self) { group in
            var next = 0
            var done = 0
            func addNext() {
                guard next < indices.count else { return }
                let i = indices[next]
                let path = recs[i].targetPath
                next += 1
                group.addTask { (i, ReclaimEstimator.estimate(path: path, isCancelled: isCancelled)) }
            }
            for _ in 0..<min(maxConcurrent, indices.count) { addNext() }
            while let (i, est) = await group.next() {
                done += 1
                progress?(done, indices.count)
                apply(est, to: &out[i])
                addNext()
            }
        }
        return out
    }

    public static func apply(_ est: ReclaimEstimate, to rec: inout Recommendation) {
        // Never report more than was measured at scan time (the invariant the UI relies on).
        rec.estimatedReclaimable = min(est.reclaimable, rec.detectedAllocated)
        rec.reclaimMethod = est.method
        if est.cloneShared > 50 << 20 || (est.cloneShared >= 1 << 20 && est.cloneShared * 4 >= est.allocated) {
            rec.notes.append("\(ByteFormat.string(est.cloneShared)) of this is shared with APFS clones elsewhere and would NOT be freed.")
        }
        if est.hardLinkRetained > 50 << 20 || (est.hardLinkRetained >= 1 << 20 && est.hardLinkRetained * 4 >= est.allocated) {
            rec.notes.append("\(ByteFormat.string(est.hardLinkRetained)) is hard-linked from outside this folder and would NOT be freed.")
        }
        if !est.complete {
            rec.analysisComplete = false
            rec.notes.append("Reclaim estimate incomplete (\(est.errors) unreadable entries).")
        }
    }
}
