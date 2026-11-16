import AppKit
import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Tier 2: drives the **real attach entry point** — `Coordinator.startSessionClient`
/// — and requires that a holder-backed panel attaches to the session's pty,
/// and that a panel never attaches a row still on tmux.
///
/// The assertions are about **what ran and what did not**, observed on the
/// production call path:
///
/// - **The session is painted.** The screen the daemon handed back appears in
///   the buffer, and the ack names the attach the daemon minted.
/// - **The ordering the attach depends on.** The preamble goes in through
///   `feedSnapshot`, and the reader is wired only after that feed's ingest
///   window has closed — `feedSnapshot` lowers its flag a main-queue turn
///   after it returns, and everything delivered while it is up is dropped
///   regardless of origin. `attach.ready` is the first thing that happens
///   after the reader exists, so the state observed AT the ack is the
///   observable form of that ordering.
/// - **The refusals.** When the daemon says the attach is unavailable, ended
///   or refused, the placard is what the panel shows.
///
/// **Nothing here talks to a live daemon.** The holder attach goes through an
/// injected `HolderAttaching` stub over a real pipe.
// A hang guard, and it has to clear the bounded waits below, which run to
// `TestDeadlines.saturatedPass` (120 s): a suite limit under that truncates
// their named diagnostic into a bare "Time limit was exceeded" — measured, by
// mutating away `reader.start()`. The shared dial is derived to clear exactly
// that, so it is what this takes rather than a locally chosen two minutes. See
// `.fastPassBounded` in `Tests/TestSupport/ClockTestSupport.swift`.
@Suite("A holder-backed panel attaches to its pty, not to tmux", .fastPassBounded)
struct TerminalHolderTransportGateTests {

    /// What the panel looked like at the instant `attach.ready` was sent.
    private struct ReadyObservation: Sendable {
        /// Must already carry the preamble: it is fed before the ack.
        let firstRow: String
    }

