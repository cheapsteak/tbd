import AppKit
import Darwin
import Foundation
import SwiftTerm
import TBDShared
import TBDTerminalSerialization
import Testing

@testable import TBDApp
import TestSupport

/// The viewer's half of the handback: closing the descriptor, serializing the
/// screen, and only then telling the daemon.
///
/// **The ordering is the point, and it is asserted as an ordering rather than
/// as two facts.** The daemon puts a drain back on the pty the moment
/// `pane.detach` arrives, so a detach sent before this process was off the fd
/// would mean two readers on one pty — silent byte theft, which nothing
/// reports. Every test here that touches the order therefore observes the
/// descriptor's state *at the instant the detach call is made*, from inside the
/// stub that receives it: the panel is handed one end of a `socketpair`, and the
/// test holds the other, where a `read` returning 0 means every copy of the
/// peer end in this process is closed. A `read` that would block instead means
/// the panel is still on it.
///
/// Tier 2: a real `TBDTerminalView`, the real reader thread, the real
/// serialization — no daemon, no tmux, no pty.
@Suite("A holder panel hands its session back when it detaches", .timeLimit(.minutes(2)))
struct HolderDetachHandbackTests {

    private static let generation: UInt64 = 11

    /// What the panel had done to its descriptor at the moment it notified.
    private enum DescriptorState: Equatable, Sendable {
        /// A `read` on the far end returned 0: every copy of the near end in
        /// this process is closed.
        case closed
        /// A `read` on the far end would have blocked: the panel is still on it.
        case stillOpen
        /// Neither — recorded rather than asserted away, so a fixture failure
        /// cannot masquerade as a passing ordering check.
        case unreadable(errno: Int32)
    }

    private struct DetachCall: Sendable {
        let worktreeID: UUID
        let paneID: String
        let terminalID: UUID
        let generation: UInt64
        let preamble: Data
        let descriptorState: DescriptorState
    }

    /// Stands in for the daemon's three holder RPCs, and probes the panel's
    /// descriptor at the instant the detach arrives.
    private final class StubHolderAttach: HolderAttaching, @unchecked Sendable {
        private let lock = NSLock()
        private var detachStorage: [DetachCall] = []
        private var readyStorage = 0
        private let attachment: HolderAttachment
        private let readyOutcome: @Sendable () throws -> Void
        /// Reads the far end of the panel's descriptor. Set by the fixture.
        var descriptorProbe: (@Sendable () -> DescriptorState)?

        init(
            attachment: HolderAttachment,
            ready: @escaping @Sendable () throws -> Void = {}
        ) {
            self.attachment = attachment
            self.readyOutcome = ready
        }

        var detaches: [DetachCall] { lock.withLock { detachStorage } }
        var readyCalls: Int { lock.withLock { readyStorage } }

        func attach(
            worktreeID: UUID, paneID: String, terminalID: UUID
        ) async throws -> HolderAttachment { attachment }

        func ready(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
        ) async throws {
            lock.withLock { readyStorage += 1 }
            try readyOutcome()
        }

        func detach(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
            snapshotPreamble: Data
        ) async throws {
            let state = descriptorProbe?() ?? .unreadable(errno: 0)
            lock.withLock {
                detachStorage.append(
                    DetachCall(
                        worktreeID: worktreeID, paneID: paneID, terminalID: terminalID,
                        generation: generation, preamble: snapshotPreamble,
                        descriptorState: state))
            }
        }
    }

    /// A panel attached to one end of a `socketpair`, with the other end kept
    /// here to play the session — and, at detach time, to answer whether the
    /// panel is still on its descriptor.
    ///
    /// A `socketpair` rather than the pipe the neighbouring suites use, for one
    /// reason: the far end must report the near end's *close* without raising
    /// `SIGPIPE`, and a `read` returning 0 does exactly that. Asking whether an
    /// fd number is still open would be the same question answered by a number
    /// the kernel is free to reissue.
    @MainActor
    private final class Fixture {
        let state: AppState
        let coordinator: TerminalPanelRepresentable.Coordinator
        let view: TBDTerminalView
        let stub: StubHolderAttach
        let worktreeID: UUID
        let terminalID: UUID
        private let sessionEnd: Int32
        /// The end handed to the panel. Kept so a test can read the flags the
        /// attach set on it; the panel's reader still owns the close.
        let vendedEnd: Int32
        private let defaults: UserDefaults
        private let suiteName: String

