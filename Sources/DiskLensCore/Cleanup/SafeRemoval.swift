import Foundation
import Darwin

/// Race-resistant primitives for removing a validated target.
///
/// Path-based deletion re-resolves the path at removal time, so an ancestor swapped for a symlink
/// after validation could redirect it. Instead we open the validated parent with O_NOFOLLOW_ANY,
/// confirm (F_GETPATH) it is the directory we validated, confirm the child's device+inode with
/// fstatat(AT_SYMLINK_NOFOLLOW), and atomically rename the child into a DiskLens-owned staging
/// directory on the same volume. Only the staged item (which nobody else references) is removed.
public enum SafeRemoval {
    static let O_NOFOLLOW_ANY_FLAG: Int32 = 0x2000_0000
    static let RENAME_EXCL_FLAG: UInt32 = 0x0000_0004

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case parentChanged(String)
        case targetChanged
        case stagingUnavailable(String)
        case renameFailed(Int32)

        public var description: String {
            switch self {
            case .parentChanged(let p): return "The parent folder changed since validation (symlink or replacement): \(p)"
            case .targetChanged: return "The target changed since validation (different inode or became a symlink)."
            case .stagingUnavailable(let why): return "Cannot stage safely: \(why)"
            case .renameFailed(let e): return "Atomic move failed: \(String(cString: strerror(e)))"
            }
        }
    }

    /// Opens `path` as a directory without following any symlink in it; nil if it is not exactly `path`.
    public static func openVerifiedDirectory(_ path: String) -> Int32? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY_FLAG | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) != -1 else { close(fd); return nil }
        let actual = String(cBuffer: buf)
        // F_GETPATH may differ only in letter case on case-insensitive volumes.
        guard actual.compare(path, options: .caseInsensitive) == .orderedSame else { close(fd); return nil }
        return fd
    }

    /// Device/inode/type of `name` inside directory `dirfd` (never follows a symlink).
    public static func identity(dirfd: Int32, name: String) -> (dev: Int32, ino: UInt64, isLink: Bool)? {
        var st = stat()
        guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return (st.st_dev, UInt64(st.st_ino), (st.st_mode & S_IFMT) == S_IFLNK)
    }

    public static func exists(dirfd: Int32, name: String) -> Bool { identity(dirfd: dirfd, name: name) != nil }

    /// Atomically moves `name` from `parentFD` into `stagingFD` after verifying its identity.
    /// Returns the staged name. Throws without moving anything if identity does not match.
    public static func stage(parentFD: Int32, name: String, expectedDev: Int32, expectedIno: UInt64,
                             stagingFD: Int32) throws -> String {
        guard let id = identity(dirfd: parentFD, name: name), !id.isLink,
              id.dev == expectedDev, expectedIno == 0 || id.ino == expectedIno else { throw Failure.targetChanged }
        var sst = stat()
        guard fstat(stagingFD, &sst) == 0, sst.st_dev == id.dev else {
            throw Failure.stagingUnavailable("staging folder is on a different volume")
        }
        let staged = "\(UUID().uuidString)-\(name)"
        guard renameatx_np(parentFD, name, stagingFD, staged, RENAME_EXCL_FLAG) == 0 else { throw Failure.renameFailed(errno) }
        // Re-verify that what we moved is what we validated; if not, put it straight back.
        guard let moved = identity(dirfd: stagingFD, name: staged), moved.ino == id.ino, moved.dev == id.dev else {
            _ = renameatx_np(stagingFD, staged, parentFD, name, RENAME_EXCL_FLAG)
            throw Failure.targetChanged
        }
        return staged
    }

    /// Moves a staged item back to its original place (failure recovery). Returns success.
    @discardableResult
    public static func unstage(stagingFD: Int32, stagedName: String, parentFD: Int32, name: String) -> Bool {
        renameatx_np(stagingFD, stagedName, parentFD, name, RENAME_EXCL_FLAG) == 0
    }
}
