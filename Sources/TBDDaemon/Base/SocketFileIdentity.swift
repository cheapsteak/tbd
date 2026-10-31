import Darwin
import Foundation

// MARK: - Socket file identity

/// The identity of a file on disk — `(st_dev, st_ino)` — as distinct from its
/// path. Two sockets bound in turn at one path are two different inodes, and
/// that is the only thing that tells them apart.
struct SocketFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    /// Reads the identity of whatever is at `path`, or `nil` if nothing is.
    ///
    /// `lstat` rather than `stat`: a symlink swapped in at the path is not the
    /// socket we bound, and must not be mistaken for it.
    ///
    /// By the path, and not by `fstat(2)` on the bound descriptor, however
    /// tempting the tighter window looks: on darwin the two do not name the
    /// same thing. `fstat(2)` on a bound `AF_UNIX` descriptor reports the
    /// socket's own in-kernel vnode — a different inode, with `st_dev` of -1 —
    /// not the filesystem entry `bind(2)` created. Measured on darwin 25.1:
    /// `fstat` answered `dev=-1 ino=15302332` for a socket whose path
    /// `lstat`ed as `dev=16777235 ino=863366896`. An identity captured that
    /// way could never equal the one read back from the path, so every
    /// ownership check would fail closed and the socket file would never be
    /// reclaimed at all.
    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        self.device = info.st_dev
        self.inode = info.st_ino
    }
}
