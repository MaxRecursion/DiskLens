import Foundation

public struct ScanOptions: Codable, Sendable, Hashable {
    /// Roots to scan. They are canonicalised and de-overlapped before scanning.
    public var roots: [String]
    /// Files at or above this allocated size get their own node; smaller files are aggregated.
    public var fileNodeThreshold: Int64
    /// Never descend into directories on a different device than their scan root.
    public var stayOnDevice: Bool
    /// Absolute canonical paths whose subtrees are skipped entirely (recorded in the manifest).
    public var excludedPaths: [String]
    /// Seconds to wait for a privacy-protected folder to open before skipping it.
    public var privacyProbeTimeout: TimeInterval = 8
    /// Folders to treat as privacy-blocked without probing (user choice; also used by tests).
    public var assumeBlocked: [String] = []

    public init(roots: [String], fileNodeThreshold: Int64 = 1 << 20, stayOnDevice: Bool = true, excludedPaths: [String] = []) {
        self.roots = roots
        self.fileNodeThreshold = fileNodeThreshold
        self.stayOnDevice = stayOnDevice
        self.excludedPaths = excludedPaths
    }

    /// Default scope: the user's home plus user-attributable system locations. Read-only.
    public static func defaultScope(home: String = Platform.realHome) -> ScanOptions {
        var roots = [home, "/Applications", "/opt/homebrew", "/usr/local", "/Library", "/Users/Shared"]
        let userTemp = (NSTemporaryDirectory() as NSString).deletingLastPathComponent  // .../T -> user folder
        if userTemp.hasPrefix("/var/folders/") || userTemp.hasPrefix("/private/var/folders/") {
            roots.append(userTemp)
        }
        return ScanOptions(roots: roots)
    }
}

public struct ScanError: Codable, Sendable, Hashable {
    public var path: String
    public var errno: Int32
    public var message: String
    public init(path: String, errno: Int32, message: String) {
        self.path = path; self.errno = errno; self.message = message
    }
}

public struct ScanStats: Codable, Sendable, Hashable {
    public var filesVisited: Int64 = 0
    public var directoriesVisited: Int64 = 0
    public var symlinksNotFollowed: Int64 = 0
    public var hardLinkDuplicatesSkipped: Int64 = 0
    public var mountPointsNotCrossed: Int64 = 0
    public var unreadableDirectories: Int64 = 0
    public var statFailures: Int64 = 0
    public var datalessFiles: Int64 = 0
    public var datalessDirectories: Int64 = 0
    public var otherFileTypes: Int64 = 0
    public init() {}
}

/// Machine-readable record of how a scan was produced. Shown in the app's Manifest tab and
/// written next to every saved scan.
public struct ScanManifest: Codable, Sendable {
    public var scanID: UUID
    public var startedAt: Date
    public var finishedAt: Date
    public var requestedRoots: [String]
    public var effectiveRoots: [String]
    public var droppedOverlappingRoots: [String]
    public var missingRoots: [String]
    public var options: ScanOptions
    public var stats: ScanStats
    /// First N errors (full count is in `stats` / `errorCount`).
    public var errors: [ScanError]
    public var errorCount: Int
    public var volumeBefore: VolumeSnapshot?
    /// Privacy-protected folders that did not open in time and were not scanned.
    public var privacyBlockedPaths: [String] = []
    public var totalAllocated: Int64
    public var totalLogical: Int64
    public var cancelled: Bool
    public var hostName: String
    public var osVersion: String
    public var methodology: String

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    public init(scanID: UUID, startedAt: Date, finishedAt: Date, requestedRoots: [String], effectiveRoots: [String],
                droppedOverlappingRoots: [String], missingRoots: [String], options: ScanOptions, stats: ScanStats,
                errors: [ScanError], errorCount: Int, volumeBefore: VolumeSnapshot?, privacyBlockedPaths: [String] = [],
                totalAllocated: Int64, totalLogical: Int64, cancelled: Bool, hostName: String, osVersion: String,
                methodology: String) {
        self.scanID = scanID; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.requestedRoots = requestedRoots; self.effectiveRoots = effectiveRoots
        self.droppedOverlappingRoots = droppedOverlappingRoots; self.missingRoots = missingRoots
        self.options = options; self.stats = stats; self.errors = errors; self.errorCount = errorCount
        self.volumeBefore = volumeBefore; self.privacyBlockedPaths = privacyBlockedPaths
        self.totalAllocated = totalAllocated; self.totalLogical = totalLogical; self.cancelled = cancelled
        self.hostName = hostName; self.osVersion = osVersion; self.methodology = methodology
    }

    public static let methodologyText = """
    Measurement methodology (DiskLens):
    • Traversal: POSIX fts(3) with FTS_PHYSICAL (symbolic links are never followed; a link counts only its own few bytes) \
    and FTS_NOCHDIR. Directories on a different device than their scan root are not crossed (mount points are recorded).
    • Logical size = st_size. Allocated size = st_blocks × 512 (what the file occupies on disk; sparse VM images and \
    compressed files can have allocated << logical).
    • Hard links: a file with st_nlink > 1 is counted once per (device, inode) per scan.
    • Overlapping roots are de-duplicated before scanning so no subtree is counted twice. Directory totals are the sum \
    of their children; category totals are computed from leaves only.
    • APFS clones and snapshots: allocated size double-counts blocks shared between clones. Reclaimable estimates for \
    cleanup candidates are therefore computed separately with getattrlist(ATTR_CMNEXT_PRIVATESIZE), which reports \
    only the blocks private to each file. Blocks pinned by local snapshots are not freed by deletion until the \
    snapshot is removed.
    • Cloud-only (dataless) files and folders from File Provider apps (iCloud Drive, Google Drive…) are never \
    downloaded: materialization is disabled for the process (setiopolicy_np) and dataless folders are not entered.
    • Unreadable directories (permissions/TCC) are flagged and listed as coverage gaps; their size is unknown, never \
    assumed to be zero.
    • Free space is read from URLResourceValues (volumeAvailableCapacity and \
    volumeAvailableCapacityForImportantUsage, which includes purgeable space) and statfs(2).
    • The scan is strictly read-only: no file contents are opened and nothing is modified.
    """
}
