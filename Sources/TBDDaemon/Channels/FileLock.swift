import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "channels.flock")

/// Holds an exclusive `flock(2)` on a sidecar lockfile for the lifetime of
/// the value. Use `acquire(path:)` (blocking) and call `release()` once done.
///
/// Rationale: defensive guard against the two-daemon race the
/// adversarial-review identified. The daemon enforces single-instance via
/// `PIDFile.swift`, but the read-then-write check there has a TOCTOU window;
/// `flock` makes channel writes safe even if two daemons briefly coexist.
struct FileLock {
    private let fd: Int32
    private let path: String

    static func acquire(path: String) throws -> FileLock {
        // O_RDWR | O_CREAT | O_CLOEXEC; permissions 0644.
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        if fd < 0 {
            throw FileLockError.openFailed(errno: errno, path: path)
        }
        // Blocking exclusive lock.
        if flock(fd, LOCK_EX) != 0 {
            let savedErrno = errno
            close(fd)
            throw FileLockError.lockFailed(errno: savedErrno, path: path)
        }
        logger.debug("Acquired lock on \(path, privacy: .public)")
        return FileLock(fd: fd, path: path)
    }

    func release() throws {
        if flock(fd, LOCK_UN) != 0 {
            let savedErrno = errno
            close(fd)
            throw FileLockError.unlockFailed(errno: savedErrno, path: path)
        }
        close(fd)
        logger.debug("Released lock on \(path, privacy: .public)")
    }
}

enum FileLockError: Error, CustomStringConvertible {
    case openFailed(errno: Int32, path: String)
    case lockFailed(errno: Int32, path: String)
    case unlockFailed(errno: Int32, path: String)

    var description: String {
        switch self {
        case .openFailed(let e, let p):  return "open(\(p)) failed: errno=\(e)"
        case .lockFailed(let e, let p):  return "flock(LOCK_EX, \(p)) failed: errno=\(e)"
        case .unlockFailed(let e, let p): return "flock(LOCK_UN, \(p)) failed: errno=\(e)"
        }
    }
}
