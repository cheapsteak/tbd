import AppKit
import Darwin
import Foundation
import SwiftTerm
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

    /// Whatever `fd` has for us right now, after a short bounded poll. Used
    /// both to read what a panel wrote and to establish that it wrote nothing.
    private func readAvailable(from fd: Int32, within milliseconds: Int32 = 100) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var remaining = milliseconds
        while remaining > 0 {
            var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&watched, 1, 10) > 0 else { remaining -= 10; continue }
            let read = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if read <= 0 { break }
            out.append(contentsOf: buffer[0..<read])
            break
        }
        return out
    }

    /// An outer frame carrying a type byte no `SidecarFrameType` case claims.
    ///
    /// Hand-built because `SidecarFrameCodec.encode` takes the enum, and the
    /// enum is precisely what a forward-compatible peer does not have: the
    /// case under test is a byte from a newer daemon, not one of ours.
    private func rawFrame(type: UInt8, payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        let length = UInt32(1 + payload.count)
        out.append(UInt8(length & 0xff))
        out.append(UInt8((length >> 8) & 0xff))
        out.append(UInt8((length >> 16) & 0xff))
        out.append(UInt8((length >> 24) & 0xff))
        out.append(type)
        out.append(payload)
        return out
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

    /// The forward-compat seam the injection frames rely on, exercised where
    /// it actually lives: the **receive loop's** `SidecarFrameType(rawValue:)`
    /// guard. The scanner never reads the type byte, so a scanner-level test
    /// of this property asserts nothing — it is type-agnostic by construction
    /// and no mutation can redden it.
    ///
    /// The unknown frame and the injection go out in one write, so a loop that
    /// treated an unrecognized type as corruption (breaking, or tearing the
    /// connection down) would drop the injection sitting behind it and this
    /// test would time out by name.
    @Test("an unknown frame type is skipped by the receive loop, which keeps reading")
    func unknownFrameTypeIsSkippedByTheReceiveLoop() async throws {
        let (daemonSide, appSide) = try makeSocketPair()
        defer { Darwin.close(daemonSide) }
        let client = FDSidecarClient()
        client.adopt(fd: appSide)

        let injectionID = UUID()
        let received = LockedBox<UUID?>(nil)
        client.setOnInjection { header, _ in received.value = header.injectionID }

        var wire = rawFrame(type: 99, payload: Data([0xde, 0xad, 0xbe, 0xef]))
        wire += try SidecarFrameCodec.encodeInjection(
            header: SidecarInjectionHeader(terminalID: UUID(), injectionID: injectionID),
            bytes: Data("hi\r".utf8))
        try FDChannel.sendData(wire, over: daemonSide)

        try await waitFor("the injection queued behind an unknown frame to reach the handler") {
            received.value == injectionID
        }
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

    /// The **production** guard, reached on the closure a real panel
    /// registered.
    ///
    /// `mismatchedTargetIsRefusedByThePanel` above builds its own closure and
    /// therefore asserts on itself: delete
    /// `guard let self, target == self.panelID` from `startHolderClient` and it
    /// stays green. Nothing in production can call a panel's closure with a
    /// foreign target either — `TerminalInjectionRouter.deliver` looks an entry
    /// up by id and passes that same id — so the guard is reachable only
    /// through `registeredHandlerForTesting`, which hands back the closure the
    /// panel actually installed.
    ///
    /// The positive control on the same closure is what makes the refusal
    /// evidence: the panel's `dup` here is a live socket, so an injection
    /// addressed to it really is written and really is read back off the other
    /// end. Without that, "returned false and wrote nothing" would also be the
    /// reading for a panel with no write destination at all.
    @MainActor
    @Test("the panel's own registered handler refuses an injection addressed elsewhere")
    func registeredPanelHandlerRefusesAForeignTarget() async throws {
        let panel = try await makeHolderPanel()
        defer { panel.tearDown() }
        let handler = try #require(
            panel.state.terminalInjections.registeredHandlerForTesting(
                terminalID: panel.terminalID),
            "the panel must claim its session once the attach is live")

        let refused = await handler(UUID(), Data("stranger\r".utf8))

        #expect(refused == false, "a frame addressed to another session must be refused")
        #expect(readAvailable(from: panel.sessionEnd).isEmpty,
                "the refused bytes must not reach this session's pty")

        // Positive control, same closure: what IS addressed here goes out.
        let accepted = await handler(panel.terminalID, Data("mine\r".utf8))

        #expect(accepted == true)
        #expect(readAvailable(from: panel.sessionEnd) == Data("mine\r".utf8))
    }

    /// R20's rule, applied to the other direction: **one line per failing
    /// episode, not one per keystroke.**
    ///
    /// Reached by the route a user actually reaches it by — after the
    /// session's child exits, every write to the master returns `EIO` and
    /// nothing lowers `holderWriteFD`, because the reader closes its own
    /// descriptor on EOF and never calls `stopHolderReader`. A read-only
    /// descriptor stands in for that: every write fails, forever, for a panel
    /// that is otherwise live.
    ///
    /// The assertion is on the *count of transitions*, not on a state bit: an
    /// unconditional log leaves the bit identical while the count climbs once
    /// per write, so only the count can tell the two apart.
    @MainActor
    @Test("a permanently failing pty logs once per episode, not once per write")
    func failingHolderWritesAreLoggedOncePerEpisode() async throws {
        let readOnly = Darwin.open("/dev/null", O_RDONLY)
        try #require(readOnly >= 0)
        let panel = try await makeHolderPanel(vending: readOnly)
        defer { panel.tearDown() }
        let handler = try #require(
            panel.state.terminalInjections.registeredHandlerForTesting(
                terminalID: panel.terminalID))

        for _ in 0..<3 {
            #expect(await handler(panel.terminalID, Data("x".utf8)) == false,
                    "a write to an unwritable descriptor must be reported unwritten")
        }

        #expect(panel.coordinator.holderWriteFailureLogsForTesting == 1, """
            every failing write logged; on a session whose child has exited that is one \
            `.error` per keystroke for as long as somebody keeps typing
            """)
    }

    /// The positive control for the latch: a panel whose writes succeed logs
    /// nothing at all, so "1" above is a transition rather than a constant.
    @MainActor
    @Test("a working pty logs no write failures")
    func workingHolderWritesLogNothing() async throws {
        let panel = try await makeHolderPanel()
        defer { panel.tearDown() }
        let handler = try #require(
            panel.state.terminalInjections.registeredHandlerForTesting(
                terminalID: panel.terminalID))

        #expect(await handler(panel.terminalID, Data("x".utf8)) == true)

        #expect(panel.coordinator.holderWriteFailureLogsForTesting == 0)
    }

    /// A holder-backed panel wired the way production wires one, attached to a
    /// socket pair standing in for the vended pty: the panel gets one end (and
    /// `dup`s it to write through), the test holds the other and plays the
    /// session.
    @MainActor
    private struct HolderPanel {
        let state: AppState
        let coordinator: TerminalPanelRepresentable.Coordinator
        let view: TBDTerminalView
        let terminalID: UUID
        /// The session's end of the pair. The panel's end belongs to the
        /// reader, which closes it on its way out.
        let sessionEnd: Int32
        let defaults: UserDefaults
        let suiteName: String

        func tearDown() {
            coordinator.cleanup()
            Darwin.close(sessionEnd)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// Stands in for the daemon's two attach RPCs, handing over a descriptor
    /// the test can read.
    private struct StubAttach: HolderAttaching {
        let attachment: HolderAttachment

        func attach(
            worktreeID: UUID, paneID: String, terminalID: UUID
        ) async throws -> HolderAttachment { attachment }

        func ready(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
        ) async throws {}
    }

    @MainActor
    private func makeHolderPanel(vending: Int32? = nil) async throws -> HolderPanel {
        // `vending` overrides the socket pair for a panel whose writes must
        // fail; `sessionEnd` is then a descriptor nothing ever writes to.
        let (sessionEnd, paired) = try makeSocketPair()
        let vended = vending ?? paired
        if vending != nil { Darwin.close(paired) }
        // The real vend is a `dup` of a pty the daemon opened `O_NONBLOCK`, and
        // the flag rides the dup; a reader that blocks here would spin.
        _ = fcntl(vended, F_SETFL, fcntl(vended, F_GETFL, 0) | O_NONBLOCK)

        let worktreeID = UUID()
        let terminalID = UUID()
        let state = AppState()
        // A holder row carries empty tmux coordinates by construction.
        state.terminals[worktreeID] = [Terminal(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: "",
            tmuxPaneID: "",
            label: "Shell",
            kind: .shell,
            transport: .holder
        )]

        // Isolated defaults: `AppearanceSettings` must never read or write the
        // developer's real TBDApp.plist.
        let suiteName = "TBDAppTests.HolderInjectionDelivery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID
        coordinator.holderAttachClient = StubAttach(
            attachment: HolderAttachment(
                ptyFD: vended, generation: 7, snapshotPreamble: Data()))

        await coordinator.startHolderClient(terminalView: view)

        return HolderPanel(
            state: state, coordinator: coordinator, view: view, terminalID: terminalID,
            sessionEnd: sessionEnd, defaults: defaults, suiteName: suiteName)
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
            // Recorded as an Error, not a String: only `Issue.record(some
            // Error)` puts the text on the primary failure line, and here the
            // text — what the write actually reported — is the whole finding.
            Issue.record(UnexpectedWriteOutcome(expected: "partial", actual: outcome))
            return
        }
        #expect(written > 0)
        #expect(written < payload.count)
    }

    /// The unwritable descriptor is a **live, read-only** fd this test owns,
    /// never a number it just closed — and that is not fussiness.
    ///
    /// All test targets compile into one process and Swift Testing runs suites
    /// in parallel, so a number closed here can be handed straight to a
    /// concurrent test's socket, file or pipe before the write below runs. The
    /// earlier version of this test wrote `"x"` into that stranger's
    /// descriptor and read back `.complete` — a flake and a cross-test
    /// corruption source in one. An fd held open for the duration cannot be
    /// reissued, and `write(2)` against `O_RDONLY` is `EBADF` just the same.
    @Test("an unwritable descriptor is a failure, and an absent one writes nothing")
    func deadDescriptorsAreReported() throws {
        let readOnly = Darwin.open("/dev/null", O_RDONLY)
        try #require(readOnly >= 0)
        defer { Darwin.close(readOnly) }

        let outcome = PTYWrite.all(Data("x".utf8), to: readOnly)
        guard case .failed = outcome else {
            Issue.record(UnexpectedWriteOutcome(expected: "failed", actual: outcome))
            return
        }
        #expect(PTYWrite.all(Data("x".utf8), to: -1) == .nothingWritten)
        #expect(PTYWrite.all(Data(), to: -1) == .complete, "an empty write asks nothing of the fd")
    }
}

/// What `PTYWrite.all` was supposed to report, and what it did.
///
/// An `Error` rather than a string so `Issue.record` puts it on the primary
/// failure line: `#expect(_, "…")` and `Issue.record(String)` both demote the
/// message to a trailing line CI summaries drop, and here the outcome IS the
/// finding.
private struct UnexpectedWriteOutcome: Error, CustomStringConvertible {
    let expected: String
    let actual: PTYWrite.Outcome

    var description: String {
        "PTYWrite.all must report \(expected), reported \(actual)"
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
