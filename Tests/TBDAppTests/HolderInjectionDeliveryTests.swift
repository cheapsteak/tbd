import Darwin
import Foundation
import TBDShared
import Testing

@testable import TBDApp
import TestSupport

/// The app's half of the injection path: the frame arriving, the panel that
/// claims the session, the write destination that makes the app the attached
/// session's only writer, and the answer that goes back.
@Suite("HolderInjectionDelivery")
struct HolderInjectionDeliveryTests {

    private func makeSocketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        try pair.withUnsafeMutableBufferPointer { buf in
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (pair[0], pair[1])
    }

    /// Read exactly the frames the daemon side can see, bounded.
    private func readFrames(from fd: Int32, count: Int) throws -> [(type: UInt8, payload: Data)] {
        let scanner = SidecarFrameScanner()
        var frames: [(type: UInt8, payload: Data)] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        var deadline = 200   // ~2 s in 10 ms slices; a hang bound, not a timing budget
        while frames.count < count, deadline > 0 {
            var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&watched, 1, 10) > 0 {
                let read = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if read <= 0 { break }
                frames.append(contentsOf: scanner.append(Data(buffer[0..<read])))
            }
            deadline -= 1
        }
        return frames
    }

    // MARK: - The frame in, the ack out

    @Test("an injection frame reaches the installed handler and its ack goes back")
    func injectionReachesTheHandlerAndIsAcknowledged() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let terminalID = UUID()
        let injectionID = UUID()
        let received = LockedBox<(SidecarInjectionHeader, Data)?>(nil)
        client.setOnInjection { header, bytes in
            received.value = (header, bytes)
            client.sendInjectionAck(injectionID: header.injectionID, written: true)
        }

        let frame = try SidecarFrameCodec.encodeInjection(
            header: SidecarInjectionHeader(terminalID: terminalID, injectionID: injectionID),
            bytes: Data("hello\r".utf8))
        try FDChannel.sendData(frame, over: daemonSide)

        try await waitFor("the injection to reach the handler") { received.value != nil }
        let (header, bytes) = try #require(received.value)
        #expect(header.terminalID == terminalID)
        #expect(header.injectionID == injectionID)
        #expect(bytes == Data("hello\r".utf8))

        let acks = try readFrames(from: daemonSide, count: 1)
        let ack = try SidecarFrameCodec.decodeInjectionAck(payload: try #require(acks.first).payload)
        #expect(ack == SidecarInjectionAck(injectionID: injectionID, written: true))
    }

    /// A knowable, synchronous refusal is reported rather than left to the
    /// daemon's deadline: an app with no handler will never write those bytes,
    /// and five seconds of silence would say the same thing five seconds later.
    @Test("an injection with no handler installed is answered unwritten")
    func injectionWithNoHandlerIsAnsweredUnwritten() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let injectionID = UUID()
        try FDChannel.sendData(
            try SidecarFrameCodec.encodeInjection(
                header: SidecarInjectionHeader(terminalID: UUID(), injectionID: injectionID),
                bytes: Data("hello".utf8)),
            over: daemonSide)

        let acks = try readFrames(from: daemonSide, count: 1)
        let ack = try SidecarFrameCodec.decodeInjectionAck(payload: try #require(acks.first).payload)
        #expect(ack == SidecarInjectionAck(injectionID: injectionID, written: false))
    }

    // MARK: - Routing to the panel that owns the session

    @MainActor
    @Test("an injection is routed to the panel that claims the session, carrying its own target")
    func injectionIsRoutedByTheFramesOwnTarget() async {
        let router = TerminalInjectionRouter()
        let mine = UUID()
        var seen: [(UUID, Data)] = []
        _ = router.register(terminalID: mine) { target, bytes in
            seen.append((target, bytes))
            // The panel's own F10 check: the frame names its target, and a
            // panel writes only what is addressed to it.
            return target == mine
        }

        let written = await router.deliver(terminalID: mine, bytes: Data("hi".utf8))

        #expect(written == true)
        #expect(seen.count == 1)
        #expect(seen.first?.0 == mine, "the frame's own target must reach the panel, not be assumed")
        #expect(seen.first?.1 == Data("hi".utf8))
    }

    @MainActor
    @Test("a panel that verifies the target refuses an injection addressed elsewhere")
    func mismatchedTargetIsRefusedByThePanel() async {
        let router = TerminalInjectionRouter()
        let mine = UUID()
        let someoneElse = UUID()
        // Registered under a key that does not match the closure's own panel
        // id — the shape nothing in the app enforces, and the reason the
        // closure checks rather than trusts its registration.
        _ = router.register(terminalID: someoneElse) { target, _ in target == mine }

        #expect(await router.deliver(terminalID: someoneElse, bytes: Data("hi".utf8)) == false)
    }

    @MainActor
    @Test("an injection for a session no panel claims reports nobody, not a false write")
    func unclaimedSessionReportsNobody() async {
        let router = TerminalInjectionRouter()
        #expect(await router.deliver(terminalID: UUID(), bytes: Data("hi".utf8)) == nil)
    }

    /// A torn-down panel must not withdraw a successor's claim: rebuilding a
    /// tab makes a second coordinator for the same session, and the old one's
    /// cleanup runs after the new one has registered.
    @MainActor
    @Test("unregistering a superseded claim leaves the live one in place")
    func supersededUnregisterIsANoOp() async {
        let router = TerminalInjectionRouter()
        let terminalID = UUID()
        let stale = router.register(terminalID: terminalID) { _, _ in false }
        _ = router.register(terminalID: terminalID) { _, _ in true }

        router.unregister(stale)

        #expect(router.registrationCount == 1)
        #expect(await router.deliver(terminalID: terminalID, bytes: Data("hi".utf8)) == true)
    }

    // MARK: - The write destination itself

    @Test("a whole payload written to a live descriptor reports complete")
    func wholePayloadReportsComplete() throws {
        let (readEnd, writeEnd) = try makeSocketPair()
        defer { Darwin.close(readEnd); Darwin.close(writeEnd) }

        #expect(PTYWrite.all(Data("echo hi\r".utf8), to: writeEnd) == .complete)

        var buffer = [UInt8](repeating: 0, count: 64)
        let read = buffer.withUnsafeMutableBytes { Darwin.read(readEnd, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<max(0, read)]) == Data("echo hi\r".utf8))
    }

    /// The decision R24 asks for, pinned: a payload that only partly fits is a
    /// **failure**, so the daemon rewrites the whole thing. A duplicated
    /// prompt is visible and recoverable; a silently truncated one is not.
    @Test("a payload that does not fit is reported as partial, never as written")
    func oversizePayloadReportsPartialRatherThanWritten() throws {
        let (readEnd, writeEnd) = try makeSocketPair()
        defer { Darwin.close(readEnd); Darwin.close(writeEnd) }
        // Nobody ever reads `readEnd`, so the socket buffer fills and stays
        // full — the same shape as a child that has stopped reading its tty.
        _ = fcntl(writeEnd, F_SETFL, fcntl(writeEnd, F_GETFL, 0) | O_NONBLOCK)
        let payload = Data(repeating: 0x61, count: 8 * 1024 * 1024)

        let outcome = PTYWrite.all(payload, to: writeEnd, budgetMilliseconds: 5)

        guard case .partial(let written) = outcome else {
            Issue.record("expected a partial write, got \(outcome)")
            return
        }
        #expect(written > 0)
        #expect(written < payload.count)
    }

    @Test("a closed descriptor is a failure, and an absent one writes nothing")
    func deadDescriptorsAreReported() throws {
        let (readEnd, writeEnd) = try makeSocketPair()
        Darwin.close(readEnd)
        Darwin.close(writeEnd)

        guard case .failed = PTYWrite.all(Data("x".utf8), to: writeEnd) else {
            Issue.record("a closed descriptor must report a failure")
            return
        }
        #expect(PTYWrite.all(Data("x".utf8), to: -1) == .nothingWritten)
        #expect(PTYWrite.all(Data(), to: -1) == .complete, "an empty write asks nothing of the fd")
    }
}

/// Minimal cross-thread box: the sidecar's receive thread writes, the test
/// reads. Not `LockIsolated` from swift-clocks' dependency tree, because this
/// target does not depend on it.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
