import Foundation
import Darwin
import CoreServices

/// Facts about the process environment that differ between the direct-download build and the
/// sandboxed Mac App Store build. Detected at runtime, so one binary serves both editions.
public enum Platform {
    /// True when running inside the App Sandbox (Mac App Store edition).
    public static let isSandboxed: Bool = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// The user's real home folder. Inside the sandbox `NSHomeDirectory()` returns the app's
    /// container, so the password database is consulted instead.
    public static let realHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let s = String(cString: dir)
            if !s.isEmpty { return PathUtil.canonical(s) ?? s }
        }
        return NSHomeDirectory()
    }()

    /// Whether helper tools (ps, git, brew) may be launched. Child processes of a sandboxed app
    /// inherit its sandbox, so tools that read or write outside granted folders cannot work there.
    public static var canRunExternalTools: Bool { !isSandboxed }

    /// Spotlight attribute date for a path (e.g. kMDItemLastUsedDate), via the MDItem API.
    public static func spotlightDate(_ path: String, attribute: CFString) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let value = MDItemCopyAttribute(item, attribute) else { return nil }
        return value as? Date
    }
}
