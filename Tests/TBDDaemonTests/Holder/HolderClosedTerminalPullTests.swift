import Clocks
import Darwin
import Foundation
import TBDShared
import Testing

@testable import TBDDaemonLib
import TestSupport

/// The final screen of a tab somebody had open, written into Closed Terminals
/// history at disposal.
///
/// The daemon's emulator has been frozen since the viewer attached, so the half
/// of this that was already shipped writes the session id alone rather than
/// present a stale screen as a session's last one. These are the cases the pull
/// adds and the cases it must not break:
///
/// - a viewer that answers contributes **its** capture, and the daemon's frozen
///   one never reaches the file;
/// - a daemon that is reading captures locally and **sends no frame**, which is
///   what keeps a fleet of detached sessions closing off this path entirely;
/// - a pull that expires, is refused, or cannot be delivered each lands back on
///   the shipped behaviour, and the dispose completes regardless;
/// - the file is the same shape whichever store answered.
///
/// Driven against a real `HolderReader` over a socketpair, because the daemon's
/// own answer comes from its drain state and a fake reader would be testing the
/// fake. The viewer is a double: reaching a real one needs a real app, a real
/// attach and a real pty for what is a question about which store gets asked.
/// Every bound runs on a `TestClock`, so nothing sleeps.
@Suite("Closed Terminals for a viewed tab", .clockDriven, .serialized)
struct HolderClosedTerminalPullTests {

    private static let esc = "\u{1b}"

    /// What the daemon's emulator holds, seeded before the reader starts.
    /// Present in the file on the detached path and absent on the viewed one —
    /// which is what makes "the viewer's capture" an assertion rather than a
    /// coincidence.
    private static let seed =
        "first plain line\r\n\(esc)[31mred marker line\(esc)[0m\r\nlast line"

    /// What the viewer hands back, already in the shape the history store
    /// records (`ViewerScreenProducer` applies it at the producer).
    private static let viewerCapture =
        "what the person was looking at\n\(esc)[32mgreen tail\(esc)[0m\n\(esc)[0m\n"

    // MARK: - Fixture

    private struct Fixture {
        let db: TBDDatabase
        let historyDir: String
        let terminal: Terminal

        func contentPath() -> String {
            db.terminalHistory.contentPath(
                worktreeID: terminal.worktreeID, terminalID: terminal.id)
        }

        func capturedText() throws -> String? {
            guard FileManager.default.fileExists(atPath: contentPath()) else { return nil }
            return try String(contentsOfFile: contentPath(), encoding: .utf8)
        }

        func entries() async throws -> [TerminalHistoryEntry] {
            try await db.terminalHistory.list(worktreeID: terminal.worktreeID)
        }

        func cleanup() {
            try? FileManager.default.removeItem(atPath: historyDir)
        }
    }

