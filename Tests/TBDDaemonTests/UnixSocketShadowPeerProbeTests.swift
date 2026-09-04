import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib

/// `UnixSocketShadowPeerProbe` — the one step of the shadow-peer sweep that
/// touches a real socket, and the only place the platform gets to answer for
/// itself.
///
/// Every case here binds an actual `AF_UNIX` listener rather than standing in a
/// fake for the syscall. The fact this suite exists to pin is a **kernel** fact,
/// and a fake would only restate whatever its author believed the kernel does —
/// which is exactly the belief that was wrong.
///
/// Nothing goes near the socket directory the feature really uses; that one is
/// shared with every Claude Code session on the machine. Each test gets its own
/// directory, created directly under `/tmp` because `sockaddr_un.sun_path` is
/// about 104 bytes on darwin and the per-process temporary directory spends
/// most of that on its own.
@Suite("UnixSocketShadowPeerProbe")
struct UnixSocketShadowPeerProbeTests {

    // MARK: - Scaffolding

    /// Thrown when the test's own scaffolding could not be built. Never an
    /// assertion about the code under test — the `Issue` was already recorded
    /// where it was discovered.
    private struct SetupFailure: Swift.Error {}

    /// A scratch directory **directly under `/tmp`**, and short on purpose: the
    /// probe answers `.inconclusive` without connecting at all when a path will
    /// not fit in `sun_path`, so a suite built on a long temporary directory
    /// would green on an answer that never went near a socket.
    private static func makeScratchDirectory() throws -> URL {
        let name = String(format: "tbd-probe-%08x", UInt32.random(in: 0...UInt32.max))
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func socketAddress(for path: String) -> sockaddr_un {
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
    private static func bindListener(
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
    private static func connectAndHold(
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

    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Cases

    /// Nothing at the path at all. Already reclaimed — by the helper's own
    /// exit, or by an earlier sweep.
    @Test func aPathWithNoFileIsAbsent() throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("1.sock").path

        #expect(UnixSocketShadowPeerProbe().listenerState(atPath: path) == .absent)
    }

    /// A healthy listener with room in its accept queue — the shape of every
    /// live session's socket, and the answer that must never lead to an unlink.
    @Test func aListenerWithRoomInItsQueueIsListening() throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("2.sock").path
        let listener = try Self.bindListener(at: path, backlog: 8)
        defer { Darwin.close(listener) }

        #expect(UnixSocketShadowPeerProbe().listenerState(atPath: path) == .listening)
    }

    /// The orphan the sweep exists to collect: a process bound, listened, and
    /// went away, leaving the file with nothing behind it. Closing a Unix
    /// listener never unlinks its socket file, which is why the orphan exists.
    @Test func aBoundFileWhoseListenerIsClosedIsRefused() throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("3.sock").path
        let listener = try Self.bindListener(at: path, backlog: 8)
        Darwin.close(listener)

        #expect(Self.exists(path), "closing a listener does not unlink its socket file")
        #expect(UnixSocketShadowPeerProbe().listenerState(atPath: path) == .refused)
    }

    /// **The platform fact the reconciler's whole design turns on.**
    ///
    /// A live listener whose accept queue is full refuses a connect on darwin:
    /// the queue's limit is exactly the backlog passed to `listen(2)`, the call
    /// returns `ECONNREFUSED` immediately rather than blocking, and a
    /// non-blocking connect never comes back in-progress. So `.refused` and
    /// "nothing is listening" are one observation, and a sweep that unlinked on
    /// `.refused` alone would delete a live session's socket out from under it
    /// in the microseconds its queue happened to be full — leaving a running
    /// session silently unaddressable for the rest of its life.
    ///
    /// `ShadowPeerReconciler` therefore never treats a refusal as proof on its
    /// own: it unlinks only when the pid the file is named after is provably
    /// gone, because that pid is the only process that could legitimately be
    /// listening there.
    @Test func aLiveListenerWithAFullAcceptQueueIsAlsoRefused() throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("4.sock").path
        let listener = try Self.bindListener(at: path, backlog: 1)
        defer { Darwin.close(listener) }
        let queued = try Self.connectAndHold(to: path)
        defer { Darwin.close(queued) }

        #expect(
            UnixSocketShadowPeerProbe().listenerState(atPath: path) == .refused,
            "a saturated listener is indistinguishable from an absent one at the connect")
    }
}
