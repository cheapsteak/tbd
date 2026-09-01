import Foundation

/// Fixtures for the holder rendezvous sweep, built out of real unix sockets
/// rather than plain files.
///
/// **A regular file named `<uuid>.sock` would not discriminate.** `connect` to
/// one fails with `ENOTSOCK`, which the collector reads — correctly — as an
/// unreadable answer and keeps. Only a socket that was really bound and then
/// abandoned refuses with `ECONNREFUSED`, and that is precisely the corpse a
/// `SIGKILL`ed holder leaves behind, so it is the only fixture that proves the
/// sweep works on the case it exists for.
enum HolderRendezvousFixture {

    /// Binds a unix socket at `path` and returns its descriptor, `listen`ing
    /// when asked. The caller owns the descriptor.
    ///
    /// Returns `nil` on any failure — most often a path over darwin's 104-byte
    /// `sun_path` limit, which is why every suite here roots its sandbox
    /// directly under `/tmp` rather than under `NSTemporaryDirectory()`.
    static func bind(at path: String, listening: Bool) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { close(fd); return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (index, byte) in bytes.enumerated() { dst[index] = CChar(bitPattern: byte) }
                dst[bytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Foundation.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); return nil }
        if listening { _ = listen(fd, 1) }
        return fd
    }

    /// Binds, optionally listens, then closes — leaving the socket *file* on
    /// disk with nothing behind it. The exact residue of a holder that took a
    /// `SIGKILL`: `bind` refuses an existing path, so nothing will ever reclaim
    /// this file on its own.
    @discardableResult
    static func bindAndAbandon(at path: String) -> Bool {
        guard let fd = bind(at: path, listening: true) else { return false }
        close(fd)
        return true
    }
}