    /// Collects OSC 777 notification titles. Written and read on the main
    /// queue (the view hops there before the engine tells the coordinator),
    /// but the bounded wait reads it from a `@Sendable` closure, so it carries
    /// a lock.
    private final class NotificationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func record(_ title: String) { lock.withLock { storage.append(title) } }
        var titles: [String] { lock.withLock { storage } }
    }

    /// Stands in for the daemon's two attach RPCs. Hands out a real descriptor
    /// (a pipe read end, opened `O_NONBLOCK` exactly like the vended pty) so
    /// the production reader path runs unmodified.
    private final class StubHolderAttach: HolderAttaching, @unchecked Sendable {
        struct ReadyCall: Equatable, Sendable {
            let worktreeID: UUID
            let paneID: String
            let terminalID: UUID
            let generation: UInt64
        }

        private let lock = NSLock()
        private var attachCallCount = 0
        private var readyCallsStorage: [ReadyCall] = []
        private var readyObservationStorage: [ReadyObservation] = []

        private let attachOutcome: @Sendable () throws -> HolderAttachment
        private let readyOutcome: @Sendable () throws -> Void
        /// Reads panel state on the main actor at the moment `ready` runs.
        var readyProbe: (@MainActor @Sendable () -> ReadyObservation)?

        init(
            attach: @escaping @Sendable () throws -> HolderAttachment,
            ready: @escaping @Sendable () throws -> Void = {}
        ) {
            self.attachOutcome = attach
            self.readyOutcome = ready
        }

        var attaches: Int { lock.lock(); defer { lock.unlock() }; return attachCallCount }
        var readyCalls: [ReadyCall] { lock.lock(); defer { lock.unlock() }; return readyCallsStorage }
        var readyObservations: [ReadyObservation] {
            lock.lock(); defer { lock.unlock() }; return readyObservationStorage
        }

        func attach(
            worktreeID: UUID, paneID: String, terminalID: UUID, attachSeq: UInt64,
            grid: (cols: Int, rows: Int)?
        ) async throws -> HolderAttachment {
            lock.withLock { attachCallCount += 1 }
            return try attachOutcome()
        }

        func ready(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
        ) async throws {
            let observation = await readyProbe?()
            lock.withLock {
                readyCallsStorage.append(
                    ReadyCall(
                        worktreeID: worktreeID, paneID: paneID,
                        terminalID: terminalID, generation: generation))
                if let observation { readyObservationStorage.append(observation) }
            }
            try readyOutcome()
        }

        func detach(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
            snapshotPreamble: Data
        ) async throws {}
    }

    /// A pipe standing in for the vended pty: the read end goes to the panel's
    /// reader (which owns and closes it), the write end plays the session.
    private final class FakePTY {
        let readEnd: Int32
        private var writeEnd: Int32

        init() throws {
            var fds: [Int32] = [-1, -1]
            #expect(pipe(&fds) == 0)
            readEnd = fds[0]
            writeEnd = fds[1]
            // The real vend is a `dup` of a pty the daemon opened `O_NONBLOCK`,
            // and the flag lives on the shared open file description, so it
            // rides the dup. Mirror it: a reader that blocks here would spin.
            #expect(fcntl(readEnd, F_SETFL, O_NONBLOCK) == 0)
        }

        func write(_ text: String) {
            let bytes = [UInt8](text.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(writeEnd, $0.baseAddress, $0.count) }
        }

        /// EOF for the reader, which ends its loop and closes the read end.
        func closeWriteEnd() {
            guard writeEnd >= 0 else { return }
            Darwin.close(writeEnd)
            writeEnd = -1
        }
    }

    /// A panel wired the way production wires one.
    @MainActor
    private struct Panel {
        let state: AppState
        let coordinator: TerminalPanelRepresentable.Coordinator
        let engine: SwiftTermEngine
        let view: TBDTerminalView
        let worktreeID: UUID
        let terminalID: UUID
        let defaultsSuite: TestDefaultsSuite
    }

    private static let paneID = "%1"
    private static let windowID = "@1"
    private static let preambleText = "HOLDER-PREAMBLE"
    private static let generation: UInt64 = 7
    /// An OSC 777 rides the preamble on purpose. It is the discriminator
    /// between `feedSnapshot` and a bare `feed`: the observer that raises a
    /// user notification is NOT a `TerminalViewDelegate` callback, so the
    /// engine's ingest flag does not cover it — `feedSnapshot` suspends
    /// the observation outright, and nothing else does. Replayed history must
    /// not raise a notification for a message the agent sent minutes ago.
    private static let preamble =
        "\(preambleText)\u{1b}]777;notify;preamble;replayed history\u{07}"
    /// The same escape on the live side, as the positive control: it proves
    /// the notification path works in this test at all, so "the preamble
    /// raised none" is evidence rather than an absent mechanism.
    private static let liveOutput =
        "\r\nLIVE-OUTPUT\u{1b}]777;notify;live;fresh output\u{07}"

    @MainActor
    private func makePanel(transport: TerminalTransport) throws -> Panel {
        let worktreeID = UUID()
        let terminalID = UUID()
        let state = AppState()
        // A holder row carries EMPTY tmux coordinates by construction — the v1
        // schema's NOT NULL columns cannot be relaxed — so the panel must
        // discriminate on `transport` alone, never on those strings.
        let isHolder = transport == .holder
        state.terminals[worktreeID] = [Terminal(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: isHolder ? "" : Self.windowID,
            tmuxPaneID: isHolder ? "" : Self.paneID,
            label: "Shell",
            kind: .shell,
            transport: transport
        )]

        // Isolated defaults: AppearanceSettings must never read or write the
        // developer's real TBDApp.plist.
        let suite = TestDefaultsSuite("TBDAppTests.HolderTransportGate")
        let defaults = suite.defaults
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults)
        )
        let engine = SwiftTermEngine(view: view)

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID

        return Panel(
            state: state,
            coordinator: coordinator,
            engine: engine,
            view: view,
            worktreeID: worktreeID,
            terminalID: terminalID,
            defaultsSuite: suite
        )
    }

    @MainActor
    private func tearDown(_ panel: Panel) {
        // Releases the vended descriptor: the reader stops within a poll
        // interval and closes it on its way out.
        panel.coordinator.cleanup()
        panel.defaultsSuite.tearDown()
    }

    /// Whether `message` had already been fed into the panel.
    ///
    /// `shouldFeedPreparationMessage` is the once-per-coordinator set the
    /// production feed path itself consults, so "already present" is exactly
    /// "this message was fed". The query **consumes** its answer (it inserts),
    /// so ask about any one message at most once per coordinator.
    @MainActor
    private func didFeed(_ message: String, _ panel: Panel) -> Bool {
        !panel.coordinator.shouldFeedPreparationMessage(message)
    }

    /// Trimmed text of one viewport row, read through the production locked
    /// accessor.
    @MainActor
    private func rowText(_ row: Int, _ panel: Panel) -> String {
        panel.view.withTerminal { $0.getLine(row: row)?.translateToString(trimRight: true) ?? "" }
    }

    /// Wires the injected attach stub onto the panel and returns it.
    @MainActor
    private func attachStub(
        _ panel: Panel, fd: Int32,
        preamble: String = TerminalHolderTransportGateTests.preamble,
        ready: @escaping @Sendable () throws -> Void = {}
    ) -> StubHolderAttach {
        let attachment = HolderAttachment(
            ptyFD: fd, generation: Self.generation,
            snapshotPreamble: Data(preamble.utf8))
        let stub = StubHolderAttach(attach: { attachment }, ready: ready)
        stub.readyProbe = { [view = panel.view] in
            ReadyObservation(
                firstRow: view.withTerminal {
                    $0.getLine(row: 0)?.translateToString(trimRight: true) ?? ""
                })
        }
        panel.coordinator.holderAttachClient = stub
        return stub
    }

    // MARK: - startSessionClient

    @MainActor
    @Test("startSessionClient attaches a holder panel to its pty and paints the screen it was handed")
    func startSessionClientAttachesHolderPanel() async throws {
        let panel = try makePanel(transport: .holder)
        defer { tearDown(panel) }
        let pty = try FakePTY()
        defer { pty.closeWriteEnd() }
        // Observed where production delivers a notification, through the
        // engine to its coordinator, so the view's own hook stays the engine's.
        let notifications = NotificationRecorder()
        panel.engine.delegate = panel.coordinator
        panel.coordinator.onTerminalNotification = { title, _ in notifications.record(title) }
        let stub = attachStub(panel, fd: pty.readEnd)
        // The ingest window is closed by a block on the main queue, so nothing
        // reachable through the attach RPCs can observe it still open — every
        // such probe is behind a hop that already ran that block. This is the
        // one place the ordering is visible.
        var ingestAtWiring: Bool?
        panel.coordinator.onHolderReaderWillStart = { [engine = panel.engine] in
            ingestAtWiring = engine.isIngestingSnapshot
        }

        await panel.coordinator.startSessionClient(engine: panel.engine)

        #expect(stub.attaches == 1, "the panel must request exactly one attach")
        #expect(rowText(0, panel) == Self.preambleText,
                "the screen the daemon handed back must be on the terminal")
        #expect(!didFeed(TerminalPreparationPresentation.holderAttachFailedMessage, panel),
                "the placard belongs to a refused attach, not to a live one")

        // The ack carries what only this attach knows: the session's id (a
        // holder row has no pane to name it by) and the generation the daemon
        // minted, which it refuses a holder ack without.
        #expect(stub.readyCalls == [
            StubHolderAttach.ReadyCall(
                worktreeID: panel.worktreeID, paneID: "",
                terminalID: panel.terminalID, generation: Self.generation)
        ])

        // Ordering, observed at the ack — the reader is wired just before it.
        let observation = try #require(stub.readyObservations.first)
        #expect(observation.firstRow == Self.preambleText,
                "the preamble must be fed before the ack, not after")
        #expect(ingestAtWiring == false, """
            the reader was wired while the snapshot ingest window was still open — \
            everything delivered there is dropped regardless of origin, so a live \
            DA1/DSR the agent is waiting on would be answered by nobody
            """)

        // And the panel is live: bytes the session writes now reach the screen.
        pty.write(Self.liveOutput)
        try await waitFor("live pty output to paint",
                          observed: { await MainActor.run { self.rowText(1, panel) } }) {
            await MainActor.run { self.rowText(1, panel) == "LIVE-OUTPUT" }
        }

        // The live OSC 777 proves the notification path is wired here; the
        // preamble's identical escape must have raised nothing, because the
        // screen it painted is history.
        try await waitFor("the live OSC 777 to raise its notification",
                          observed: { await MainActor.run { notifications.titles.description } }) {
            await MainActor.run { notifications.titles.contains("live") }
        }
        #expect(!notifications.titles.contains("preamble"), """
            the preamble was fed through a bare `feed`: its OSC 777 raised a \
            notification for a message the session emitted long ago
            """)
    }

    @MainActor
    @Test("startSessionClient shows the attach-failed placard when the daemon refuses a holder attach")
    func startSessionClientShowsPlacardWhenAttachRefused() async throws {
        let panel = try makePanel(transport: .holder)
        defer { tearDown(panel) }
        let stub = StubHolderAttach(attach: {
            throw DaemonClientError.rpcError("attach failed: no live holder reader", code: nil)
        })
        panel.coordinator.holderAttachClient = stub
        // One attempt: what the placard says is under test here, not how
        // often the panel asks — `HolderAttachRetryTests` owns that.
        panel.coordinator.holderAttachRetryDelays = []
        var retryOffers = 0
        panel.coordinator.onHolderAttachRetryOffered = { retryOffers += 1 }

        await panel.coordinator.startSessionClient(engine: panel.engine)

        #expect(stub.attaches == 1)
        #expect(stub.readyCalls.isEmpty, "an attach that never happened must not be acked")
        #expect(didFeed(TerminalPreparationPresentation.holderAttachFailedMessage, panel),
                "a refused attach must explain itself with the attach-failed notice")
        #expect(retryOffers == 1,
                "the attach-failed placard points at a Retry button, so it must raise the banner that carries it")
    }

    /// A daemon with no holder transport wired answers "unavailable", and
    /// will answer it to every attempt and every fresh panel. So the panel
    /// asks once, and its placard promises no Retry and raises no banner.
    ///
    /// Runs on the production retry schedule and clock on purpose: were the
    /// answer retried, the attempts would show it (and the test would take
    /// the whole backoff to say so).
    @MainActor
    @Test("a holder attach the daemon can never serve is not retried and offers no Retry")
    func startSessionClientShowsUnavailablePlacardWithoutRetry() async throws {
        let panel = try makePanel(transport: .holder)
        defer { tearDown(panel) }
        let stub = StubHolderAttach(
            attach: { throw DaemonClientError.attachUnavailable("unavailable") })
        panel.coordinator.holderAttachClient = stub
        var retryOffers = 0
        panel.coordinator.onHolderAttachRetryOffered = { retryOffers += 1 }

        await panel.coordinator.startSessionClient(engine: panel.engine)

        #expect(stub.attaches == 1, "an answer that cannot change must not be asked again")
        #expect(didFeed(TerminalPreparationPresentation.holderAttachUnavailableMessage, panel))
        #expect(!didFeed(TerminalPreparationPresentation.holderAttachFailedMessage, panel),
                "a refusal that Retry cannot change must not point at Retry")
        #expect(retryOffers == 0, "a refusal that Retry cannot change must not raise the Retry banner")
    }

    /// The attach-failed copy says the session keeps running and that Retry
    /// attaches again. When the daemon reports the holder gone, both claims
    /// are false, so the ended copy must replace it.
    @MainActor
    @Test("a holder attach the daemon reports as ended shows the session-ended placard")
    func startSessionClientShowsEndedPlacardWhenTheHolderIsGone() async throws {
        let panel = try makePanel(transport: .holder)
        defer { tearDown(panel) }
        let stub = StubHolderAttach(attach: {
            throw DaemonClientError.attachUnavailable(AttachRequestResult.holderSessionEndedStatus)
        })
        panel.coordinator.holderAttachClient = stub
        var retryOffers = 0
        panel.coordinator.onHolderAttachRetryOffered = { retryOffers += 1 }

        await panel.coordinator.startSessionClient(engine: panel.engine)

        #expect(stub.attaches == 1)
        // The fixture's tab is a shell, so the copy promises no resume.
        #expect(didFeed(TerminalPreparationPresentation.holderSessionEndedMessage, panel),
                "an ended session must say it has ended")
        #expect(!didFeed(TerminalPreparationPresentation.holderAttachFailedMessage, panel),
                "an ended session must not claim it keeps running")
        #expect(retryOffers == 0,
                "an ended session has nothing to attach to, so it must not be offered a Retry")
    }

    /// Closing a tab ends its session, so the placard for a session that
    /// keeps running must never send the user there. Its remedy is the Retry
    /// button the panel shows, and the copy must name it by the button's own
    /// title so the two cannot drift apart. The ended copies keep their close
    /// advice: there, closing is right.
    @Test("the attach-failed placard points at Retry and never at closing the tab")
    func attachFailedCopyPointsAtRetry() {
        typealias Copy = TerminalPreparationPresentation
        let copy = Copy.holderAttachFailedMessage.lowercased()
        #expect(!copy.contains("close"), "closing the tab ends the session this copy says keeps running")
        #expect(!copy.contains("reopen"), "reopening means closing first, which ends the session")
        #expect(Copy.holderAttachFailedMessage.contains(Copy.retryTitle),
                "the copy must name the button that retries, by its own title")
        #expect(copy.contains("keeps running"))
        let unavailable = Copy.holderAttachUnavailableMessage.lowercased()
        #expect(!unavailable.contains("retry") && !unavailable.contains("close"),
                "a refusal nothing can change must promise no remedy at all")
        #expect(unavailable.contains("keeps running"))
        #expect(Copy.holderSessionEndedMessage.contains("Close the tab"),
                "the ended copy's close advice is correct and must stay")
        #expect(Copy.holderClaudeSessionEndedMessage.contains("Close the tab"))
    }

    /// Retry is a fresh panel, not a reach into the failed one: the Retry
    /// count is part of the pane's identity, so advancing it is what makes
    /// SwiftUI tear the failed panel down and build one that attaches again.
    /// It leaves the attach epoch alone — an account switch reads that one
    /// (`SwitchingAccountPaneTests`).
    @MainActor
    @Test("Retry advances the terminal's Retry count, which changes its pane's identity")
    func retryAdvancesTheRetryCount() {
        let state = AppState()
        let row = TBDShared.Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            label: "Shell", kind: .shell, transport: .holder)
        let bystander = UUID()
        @MainActor func identity() -> String {
            TerminalPanePresentation.identity(
                for: row, switching: nil,
                attachEpoch: state.terminalAttachEpochs[row.id] ?? 0,
                attachRetry: state.terminalAttachRetries[row.id] ?? 0,
                engineOverride: state.terminalEngineOverrides[row.id])
        }
        let before = identity()

        state.retryTerminalAttach(terminalID: row.id)

        #expect(state.terminalAttachRetries[row.id] == 1)
        #expect(state.terminalAttachEpochs[row.id] == nil, "Retry must leave the switch's epoch alone")
        #expect(identity() != before, "a Retry that leaves the identity alone rebuilds nothing")
        #expect(state.terminalAttachRetries[bystander] == nil,
                "only the retried terminal's panel may be rebuilt")
        state.retryTerminalAttach(terminalID: row.id)
        #expect(state.terminalAttachRetries[row.id] == 2, "every Retry must be a fresh attempt")
    }

    @MainActor
    @Test("a terminal's Retry count goes with the terminal")
    func retryCountIsForgottenWithItsTerminal() {
        let suite = TestDefaultsSuite("TBDAppTests.HolderTransportGate")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        let state = AppState(userDefaults: defaults)
        let worktreeID = UUID()
        func row() -> TBDShared.Terminal {
            TBDShared.Terminal(
                id: UUID(), worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "",
                label: "Shell", kind: .shell, transport: .holder)
        }
        let removed = row()
        let kept = row()
        state.terminals[worktreeID] = [removed, kept]
        state.retryTerminalAttach(terminalID: removed.id)
        state.retryTerminalAttach(terminalID: kept.id)

        state.removeDeletedTerminalFromState(terminalID: removed.id, worktreeID: worktreeID)

        #expect(state.terminalAttachRetries[removed.id] == nil, "a removed terminal's count must not linger")
        #expect(state.terminalAttachRetries[kept.id] == 1, "only the removed terminal's count goes")
    }

    @Test("only the ended status maps to the session-ended copy, and only a resumable Claude tab is promised a resume")
    func holderAttachFailureMessageMapping() {
        typealias Copy = TerminalPreparationPresentation
        func tab(_ kind: TerminalKind?, session: String?) -> TBDShared.Terminal {
            TBDShared.Terminal(
                id: UUID(), worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
                claudeSessionID: session, kind: kind, transport: .holder)
        }
        let ended = DaemonClientError.attachUnavailable(AttachRequestResult.holderSessionEndedStatus)
        #expect(Copy.holderAttachFailureMessage(for: ended, terminal: tab(.claude, session: "s-1"))
            == Copy.holderClaudeSessionEndedMessage)
        let neutral: [TBDShared.Terminal?] = [
            tab(.claude, session: nil), tab(.shell, session: nil), tab(.codex, session: "s-1"), nil,
        ]
        for terminal in neutral {
            #expect(Copy.holderAttachFailureMessage(for: ended, terminal: terminal)
                == Copy.holderSessionEndedMessage)
        }
        #expect(!Copy.holderSessionEndedMessage.contains("resume"),
                "a tab that cannot resume must not be promised one")
        for permanent in [
            DaemonClientError.attachUnavailable("unavailable") as any Error,
            HolderAttachError.missingGeneration,
        ] {
            #expect(Copy.holderAttachFailureMessage(
                for: permanent, terminal: tab(.claude, session: "s-1"))
                == Copy.holderAttachUnavailableMessage,
                "\(permanent) cannot change on Retry, so it must not get the Retry copy")
        }
        #expect(Copy.holderAttachFailureMessage(
            for: DaemonClientError.rpcError("attach failed: no live holder reader", code: nil),
            terminal: tab(.claude, session: "s-1")) == Copy.holderAttachFailedMessage)
    }

    @MainActor
    @Test("a holder attach whose ready is refused stops reading and shows the attach-failed placard")
    func holderAttachWithRefusedReadyShowsPlacard() async throws {
        let panel = try makePanel(transport: .holder)
        defer { tearDown(panel) }
        let pty = try FakePTY()
        defer { pty.closeWriteEnd() }
        let stub = attachStub(
            panel, fd: pty.readEnd,
            ready: { throw DaemonClientError.rpcError("attach.ready refused", code: nil) })
        // One attempt: this is about how a refused ack ends, and the stub
        // would hand a retry the descriptor the first reader closed.
        panel.coordinator.holderAttachRetryDelays = []

        await panel.coordinator.startSessionClient(engine: panel.engine)

        #expect(stub.readyCalls.count == 1)
        #expect(didFeed(TerminalPreparationPresentation.holderAttachFailedMessage, panel),
                "a viewer the daemon has not accounted for must say so")
    }

    /// Holds a handback open until the test releases it, standing in for the
    /// predecessor panel's detach task. Suspension-based, so no thread blocks.
    private actor HeldHandback {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    @Test("a holder attach waits for the predecessor's handback before it asks the daemon")
    func holderAttachWaitsForPredecessorHandback() async throws {
        let panel = try makePanel(transport: .holder)
        defer { tearDown(panel) }
        let pty = try FakePTY()
        defer { pty.closeWriteEnd() }
        let stub = attachStub(panel, fd: pty.readEnd)

        // The predecessor's handback, still in flight on the ledger the panel
        // reads by default — the one on its AppState — for this terminal.
        let held = HeldHandback()
        let handback = Task { await held.wait() }
        panel.state.holderHandbackLedger.register(terminalID: panel.terminalID, task: handback)

        let attaching = Task { @MainActor in
            await panel.coordinator.startSessionClient(engine: panel.engine)
        }
        // Give the attach every chance to run ahead of the handback. The
        // assertion below cannot pass by luck: the only path to `attach` runs
        // through `awaitSettled`, which cannot return while `held` is closed.
        for _ in 0..<20 { await Task.yield() }
        #expect(stub.attaches == 0,
                "the successor asked the daemon while its predecessor's handback was in flight")
        #expect(panel.state.holderHandbackLedger.isInFlight(terminalID: panel.terminalID))

        await held.release()
        await attaching.value

        #expect(stub.attaches == 1, "the attach must proceed once the handback settles")
        #expect(stub.readyCalls.count == 1)
        #expect(!panel.state.holderHandbackLedger.isInFlight(terminalID: panel.terminalID))
        #expect(!didFeed(TerminalPreparationPresentation.holderAttachFailedMessage, panel),
                "an attach that waited its turn must not paint the failure placard")
    }

    @MainActor
    @Test("a holder attach with no handback in flight does not wait")
    func holderAttachWithoutHandbackDoesNotWait() async throws {
        let panel = try makePanel(transport: .holder)
        defer { tearDown(panel) }
        let pty = try FakePTY()
        defer { pty.closeWriteEnd() }
        let stub = attachStub(panel, fd: pty.readEnd)
        #expect(!panel.state.holderHandbackLedger.isInFlight(terminalID: panel.terminalID))

        await panel.coordinator.startSessionClient(engine: panel.engine)

        #expect(stub.attaches == 1)
        #expect(stub.readyCalls.count == 1)
    }

    /// A row still on tmux is shown as `LeftoverTmuxSessionNotice`, never as
    /// a panel; a panel that meets one anyway — its row changed under it —
    /// attaches nothing and paints no placard, so no attach is asked of the
    /// daemon for a session it cannot vend.
    @MainActor
    @Test("a panel never attaches a row still on tmux")
    func aPanelNeverAttachesATmuxRow() async throws {
        let panel = try makePanel(transport: .tmux)
        defer { tearDown(panel) }
        let stub = StubHolderAttach(attach: {
            throw DaemonClientError.rpcError("a tmux row was asked to attach", code: nil)
        })
        panel.coordinator.holderAttachClient = stub
        panel.coordinator.holderAttachRetryDelays = []
        var retryOffers = 0
        panel.coordinator.onHolderAttachRetryOffered = { retryOffers += 1 }

        await panel.coordinator.startSessionClient(engine: panel.engine)

        #expect(stub.attaches == 0, "a row on tmux has no holder session to attach to")
        #expect(!didFeed(TerminalPreparationPresentation.holderAttachFailedMessage, panel),
                "nothing was attempted, so nothing failed")
        #expect(retryOffers == 0, "a Retry would only ask for the same attach")
    }

    /// A row AppState has not loaded is not assumed to be on tmux: the panel
    /// takes the holder path, which paints the attach-failed placard and
    /// offers the Retry that attaches once the row is in.
    @MainActor
    @Test("a panel whose row is not loaded offers Retry without asking the daemon")
    func aPanelWhoseRowIsNotLoadedOffersRetry() async throws {
        let panel = try makePanel(transport: .holder)
        defer { tearDown(panel) }
        panel.state.terminals[panel.worktreeID] = []
        let stub = StubHolderAttach(attach: {
            throw DaemonClientError.rpcError("an unloaded row was asked to attach", code: nil)
        })
        panel.coordinator.holderAttachClient = stub
        var retryOffers = 0
        panel.coordinator.onHolderAttachRetryOffered = { retryOffers += 1 }

        await panel.coordinator.startSessionClient(engine: panel.engine)

        #expect(stub.attaches == 0, "an attach needs the row's worktree, which is not loaded")
        #expect(didFeed(TerminalPreparationPresentation.holderAttachFailedMessage, panel))
        #expect(retryOffers == 1)
    }
}