    /// A holder-transport Claude row, created through the same store call the
    /// spawn path uses.
    private func makeFixture() async throws -> Fixture {
        let historyDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tbd-holder-pull-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: historyDir, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true, terminalHistoryDir: historyDir)
        let repo = try await db.repos.create(
            path: "/tmp/acme-holder-pull-\(UUID().uuidString)",
            displayName: "acme", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/acme-holder-pull-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-holder-pull")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holder-pull",
            kind: .claude, transport: .holder, holderPID: nil, childPID: 0)
        return Fixture(db: db, historyDir: historyDir, terminal: terminal)
    }

    /// A reader over one end of a socketpair, seeded with coloured output
    /// before it starts — `ingest` must run with nothing else feeding the
    /// emulator, which before `start()` is guaranteed.
    private func makeSeededReader(sessionID: UUID) async throws -> (HolderReader, Int32) {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let reader = HolderReader(
            sessionID: sessionID, ptyFD: pair[0], columns: 80, rows: 24,
            scrollbackLines: 200, observedChildFromStart: true)
        await reader.ingest(preamble: Data(Self.seed.utf8))
        try await reader.start()
        return (reader, pair[1])
    }

    /// The same reader, frozen the way an attach freezes it: the viewer takes a
    /// duplicate of the pty and the daemon's drain stops. The seeded screen is
    /// still in the emulator, which is what makes its absence from the file a
    /// decision rather than an empty model.
    private func suspend(_ reader: HolderReader) async throws {
        let duplicate = try await reader.suspendDraining()
        close(duplicate)
        #expect(await reader.renderScreen().contains("red marker line"))
    }

    // MARK: - The sidecar double

    private struct SidecarNotConnected: Error {}

    /// A send-counting sidecar. The count is the instrument for the negative
    /// assertion that matters most here — a detached session closing must not
    /// go near the app — and the frames are how the request itself is read back.
    private final class Sidecar: @unchecked Sendable {
        private let lock = NSLock()
        private var sentFrames: [Data] = []

        /// When set, the send throws it: a daemon with no connected app.
        var sendError: Error?

        var frames: [Data] { lock.withLock { sentFrames } }
        var sendCount: Int { lock.withLock { sentFrames.count } }

        func makePull(clock: any Clock<Duration>) -> HolderScreenPull {
            HolderScreenPull(
                sendFrame: { [self] frame in
                    if let sendError { throw sendError }
                    lock.withLock { sentFrames.append(frame) }
                    return 1
                },
                clock: clock)
        }

        /// The request the resolver put on the wire, parsed back off it.
        func decodeRequest() throws -> SidecarScreenRequest {
            let scanner = SidecarFrameScanner()
            let parsed = scanner.append(try #require(frames.first))
            let frame = try #require(parsed.first)
            #expect(SidecarFrameType(rawValue: frame.type) == .screenRequest)
            return try SidecarFrameCodec.decodeScreenRequest(payload: frame.payload)
        }
    }

    private static func resolver(
        role: PtyReaderRole?, pull: HolderScreenPull?
    ) -> HolderScreenResolver {
        HolderScreenResolver(
            ptyReader: { _ in role },
            // Unused on the disposal path: the daemon's own answer is its
            // reader's styled capture, which the caller hands in, and a typed
            // screen cannot carry colours anyway.
            daemonStore: { _ in nil },
            pull: pull,
            retainedScrollbackLines: 5_000)
    }

    private static func payload() -> ViewerScreenPayload {
        ViewerScreenPayload(
            lines: [], viewportStart: 0, cursorRow: 0, cursorColumn: 0,
            cursorVisible: true, cursorVisibleObserved: false,
            columns: 80, rows: 24,
            bracketedPaste: false, applicationCursor: false, alternateScreen: false,
            ageMilliseconds: 3)
    }

    // MARK: - A viewer answers

    @Test("a viewed tab's entry carries the viewer's screen, not the frozen one")
    func viewedTabEntryCarriesTheViewersScreen() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        let (reader, ours) = try await makeSeededReader(sessionID: fx.terminal.id)
        defer { close(ours) }
        try await suspend(reader)

        let sidecar = Sidecar()
        let pull = sidecar.makePull(clock: TestClock())
        let resolver = Self.resolver(role: .viewer(attach: 4), pull: pull)

        let dispose = Task {
            await WorktreeLifecycle.recordHolderClosedTerminal(
                fx.terminal, reader: reader, resolver: resolver,
                history: fx.db.terminalHistory)
        }
        try await waitFor("the screen request to reach the sidecar") { sidecar.sendCount == 1 }

        let request = try sidecar.decodeRequest()
        #expect(request.terminalID == fx.terminal.id)
        #expect(request.wantStyledCapture, "a history entry wants colours, which a screen cannot carry")
        #expect(request.lines == 0, "the typed screen is not what a dispose came for")
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: fx.terminal.id,
                screen: Self.payload(), styledCapture: Self.viewerCapture),
            epoch: 1)
        await dispose.value
        await reader.stop()

        let entry = try #require(try await fx.entries().first)
        #expect(entry.claudeSessionID == "sess-holder-pull")
        #expect(entry.lineCount > 0)
        let captured = try #require(try fx.capturedText())
        #expect(captured == Self.viewerCapture, "the viewer's capture was reshaped on receipt")
        #expect(!captured.contains("red marker line"),
                "the screen frozen at attach time reached the file")
    }

    // MARK: - The daemon is reading

    /// The ordinary fleet case. The negative assertion is the point: a resolver
    /// that pulled for every disposal would work, and would put a sidecar round
    /// trip inside every one of a thousand detached sessions' closes.
    @Test("a detached session captures from the daemon's reader and sends no frame")
    func detachedSessionCapturesLocallyWithNoFrame() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        let (reader, ours) = try await makeSeededReader(sessionID: fx.terminal.id)
        defer { close(ours) }

        let sidecar = Sidecar()
        let resolver = Self.resolver(
            role: .daemon, pull: sidecar.makePull(clock: TestClock()))

        await WorktreeLifecycle.recordHolderClosedTerminal(
            fx.terminal, reader: reader, resolver: resolver, history: fx.db.terminalHistory)
        await reader.stop()

        let captured = try #require(try fx.capturedText())
        #expect(captured.contains("red marker line"))
        #expect(captured.contains("\(Self.esc)["), "the capture lost its colours")
        #expect(sidecar.sendCount == 0, "a detached session's close must not go near the app")
    }

    // MARK: - The three ways a pull does not answer

    /// The alive-but-silent arm, driven to exactly
    /// `closedTerminalPullBound` on virtual time — which is also what pins the
    /// disposal's tighter bound: a dispose that waited the read bound would
    /// still be pending here.
    @Test("a pull that expires writes the entry without a capture")
    func expiredPullWritesEntryWithoutCapture() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        let (reader, ours) = try await makeSeededReader(sessionID: fx.terminal.id)
        defer { close(ours) }
        try await suspend(reader)

        let sidecar = Sidecar()
        let clock = TestClock<Duration>()
        let resolver = Self.resolver(
            role: .viewer(attach: 4), pull: sidecar.makePull(clock: clock))

        let dispose = Task {
            await WorktreeLifecycle.recordHolderClosedTerminal(
                fx.terminal, reader: reader, resolver: resolver,
                history: fx.db.terminalHistory)
        }
        try await waitFor("the screen request to reach the sidecar") { sidecar.sendCount == 1 }
        await clock.advanceWhenSuspended(by: HolderInputTiming.closedTerminalPullBound)
        await dispose.value
        await reader.stop()

        try await expectSessionIdOnlyEntry(fx)
    }

    /// A refusal the app knows synchronously — no panel claims the session —
    /// ends the wait at once rather than burning the bound. Asserted by never
    /// advancing the clock: a dispose that needed the bound to finish would
    /// hang here.
    @Test("a refused pull writes the entry without a capture")
    func refusedPullWritesEntryWithoutCapture() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        let (reader, ours) = try await makeSeededReader(sessionID: fx.terminal.id)
        defer { close(ours) }
        try await suspend(reader)

        let sidecar = Sidecar()
        let pull = sidecar.makePull(clock: TestClock())
        let resolver = Self.resolver(role: .viewer(attach: 4), pull: pull)

        let dispose = Task {
            await WorktreeLifecycle.recordHolderClosedTerminal(
                fx.terminal, reader: reader, resolver: resolver,
                history: fx.db.terminalHistory)
        }
        try await waitFor("the screen request to reach the sidecar") { sidecar.sendCount == 1 }
        pull.record(
            SidecarScreenReply(
                requestID: try sidecar.decodeRequest().requestID,
                terminalID: fx.terminal.id, unavailable: .noPanel),
            epoch: 1)
        await dispose.value
        await reader.stop()

        try await expectSessionIdOnlyEntry(fx)
    }

    /// No sidecar connection at all: the send throws, and that is an immediate
    /// answer rather than a wait. The clock is never advanced here either.
    @Test("an undeliverable pull writes the entry without a capture")
    func undeliverablePullWritesEntryWithoutCapture() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        let (reader, ours) = try await makeSeededReader(sessionID: fx.terminal.id)
        defer { close(ours) }
        try await suspend(reader)

        let sidecar = Sidecar()
        sidecar.sendError = SidecarNotConnected()
        let resolver = Self.resolver(
            role: .viewer(attach: 4), pull: sidecar.makePull(clock: TestClock()))

        await WorktreeLifecycle.recordHolderClosedTerminal(
            fx.terminal, reader: reader, resolver: resolver, history: fx.db.terminalHistory)
        await reader.stop()

        #expect(sidecar.sendCount == 0)
        try await expectSessionIdOnlyEntry(fx)
    }

    /// What all three fallbacks must leave behind: the entry, with the row's
    /// Claude session id — which is all a revive needs — and no content file,
    /// because a screen frozen at attach time must never be stored as a
    /// session's last one.
    private func expectSessionIdOnlyEntry(_ fx: Fixture) async throws {
        let entry = try #require(try await fx.entries().first)
        #expect(entry.claudeSessionID == "sess-holder-pull",
                "a Claude entry without its session id cannot be revived")
        #expect(entry.lineCount == 0)
        #expect(try fx.capturedText() == nil,
                "a screen frozen at attach time was stored as the final screen")
    }

    // MARK: - One shape, whichever store answered

    /// The producer applies the history shape — `\n` joins, a trailing SGR
    /// reset, `""` for an empty screen — and the daemon forwards what it is
    /// sent. `ViewerScreenProducerTests` pins the viewer's half of that; this
    /// pins the receiving half, which is the one that could reshape: the file
    /// written from a viewer's answer is byte-identical to the file written
    /// from the daemon's own reader over the same bytes.
    @Test("the entry's shape is the same whichever store answered")
    func captureShapeIsIdenticalWhicheverStoreAnswered() async throws {
        let detached = try await makeFixture()
        defer { detached.cleanup() }
        let (draining, drainingOurs) = try await makeSeededReader(sessionID: detached.terminal.id)
        defer { close(drainingOurs) }
        let sidecar = Sidecar()

        await WorktreeLifecycle.recordHolderClosedTerminal(
            detached.terminal, reader: draining,
            resolver: Self.resolver(role: .daemon, pull: sidecar.makePull(clock: TestClock())),
            history: detached.db.terminalHistory)
        // The same walk the viewer runs, over the same bytes — so what goes on
        // the wire below is what a viewer of this session would have sent.
        let asTheViewerWouldSendIt = try #require(await draining.closedTerminalCapture())
        await draining.stop()

        let viewed = try await makeFixture()
        defer { viewed.cleanup() }
        let (suspended, suspendedOurs) = try await makeSeededReader(sessionID: viewed.terminal.id)
        defer { close(suspendedOurs) }
        try await suspend(suspended)
        let pull = sidecar.makePull(clock: TestClock())
        let dispose = Task {
            await WorktreeLifecycle.recordHolderClosedTerminal(
                viewed.terminal, reader: suspended,
                resolver: Self.resolver(role: .viewer(attach: 9), pull: pull),
                history: viewed.db.terminalHistory)
        }
        try await waitFor("the screen request to reach the sidecar") { sidecar.sendCount == 1 }
        pull.record(
            SidecarScreenReply(
                requestID: try sidecar.decodeRequest().requestID,
                terminalID: viewed.terminal.id,
                screen: Self.payload(), styledCapture: asTheViewerWouldSendIt),
            epoch: 1)
        await dispose.value
        await suspended.stop()

        let fromTheDaemon = try #require(try detached.capturedText())
        let fromTheViewer = try #require(try viewed.capturedText())
        #expect(fromTheViewer == fromTheDaemon,
                "the two stores write two shapes of history file")
        #expect(fromTheViewer.hasSuffix("\(Self.esc)[0m\n"))
        #expect(!fromTheViewer.contains("\r\n"))
    }
}
