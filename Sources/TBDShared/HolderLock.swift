import Foundation

/// An exclusive advisory lock serializing holder creation for one session UUID.
///
/// A socket file alone cannot distinguish a live holder from the corpse of a
/// SIGKILLed one, and `bind` refuses a path that already exists — so "unlink
/// the stale socket, then bind" is a race two spawners can both win. An
/// exclusive `flock` on a sibling zero-byte file serializes creation instead.
///
/// Held for the holder's whole life. A spawner that cannot take it has learned
/// that a live holder owns this UUID *without connecting*, and must back off
/// rather than clearing the socket path.
///
/// The kernel releases the lock when the holding process dies — by `exit`, by
/// `SIGKILL`, by anything — so a crash can leak the empty file but never the
/// lock itself.
///
/// Lives in `TBDShared`, not `TBDHolder`, because a SwiftPM library target
/// cannot import an executable target and the daemon-side spawner takes this
/// lock before spawning. Same reasoning as `HolderRendezvous`.
public struct HolderLock {
    public enum Error: LocalizedError, Equatable {
        /// A live process already holds the lock for this session.
        case alreadyHeld(path: String)
        /// The lock file could not be opened, or `flock` failed for a reason
        /// other than contention.
        case cannotOpen(path: String, errno: Int32)
        /// `FD_CLOEXEC` could not be read or cleared.
        case cannotSetFlags(errno: Int32)

        public var errorDescription: String? {
            switch self {
            case .alreadyHeld(let path):
                return "a live holder already owns the creation lock at \(path)"
            case .cannotOpen(let path, let errno):
                return "could not take the holder creation lock at \(path): "
                    + "\(String(cString: strerror(errno))) (errno \(errno))"
            case .cannotSetFlags(let errno):
                return "could not clear FD_CLOEXEC on the holder creation lock: "
                    + "\(String(cString: strerror(errno))) (errno \(errno))"
            }
        }
    }

    public let fileDescriptor: Int32
    /// The lock file this descriptor is open on, kept so a holder or spawner
    /// can name it in a log line without recomputing the rendezvous path.
    public let path: String

    public static func acquire(path: String) throws -> HolderLock {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw Error.cannotOpen(path: path, errno: errno)
        }
        // LOCK_NB: never block. A spawner that would block is a spawner racing
        // a live holder, and waiting would only delay the same conclusion.
        //
        // EINTR is retried rather than reported: a signal arriving while the
        // kernel was placing the lock says nothing about whether another
        // process holds it, and mapping it to `cannotOpen` would turn an
        // ordinary signal into a spurious spawn failure.
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let saved = errno
            if saved == EINTR { continue }
            close(fd)
            if saved == EWOULDBLOCK {
                throw Error.alreadyHeld(path: path)
            }
            throw Error.cannotOpen(path: path, errno: saved)
        }
        return HolderLock(fileDescriptor: fd, path: path)
    }

    /// Clear FD_CLOEXEC so the descriptor — and with it the lock, which lives
    /// on the open file description — survives into the exec'd holder.
    public func makeInheritableAcrossExec() throws {
        let flags = fcntl(fileDescriptor, F_GETFD)
        guard flags >= 0 else { throw Error.cannotSetFlags(errno: errno) }
        guard fcntl(fileDescriptor, F_SETFD, flags & ~FD_CLOEXEC) >= 0 else {
            throw Error.cannotSetFlags(errno: errno)
        }
    }

    /// Closing the descriptor drops the lock. The file is left behind
    /// deliberately: unlinking it would let a racing spawner create and lock a
    /// *different* file at the same path while we still believe we hold it.
    /// OrphanGC sweeps the empty file alongside the socket.
    public func release() {
        close(fileDescriptor)
    }
}
