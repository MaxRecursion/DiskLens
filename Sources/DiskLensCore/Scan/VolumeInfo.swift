import Foundation
import Darwin

/// A point-in-time measurement of a volume's capacity. All values are measured, not estimated.
public struct VolumeSnapshot: Codable, Sendable, Hashable {
    public var takenAt: Date
    public var path: String
    public var volumeName: String
    public var totalBytes: Int64
    /// Free bytes right now (statfs f_bavail * f_bsize).
    public var availableBytes: Int64
    /// Free bytes including purgeable space macOS can reclaim on demand.
    public var availableForImportantUsage: Int64
    /// Bytes used by everything in the APFS container that this volume shares with others.
    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    /// Purgeable space macOS could free on demand (estimate reported by the OS).
    public var purgeableBytes: Int64 { max(0, availableForImportantUsage - availableBytes) }

    public init(takenAt: Date, path: String, volumeName: String, totalBytes: Int64, availableBytes: Int64, availableForImportantUsage: Int64) {
        self.takenAt = takenAt
        self.path = path
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableForImportantUsage = availableForImportantUsage
    }
}

public enum VolumeInfo {
    /// Measures the volume containing `path`. Returns nil only if the path cannot be stat'ed.
    public static func snapshot(for path: String = Platform.realHome) -> VolumeSnapshot? {
        var fs = statfs()
        // Inside the sandbox the real home may not be stat-able until granted; the container is
        // on the same volume.
        guard statfs(path, &fs) == 0 || statfs(NSHomeDirectory(), &fs) == 0 else { return nil }
        let bsize = Int64(fs.f_bsize)
        let total = Int64(fs.f_blocks) * bsize
        let avail = Int64(fs.f_bavail) * bsize
        var important = avail
        var name = ""
        let url = URL(fileURLWithPath: path)
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]) {
            if let imp = v.volumeAvailableCapacityForImportantUsage, imp > 0 { important = imp }
            name = v.volumeName ?? ""
        }
        return VolumeSnapshot(takenAt: Date(), path: path, volumeName: name, totalBytes: total,
                              availableBytes: avail, availableForImportantUsage: max(important, avail))
    }

    /// Device id of a path (lstat), used to detect mount crossings.
    public static func device(of path: String) -> Int32? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_dev
    }
}
