import Darwin
import Foundation
import TBDShared
import Testing

@testable import TBDApp
import TestSupport

/// The app's half of the screen pull at the wire: a `screenRequest` arriving on
/// the sidecar, the handler it reaches, and the reply that goes back.
///
/// The read-direction twin of `HolderInjectionDeliveryTests`' first two cases,
/// and the properties are the two that matter at this layer: **a request
/// reaches the installed handler**, and **a reply is sent on every path** —
/// including the path where no handler is installed at all, because a knowable
/// refusal reported now is what keeps the daemon from spending its whole bound
/// on an answer that was never coming.
@Suite("HolderScreenRequestDelivery")
struct HolderScreenRequestDeliveryTests {

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

    private func request(
        terminalID: UUID = UUID(), requestID: UUID = UUID()
    ) -> SidecarScreenRequest {
        SidecarScreenRequest(
            terminalID: terminalID, requestID: requestID, requestedLines: 50,
            retainedScrollbackLines: 5_000, wantStyledCapture: false)
    }

    private func payload() -> ViewerScreenPayload {
        ViewerScreenPayload(
            lines: ["answered from the viewer"], viewportStart: 0,
            cursorRow: 1, cursorColumn: 2,
            cursorVisible: true, cursorVisibleObserved: false,
            columns: 80, rows: 24,
            bracketedPaste: true, applicationCursor: false, alternateScreen: false,
            ageMilliseconds: 4)
    }

    // MARK: - The frame in, the reply out

    @Test("a screen request reaches the installed handler and its reply goes back")
    func requestReachesTheHandlerAndIsAnswered() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let sent = request()
        let answer = payload()
        let received = LockedBox<SidecarScreenRequest?>(nil)
        client.setOnScreenRequest { request in
            received.value = request
            client.sendScreenReply(
                SidecarScreenReply(
                    requestID: request.requestID, terminalID: request.terminalID,
                    screen: answer))
        }

        try FDChannel.sendData(try SidecarFrameCodec.encodeScreenRequest(sent), over: daemonSide)

        try await waitFor("the screen request to reach the handler") { received.value != nil }
        #expect(received.value == sent, "the request must survive the wire unchanged")

        let frames = try readFrames(from: daemonSide, count: 1)
        let frame = try #require(frames.first)
        #expect(SidecarFrameType(rawValue: frame.type) == .screenReply)
        let reply = try SidecarFrameCodec.decodeScreenReply(payload: frame.payload)
        #expect(reply.requestID == sent.requestID, "the reply must carry its request's id")
        #expect(reply.terminalID == sent.terminalID,
                "the reply must name its session, because the sidecar is one app-wide connection")
        #expect(reply.screen == answer)
        #expect(reply.unavailable == nil)
    }

    /// The path that would otherwise cost the daemon its whole bound. An app
    /// with no handler is one that will never answer, and saying so at once is
    /// what lets the daemon fall back to its own emulator immediately.
    @Test("a screen request with no handler installed is answered unavailable")
    func requestWithNoHandlerIsAnsweredUnavailable() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let sent = request()
        try FDChannel.sendData(try SidecarFrameCodec.encodeScreenRequest(sent), over: daemonSide)

        let frames = try readFrames(from: daemonSide, count: 1)
        let reply = try SidecarFrameCodec.decodeScreenReply(
            payload: try #require(frames.first).payload)
        #expect(reply.requestID == sent.requestID)
        #expect(reply.unavailable == .noPanel)
        #expect(reply.screen == nil)
    }

    /// `.screenReply` is app → daemon only. A daemon that sent one would be in
    /// protocol violation, and the app logs and drops it rather than acting —
    /// and critically, **keeps reading**: the request queued behind it still
    /// reaches the handler, which is what this asserts rather than the drop
    /// itself (a dropped frame leaves no observable trace by design).
    @Test("a screen reply from the daemon is dropped, and the loop keeps reading")
    func replyFromTheDaemonIsDroppedWithoutStoppingTheLoop() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let sent = request()
        let received = LockedBox<SidecarScreenRequest?>(nil)
        client.setOnScreenRequest { received.value = $0 }

        var wire = try SidecarFrameCodec.encodeScreenReply(
            SidecarScreenReply(
                requestID: UUID(), terminalID: UUID(), unavailable: .noPanel))
        wire += try SidecarFrameCodec.encodeScreenRequest(sent)
        try FDChannel.sendData(wire, over: daemonSide)

        try await waitFor("the request queued behind a wrong-direction reply to arrive") {
            received.value == sent
        }
    }

    /// An undecodable request is dropped rather than answered: there is no
    /// `requestID` to answer it under, so the daemon's bound is the only thing
    /// that can cover it. Asserted the only way a drop can be — by the frame
    /// behind it still arriving.
    @Test("an undecodable screen request does not stop the loop")
    func undecodableRequestDoesNotStopTheLoop() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let sent = request()
        let received = LockedBox<SidecarScreenRequest?>(nil)
        client.setOnScreenRequest { received.value = $0 }

        var wire = SidecarFrameCodec.encode(
            type: .screenRequest, payload: Data("not json".utf8))
        wire += try SidecarFrameCodec.encodeScreenRequest(sent)
        try FDChannel.sendData(wire, over: daemonSide)

        try await waitFor("the request queued behind an undecodable one to arrive") {
            received.value == sent
        }
    }
}

/// A value the sidecar's receive thread writes and the test's task reads.
///
/// File-private, like the identically-shaped box in
/// `HolderInjectionDeliveryTests`: a shared one would be a `TestSupport`
/// export, and a two-line lock box is not worth a cross-target dependency.
private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
