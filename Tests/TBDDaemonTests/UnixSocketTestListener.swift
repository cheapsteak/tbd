import Darwin
import Foundation
import Testing

/// Shared `AF_UNIX` listener scaffolding for the two suites that bind a real
/// socket to pin platform behavior: `UnixSocketShadowPeerProbeTests` and
/// `ShadowPeerReconcilerTests`. Both live in the `TBDDaemonTests` target, so
/// this is the one copy rather than two byte-identical private ones.
enum UnixSocketTestListener {

    /// Thrown when the test's own scaffolding could not be built. Never an
    /// assertion about the code under test — the `Issue` was already recorded
    /// where it was discovered.
    struct SetupFailure: Error {}

    /// A scratch directory **directly under `/tmp`**, and short on purpose: the
    /// probe answers `.inconclusive` without connecting at all when a path will
    /// not fit in `sun_path`, so a suite built on a long temporary directory
    /// would green on an answer that never went near a socket.
    static func makeShortScratchDirectory(prefix: String = "tbd-sock") throws -> URL {
        let name = String(format: "\(prefix)-%08x", UInt32.random(in: 0...UInt32.max))
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func socketAddress(for path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { chars in
                    _ = strlcpy(chars, source, sunPathSize)
                }
            }
        }
        return address
    }

    /// Bind and listen at `path`, returning the listening descriptor. **Nothing
    /// ever accepts on it**: a connect completes into the accept queue and
    /// stays there, which is what lets a test hold the queue full.
    static func bindListener(
        at path: String, backlog: Int32, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0, "could not create a listening socket", sourceLocation: sourceLocation)
        var address = socketAddress(for: path)
        unlink(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, backlog) == 0 else {
            let saved = errno
            Darwin.close(fd)
            Issue.record(
                "could not listen at \(path) (errno \(saved))", sourceLocation: sourceLocation)
            throw SetupFailure()
        }
        return fd
    }

    /// Connect to `path` and **keep the connection open**, returning the client
    /// descriptor. The listener never accepts it, so it occupies a slot in the
    /// accept queue for as long as the caller holds the descriptor.
    static func connectAndHold(
        to path: String, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0, "could not create a client socket", sourceLocation: sourceLocation)
        var address = socketAddress(for: path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let saved = errno
            Darwin.close(fd)
            Issue.record(
                "could not fill the accept queue at \(path) (errno \(saved))",
                sourceLocation: sourceLocation)
            throw SetupFailure()
        }
        return fd
    }
}