        init(preamble: String = "", readyFails: Bool = false) throws {
            var pair: [Int32] = [-1, -1]
            #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            let vended = pair[0]
            vendedEnd = vended
            sessionEnd = pair[1]
            // **Close-on-exec on both ends, at creation.** Every test target in
            // this package links into one process and Swift Testing runs their
            // suites in parallel, and two suites in this very target keep
            // `/bin/sleep 120` children alive for the rest of the run
            // (`TerminalTeardownReapTests`, `QuietIngestTests`). A `socketpair`
            // is inheritable, `startProcess` is a `forkpty` that closes nothing,
            // and the attach's own `fcntl` cannot run until this initializer has
            // returned and the attach has been scheduled — so a fixture that
            // left the flag to the attach leaves a window in which any sibling
            // spawn inherits the vended end and holds it for the rest of the
            // run. `descriptorState` then reads `.stillOpen` after a panel that
            // closed both of its own copies in the right order, which is a
            // false failure about somebody else's child. Measured on CI, and
            // `anInheritableDescriptorIsHeldOpenByAChildSpawnedBesideIt` below
            // pins the mechanism.
            _ = fcntl(vended, F_SETFD, FD_CLOEXEC)
            _ = fcntl(sessionEnd, F_SETFD, FD_CLOEXEC)
            // The real vend is a `dup` of a pty the daemon opened `O_NONBLOCK`,
            // and the flag rides the dup; a reader that blocks would spin.
            _ = fcntl(vended, F_SETFL, fcntl(vended, F_GETFL, 0) | O_NONBLOCK)
            _ = fcntl(sessionEnd, F_SETFL, fcntl(sessionEnd, F_GETFL, 0) | O_NONBLOCK)

            worktreeID = UUID()
            terminalID = UUID()
            state = AppState()
            state.terminals[worktreeID] = [Terminal(
                id: terminalID, worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "",
                label: "Shell", kind: .shell, transport: .holder)]

            suiteName = "TBDAppTests.HolderDetachHandback.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            view = TBDTerminalView(
                frame: CGRect(x: 0, y: 0, width: 600, height: 300),
                font: TBDTerminalView.defaultMonospaceFont,
                appearance: AppearanceSettings(defaults: defaults))

            stub = StubHolderAttach(
                attachment: HolderAttachment(
                    ptyFD: vended,
                    generation: HolderDetachHandbackTests.generation,
                    snapshotPreamble: Data(preamble.utf8)),
                ready: {
                    if readyFails {
                        throw DaemonClientError.rpcError("attach.ready refused", code: nil)
                    }
                })
            let far = sessionEnd
            stub.descriptorProbe = {
                var byte: UInt8 = 0
                let read = Darwin.read(far, &byte, 1)
                if read == 0 { return .closed }
                if read < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return .stillOpen }
                return .unreadable(errno: read < 0 ? errno : -1)
            }

