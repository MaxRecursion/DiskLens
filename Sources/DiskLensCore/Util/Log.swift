import Foundation
import os

/// Unified logging. Paths are always logged with `privacy: .private`, so they are redacted in
/// logs collected from other Macs (sysdiagnose) and visible only on this Mac with a debug profile.
/// File contents, command lines, license keys and tokens are never logged.
public enum Log {
    public static let subsystem = "com.akshaykulkarni.DiskLens"
    public static let scan = Logger(subsystem: subsystem, category: "scan")
    public static let cleanup = Logger(subsystem: subsystem, category: "cleanup")
    public static let license = Logger(subsystem: subsystem, category: "license")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
