import Darwin
import Foundation

// MARK: - Start errors

/// Why binding the RPC socket failed. These are all fatal to daemon startup;
/// they exist so the failure names itself instead of arriving as a bare errno.
public enum SocketServerStartError: Error, LocalizedError, CustomStringConvertible {
    case socketPathTooLong(path: String, limit: Int)
    case socketCreationFailed(code: Int32)
    case bindFailed(path: String, code: Int32)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .socketPathTooLong(let path, let limit):
            return "socket path is \(path.utf8.count) bytes, over the \(limit)-byte sun_path limit: \(path)"
        case .socketCreationFailed(let code):
            return "socket(AF_UNIX, SOCK_STREAM): \(String(cString: strerror(code)))"
        case .bindFailed(let path, let code):
            return "bind(2) on \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Create an `AF_UNIX` stream socket and `bind(2)` it at `path`, returning
/// the bound descriptor for NIO to adopt.
///
/// Only creation and bind happen here. NIO sets the descriptor
/// non-blocking and calls `listen(2)` on it while it builds the channel,
/// exactly as it would for a socket it had made itself. What changes is
/// ownership of the *file*: because NIO did not open the path, it will not
/// unlink the path when the channel closes, and `stop()` decides that
/// instead.
func bindListeningSocket(at path: String) throws -> Int32 {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count < capacity else {
        throw SocketServerStartError.socketPathTooLong(path: path, limit: capacity - 1)
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw SocketServerStartError.socketCreationFailed(code: errno)
    }

    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0 else {
        let code = errno
        close(fd)
        throw SocketServerStartError.bindFailed(path: path, code: code)
    }

    // Restrict the socket before anything can connect to it. NIO's listen
    // comes later, so there is no window here where the file is reachable
    // at the old mode.
    chmod(path, 0o700)
    return fd
}