            coordinator = TerminalPanelRepresentable.Coordinator()
            coordinator.appState = state
            coordinator.panelID = terminalID
            coordinator.holderAttachClient = stub
            // Both halves of what `makeNSView` wires, and both are
            // load-bearing here: the coordinator serializes the view it holds,
            // and the view routes its terminal's replies back to the
            // coordinator — which is the only path the handback's DECRQM
            // answers can take.
            coordinator.terminalView = view
            view.terminalDelegate = coordinator
        }

        func attach() async {
            await coordinator.startHolderClient(terminalView: view)
        }

        /// Clears `FD_CLOEXEC` on the vended end, for the one test whose
        /// subject is the flag itself.
        ///
        /// The fixture sets it at creation so no sibling suite's child can
        /// inherit this session (see `init`), but an assertion that *the attach*
        /// sets it is worth nothing against a descriptor that already had it.
        /// A real hand-over arrives without it — darwin has no
        /// `MSG_CMSG_CLOEXEC`, so nothing can be asked of `recvmsg` — and this
        /// reproduces that starting state for the length of one attach.
        func makeVendedEndInheritable() {
            _ = fcntl(vendedEnd, F_SETFD, 0)
        }

        /// Plays the session: bytes the child would have written.
        func sessionWrites(_ text: String) {
            let bytes = [UInt8](text.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(sessionEnd, $0.baseAddress, $0.count) }
        }

        /// One viewport row, read through the production locked accessor.
        func rowText(_ row: Int) -> String {
            view.withTerminal { $0.getLine(row: row)?.translateToString(trimRight: true) ?? "" }
        }

        func tearDown() {
            coordinator.cleanup()
            if sessionEnd >= 0 { Darwin.close(sessionEnd) }
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// Replays a handback preamble into a terminal that has never seen the
    /// session — the only honest test of one, because it asserts on what the
    /// receiver would paint rather than on the bytes that were emitted.
    private final class HeadlessReplay {
        private let terminal: SwiftTerm.Terminal
        private let delegate = CollectingDelegate()

        init(columns: Int = 80, rows: Int = 24) {
            terminal = SwiftTerm.Terminal(
                delegate: delegate, options: TerminalOptions(cols: columns, rows: rows))
            delegate.terminal = terminal
        }

        func feed(_ data: Data) {
            terminal.terminalLock.withLock { terminal.feed(byteArray: [UInt8](data)) }
        }

        func screenText() -> String {
            terminal.terminalLock.withLock {
                var lines: [String] = []
                for row in 0..<terminal.rows {
                    lines.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
                }
                while let last = lines.last, last.isEmpty { lines.removeLast() }
                return lines.joined(separator: "\n")
            }
        }

        /// The receiver's mode state, read the way the daemon reads its own —
        /// synchronously, because a headless terminal calls its delegate
        /// straight out of the parser.
        func capturedState() -> CapturedTerminalState {
            terminal.terminalLock.withLock {
                TerminalModeCapture.capture(from: terminal, reply: delegate)
            }
        }
    }

    /// Collects replies and answers `DECRQM` synchronously. Retained by
    /// `HeadlessReplay` because `Terminal.tdel` is weak.
    private final class CollectingDelegate: TerminalDelegate, ModeReplyReader {
        weak var terminal: SwiftTerm.Terminal?
        private var bytes: [UInt8] = []

        func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {
            bytes.append(contentsOf: data)
        }

        func requestMode(_ mode: Int, decPrivate: Bool) -> Int? {
            guard let terminal else { return nil }
            bytes.removeAll()
            let prefix = decPrivate ? "?" : ""
            terminal.feed(text: "\u{1b}[\(prefix)\(mode)$p")
            let reply = String(bytes: bytes, encoding: .utf8) ?? ""
            guard let head = reply.range(of: "\u{1b}[\(prefix)\(mode);"),
                  let tail = reply[head.upperBound...].range(of: "$y") else { return nil }
            return Int(reply[head.upperBound..<tail.lowerBound])
        }
    }

    @MainActor
    private func waitForDetach(_ fixture: Fixture) async throws {
        try await waitFor(
            "the panel's detach to reach the daemon",
            observed: { "\(fixture.stub.detaches.count) detaches" }
        ) {
            await MainActor.run { !fixture.stub.detaches.isEmpty }
        }
    }

    // MARK: - The order

    @MainActor
    @Test("the panel is off its descriptor before it tells the daemon it detached")
    func theDescriptorIsClosedBeforeTheDetachIsSent() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        await fixture.attach()
        #expect(fixture.stub.readyCalls == 1, "the attach must have completed for a detach to mean anything")

        fixture.coordinator.cleanup()
        try await waitForDetach(fixture)

        let detach = try #require(fixture.stub.detaches.first)
        #expect(detach.descriptorState == .closed, """
            the detach was sent while this process still held the pty: the daemon resumes its \
            drain on receipt, so the app's last read() would have raced it — two readers on one \
            pty, which nothing reports
            """)
        #expect(detach.generation == Self.generation)
        #expect(detach.terminalID == fixture.terminalID)
        #expect(detach.worktreeID == fixture.worktreeID)
    }

    /// A session descriptor must not survive an `exec`, and the reason is the
    /// same one the row above asserts from the other side: a child that
    /// inherited a copy holds the session open after the handback, so the far
    /// end never sees the close no matter how carefully this process orders
    /// its own. That failure is invisible until some sibling suite happens to
    /// spawn a long-lived child inside the attach window — it reached CI as
    /// `.stillOpen` — so the flag is asserted directly rather than left to
    /// whichever test the timing happens to redden.
    @MainActor
    @Test("the attach leaves nothing about the session inheritable across an exec")
    func theVendedDescriptorIsCloseOnExec() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        // Inheritable when it arrives — a descriptor received over `SCM_RIGHTS`
        // is, because darwin has no `MSG_CMSG_CLOEXEC` to ask otherwise — which
        // is what makes the attach's own `fcntl` the thing under test rather
        // than a tautology. Asked for deliberately, and only here: the fixture
        // creates its pair close-on-exec so no sibling suite's child can inherit
        // a test's session, and this is the one row for which that starting
        // state would be the wrong one.
        fixture.makeVendedEndInheritable()
        #expect(fcntl(fixture.vendedEnd, F_GETFD) & FD_CLOEXEC == 0,
                "the fixture must hand over an inheritable descriptor, or this test is vacuous")

        await fixture.attach()

        #expect(fcntl(fixture.vendedEnd, F_GETFD) & FD_CLOEXEC != 0,
                "the panel must not leave a session's pty inheritable by every child it spawns")
    }

    /// **Why the fixture creates its socketpair close-on-exec**, measured on
    /// the same shape of child that produced the false failure on CI.
    ///
    /// `descriptorState` asks the far end whether the near end is gone, and a
    /// socket end is gone only when *every* copy of it is closed — including
    /// copies in other processes. Two suites in this target keep `/bin/sleep
    /// 120` children alive for the rest of the run, started through the same
    /// `LocalProcess.startProcess` used here, which is a `forkpty` that closes
    /// nothing: a child spawned while a test's descriptor is inheritable holds
    /// that descriptor until the run ends, and the far end never reports the
    /// close however correctly the panel ordered its own.
    ///
    /// Both legs run, and each is the other's control: the failure only means
    /// something because the same sequence with the flag set reports the close.
    @MainActor
    @Test("a descriptor left inheritable is held open by a child spawned beside it")
    func anInheritableDescriptorIsHeldOpenByAChildSpawnedBesideIt() async throws {
        #expect(
            Self.farEndReportsCloseAfterSpawningAChild(closeOnExec: true),
            """
            a close-on-exec descriptor was still held after this process closed its only copy, \
            so the fixture's flag buys nothing and the false failure it prevents has some other \
            cause
            """)
        #expect(
            !Self.farEndReportsCloseAfterSpawningAChild(closeOnExec: false),
            """
            an inheritable descriptor was NOT held open by a child spawned beside it, so children \
            in this process no longer inherit and this suite's premise has changed
            """)
    }

    /// Closes this process's only copy of one end of a `socketpair` with a
    /// freshly spawned `/bin/sleep` alongside, and reports whether the far end
    /// sees the close. The child is killed and reaped before returning.
    @MainActor
    private static func farEndReportsCloseAfterSpawningAChild(closeOnExec: Bool) -> Bool {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return false }
        let near = pair[0]
        let far = pair[1]
        _ = fcntl(far, F_SETFL, fcntl(far, F_GETFL, 0) | O_NONBLOCK)
        // The far end is never the subject: a child holding *it* would not stop
        // the near end's close from being reported, and leaving it inheritable
        // would leak this probe's descriptor into every later spawn.
        _ = fcntl(far, F_SETFD, FD_CLOEXEC)
        if closeOnExec { _ = fcntl(near, F_SETFD, FD_CLOEXEC) }

        let process = LocalProcess(
            delegate: InheritanceProbeDelegate(), dispatchQueue: .main, directDelivery: true)
        process.startProcess(executable: "/bin/sleep", args: ["30"], environment: nil, execName: nil)
        let childPID = process.shellPid

        // From here this process holds nothing: whatever keeps the far end from
        // reporting a close is somebody else's copy.
        Darwin.close(near)

        // Polled rather than read once. `posix_spawn` is a single syscall on
        // darwin and a `forkpty` child reaches `execv` in microseconds, but a
        // probe that decided on the first read would be deciding on scheduling.
        var reportedClose = false
        for _ in 0..<200 {
            var byte: UInt8 = 0
            if Darwin.read(far, &byte, 1) == 0 {
                reportedClose = true
                break
            }
            usleep(5_000)
        }

        // Disposed of before returning, and unconditionally: a `sleep 30` this
        // probe started is one no production path under test ever ends.
        if childPID > 0 {
            kill(childPID, SIGKILL)
            ChildReaper.reapBlocking(pid: childPID)
        }
        Darwin.close(far)
        return reportedClose
    }

    /// The minimum a `LocalProcess` needs to start a child. The probe reads
    /// nothing off the child's tty and cares only that it exists.
    private final class InheritanceProbeDelegate: LocalProcessDelegate, @unchecked Sendable {
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
        func dataReceived(slice: ArraySlice<UInt8>) {}
        func getWindowSize() -> winsize {
            winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        }
    }

    // MARK: - The screen, out and back

    @MainActor
    @Test("the handback carries the screen the panel was showing")
    func theHandbackCarriesTheScreen() async throws {
        // The screen goes out as an attach preamble and comes back as a detach
        // one, through the same writer in both directions.
        let fixture = try Fixture(preamble: "FROM-THE-DAEMON\r\n")
        defer { fixture.tearDown() }
        await fixture.attach()

        fixture.sessionWrites("WHILE-ATTACHED\r\n")
        try await waitFor(
            "the session's live output to paint",
            observed: { await MainActor.run { fixture.rowText(1) } }
        ) {
            await MainActor.run { fixture.rowText(1) == "WHILE-ATTACHED" }
        }

        fixture.coordinator.cleanup()
        try await waitForDetach(fixture)

        let detach = try #require(fixture.stub.detaches.first)
        #expect(!detach.preamble.isEmpty, "a detach with no screen leaves the daemon frozen")
        let replay = HeadlessReplay()
        replay.feed(detach.preamble)
        let painted = replay.screenText()
        #expect(painted.contains("FROM-THE-DAEMON"), """
            the screen the daemon handed over did not come back: \(painted)
            """)
        #expect(painted.contains("WHILE-ATTACHED"), """
            what the session wrote while the viewer owned it did not come back: \(painted)
            """)
        // The other direction of the same probe, and the one that corrupts a
        // screen rather than losing an option: this panel changed no modes, so
        // the two whose default is ON must come back ON. A handback whose
        // DECRQM answers never arrived reports every mode "reset", which hands
        // the daemon autowrap off and the cursor hidden — and no assertion on a
        // mode the test itself turned *off* can see that.
        let state = replay.capturedState()
        #expect(state.wraparound, "the handback turned autowrap off on a session that had it on")
        #expect(state.cursorVisible, "the handback hid the cursor on a session that had it visible")
    }

    /// The last chunk, which nobody else will ever see again.
    ///
    /// A byte read off the pty is gone from it, so output the reader takes
    /// *after* a stop has been raised is lost outright unless it reaches this
    /// terminal — the daemon cannot re-read what this process already
    /// consumed. The session therefore writes **after** the teardown, into the
    /// window where the reader is still parked in `poll` with its stop flag up:
    /// it wakes, reads, and the two properties under test are that it feeds
    /// what it read rather than discarding it, and that the sink is still
    /// there to receive it.
    ///
    /// The window is one poll interval wide (200 ms) and the write lands
    /// microseconds after `cleanup()` returns, so the reader is essentially
    /// always still in it. A run that lost that race would read nothing at all
    /// and fail; it does not pass for the wrong reason.
    @MainActor
    @Test("output taken off the pty as the panel closes still reaches the handback")
    func theLastChunkIsNotDropped() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        await fixture.attach()

        fixture.coordinator.cleanup()
        fixture.sessionWrites("LAST-GASP\r\n")
        try await waitForDetach(fixture)

        let detach = try #require(fixture.stub.detaches.first)
        let replay = HeadlessReplay()
        replay.feed(detach.preamble)
        #expect(replay.screenText().contains("LAST-GASP"), """
            output the reader had already taken off the pty was dropped on the way out — no other \
            reader can ever see those bytes: \(replay.screenText())
            """)
    }

    @MainActor
    @Test("the handback carries the modes the viewer's terminal was in")
    func theHandbackCarriesTheModes() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        await fixture.attach()

        // A state no default terminal is in, and deliberately including two
        // modes whose default is ON: an unanswered DECRQM reads as "reset", so
        // wraparound and cursor-visible are where a probe that returns nothing
        // corrupts the screen rather than merely losing an option.
        //
        // The scroll region is kept well inside the grid — the view's row count
        // comes from its frame and its font metrics, and DECSTBM whose bottom
        // exceeds the grid is ignored outright, which would make this fixture
        // assert nothing while looking correct.
        //
        // **Written repeatedly until it sticks**, which is a property of the
        // view rather than a timing fudge: SwiftTerm defers a frame-driven
        // resize to a later turn, and `Buffer.resize` rebuilds the scroll
        // region from the new geometry — `scrollTop = 0`, `scrollBottom =
        // rows - 1` — so a resize landing after the session's DECSTBM wipes
        // exactly the state the settle condition below checks for. The loop is
        // bounded and the assertion below is on the state that was actually
        // observed.
        var settled = false
        for _ in 0..<40 where !settled {
            fixture.sessionWrites(
                "\u{1b}[?7l\u{1b}[?25l\u{1b}[?1004h\u{1b}[?1006h\u{1b}[4h\u{1b}[3;10rMODES-SET")
            try? await Task.sleep(for: .milliseconds(50))
            settled = fixture.view.withTerminal { $0.buffer.scrollTop } == 2
                && fixture.rowText(0).contains("MODES-SET")
        }
        #expect(settled, """
            the session's mode changes never reached the panel's terminal, so the handback below \
            would assert nothing: row0=\(fixture.rowText(0)) \
            scrollTop=\(fixture.view.withTerminal { $0.buffer.scrollTop })
            """)

        fixture.coordinator.cleanup()
        try await waitForDetach(fixture)

        let detach = try #require(fixture.stub.detaches.first)
        let replay = HeadlessReplay()
        replay.feed(detach.preamble)
        let state = replay.capturedState()
        #expect(state.wraparound == false, "autowrap off did not survive the handback")
        #expect(state.cursorVisible == false, "a hidden cursor did not survive the handback")
        #expect(state.focusReporting == true, "focus reporting did not survive the handback")
        #expect(state.sgrMouseEncoding == true, "SGR mouse encoding did not survive the handback")
        #expect(state.insertMode == true, "insert mode did not survive the handback")
        #expect(state.scrollTop == 2 && state.scrollBottom == 9,
                "the scroll region did not survive the handback: \(state.scrollTop)-\(state.scrollBottom)")
    }

    /// The mode probe is a batch, so every answer arrives concatenated with
    /// every other one. Anchoring on the CSI introducer is what keeps mode 7
    /// from being read out of mode 1007's answer — asserted directly, because
    /// the whole-panel test above would still pass if two modes happened to
    /// agree.
    @Test("a batched mode reply is read per mode, not by substring")
    func recordedRepliesAreAnchoredOnTheIntroducer() {
        let replies = RecordedModeReplies(
            bytes: [UInt8]("\u{1b}[?1007;1$y\u{1b}[?7;2$y\u{1b}[?25;1$y\u{1b}[4;1$y".utf8))
        #expect(replies.requestMode(7, decPrivate: true) == 2)
        #expect(replies.requestMode(1007, decPrivate: true) == 1)
        #expect(replies.requestMode(25, decPrivate: true) == 1)
        #expect(replies.requestMode(4, decPrivate: false) == 1)
        #expect(replies.requestMode(69, decPrivate: true) == nil)
    }

    // MARK: - The viewer state a detach must release

    /// A paste lease outliving its panel is not a leak of memory but of
    /// *meaning*: the daemon waits for a paste that can never close, and every
    /// injection it holds waits with it.
    @MainActor
    @Test("a detach releases the paste lease and every injection held behind it")
    func aDetachReleasesThePasteLease() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        await fixture.attach()

        // Opened through the production classifier — the marker goes in as its
        // own chunk, exactly as SwiftTerm delivers it — rather than by calling
        // `beginUserPaste()`, which would bypass the detection entirely.
        fixture.coordinator.send(source: fixture.view, data: EscapeSequences.bracketedPasteStart[...])
        #expect(fixture.coordinator.outgoingQueueForTesting.isPasteOpenForTesting,
                "the fixture never opened a paste, so the release below would prove nothing")

        // Routed the way the daemon routes one: through this panel's claim on
        // the session, which is itself part of what a detach releases.
        let injections = fixture.state.terminalInjections
        let terminalID = fixture.terminalID
        let held = Task.detached {
            await injections.deliver(terminalID: terminalID, bytes: Data("prompt\r".utf8))
        }
        try await waitFor(
            "the injection to be parked behind the open paste",
            observed: {
                await MainActor.run {
                    "\(fixture.coordinator.outgoingQueueForTesting.pendingInjectionCountForTesting)"
                }
            }
        ) {
            await MainActor.run {
                fixture.coordinator.outgoingQueueForTesting.pendingInjectionCountForTesting == 1
            }
        }

        fixture.coordinator.cleanup()

        #expect(await held.value == false, """
            an injection released by the detach must report unwritten — nothing was written for it, \
            and an ack here would lose the prompt invisibly
            """)
        #expect(fixture.coordinator.outgoingQueueForTesting.isPasteOpenForTesting == false,
                "the paste lease outlived the panel that could have closed it")
        #expect(fixture.coordinator.outgoingQueueForTesting.pendingInjectionCountForTesting == 0)
    }

    /// The placement, discriminated: the release is tied to **losing the pty**,
    /// not to the view being torn down. A refused `attach.ready` ends this
    /// panel's ownership with the panel still very much alive and `cleanup()`
    /// never called — so a lease released only in teardown would still be open
    /// here, on a panel that can no longer write a byte.
    @MainActor
    @Test("a panel that loses the pty releases the paste lease without a teardown")
    func losingThePtyReleasesThePasteLease() async throws {
        let fixture = try Fixture(readyFails: true)
        defer { fixture.tearDown() }

        fixture.coordinator.send(source: fixture.view, data: EscapeSequences.bracketedPasteStart[...])
        #expect(fixture.coordinator.outgoingQueueForTesting.isPasteOpenForTesting,
                "the fixture never opened a paste, so the release below would prove nothing")

        await fixture.attach()

        #expect(fixture.stub.readyCalls == 1, "the attach must have been refused for this to mean anything")
        #expect(fixture.coordinator.outgoingQueueForTesting.isPasteOpenForTesting == false, """
            the paste lease outlived this panel's ownership of the pty: it is released only on \
            teardown, so a refused attach leaves the daemon waiting on a paste nobody can close
            """)
    }

    // MARK: - What a detach must NOT do

    /// A viewer the daemon refused never owned the session, so there is nothing
    /// to hand back — and a detach naming an attach the daemon did not confirm
    /// would be refused by its generation check anyway.
    @MainActor
    @Test("a panel whose attach.ready was refused sends no detach")
    func aRefusedAttachSendsNoDetach() async throws {
        let fixture = try Fixture(readyFails: true)
        defer { fixture.tearDown() }
        await fixture.attach()

        fixture.coordinator.cleanup()
        // Long enough for a detach task to have run: the reader's poll interval
        // is 200 ms, and the assertion is that nothing arrives at all.
        try? await Task.sleep(for: .milliseconds(600))

        #expect(fixture.stub.readyCalls == 1)
        #expect(fixture.stub.detaches.isEmpty, """
            a panel the daemon refused sent a handback anyway; it never owned the pty
            """)
    }
}
