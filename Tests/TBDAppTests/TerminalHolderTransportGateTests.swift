import AppKit
import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Tier 2: drives the **two real attach entry points** —
/// `Coordinator.startTmuxClient` and `Coordinator.startControlModeClient` —
/// for a holder-backed panel, and requires that each one attaches to the
/// session's pty instead of reaching the tmux machinery behind it.
///
/// `TerminalPanelViewTests` covers the pure decision function
/// (`transportPreparationNotice(for:)`) and the `panelTransport()` lookup under
/// it. Those would all stay green if someone deleted or reordered the
/// `if await handleHolderTransport(into:) { return }` line at the top of either
/// attach path, which is the whole defect this gate exists to prevent — a
/// holder row would go back to being classified as a broken tmux window and
/// the false "recovery" banner would return. So the assertions here are about
/// **what ran and what did not**, observed on the production call path:
///
/// - **The session is painted, and no tmux command was issued.** `TmuxBridge`
///   takes an injected `TmuxCommandRunner`; a holder panel must leave its log
///   empty while the screen the daemon handed back appears in the buffer. This
///   is the discriminator for `startTmuxClient`: dropping its branch sends
///   `prepareSession` straight into `kill-session` / `new-session`.
/// - **No control-mode attach was requested.** `startControlModeClient`'s
///   failure path unconditionally clears two pieces of state before it falls
///   back — the view's `onControlModePaste` interceptor and the pane's
///   `controlModeAttachedPanes` record. Both are seeded here as probes, so a
///   holder panel that leaves them untouched has demonstrably never called
///   `openAttach`. Dropping that branch clears both, and the tmux recorder
///   cannot see it: the fallback lands in `startTmuxClient`, whose own branch
///   still suppresses tmux. The probes are the only thing that separates the
///   two mutations.
/// - **The ordering the attach depends on.** The preamble goes in through
///   `feedSnapshot`, and the reader is wired only after that feed's ingest
///   window has closed — `feedSnapshot` lowers its flag a main-queue turn
///   after it returns, and everything delivered while it is up is dropped
///   regardless of origin. `attach.ready` is the first thing that happens
///   after the reader exists, so the state observed AT the ack is the
///   observable form of that ordering.
///
/// Each branch also has a positive control on the same entry point with a
/// `.tmux` panel, so a branch that suppressed *everything* would fail too, plus
/// the refusal case: when the daemon says the attach is unavailable, the
/// placard is what the panel shows.
///
/// **Nothing here talks to a live daemon or a live tmux.** Every tmux command
/// goes through the recorder (the resolver points at a stub binary the runner
/// never executes), the holder attach goes through an injected
/// `HolderAttaching` stub over a real pipe, and the control-mode positive
/// control's `openAttach` runs against `TBD_SOCKET_PATH`, which
/// `scripts/test.sh` fences onto a scratch path with no listener — the connect
/// fails with ENOENT and returns at once.
// A hang guard, and it has to clear the bounded waits below, which run to
// `TestDeadlines.saturatedPass` (90 s): a suite limit under that truncates
// their named diagnostic into a bare "Time limit was exceeded" — measured, by
// mutating away `reader.start()`. The shared dial is derived to clear exactly
// that, so it is what this takes rather than a locally chosen two minutes. See
// `.fastPassBounded` in `Tests/TestSupport/ClockTestSupport.swift`.
@Suite("A holder-backed panel attaches to its pty, not to tmux", .fastPassBounded)
struct TerminalHolderTransportGateTests {

    /// Records every tmux invocation and refuses all of them, so a preparation
    /// that does run fails at `new-session` and classifies as `.commandFailed`
    /// without spawning a viewer process.
    private actor RefusingTmuxRunner {
        private(set) var invocations: [[String]] = []

        func run(args: [String]) -> TmuxCommandOutcome {
            invocations.append(args)
            return TmuxCommandOutcome(success: false, output: "fixture refuses every tmux command")
        }

        func recorded() -> [[String]] { invocations }
    }

    /// What the panel looked like at the instant `attach.ready` was sent.
    private struct ReadyObservation: Sendable {
        /// Must already carry the preamble: it is fed before the ack.
        let firstRow: String
    }

    /// Collects OSC 777 notification titles. Written and read on the main
    /// queue (the view hops there before calling `onNotification`), but the
    /// bounded wait reads it from a `@Sendable` closure, so it carries a lock.
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
            worktreeID: UUID, paneID: String, terminalID: UUID
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

    /// A panel wired the way production wires one, plus the bridge whose
    /// command log is the "did any tmux mechanic run" verdict.
    @MainActor
    private struct Panel {
        let state: AppState
        let coordinator: TerminalPanelRepresentable.Coordinator
        let view: TBDTerminalView
        let bridge: TmuxBridge
        let runner: RefusingTmuxRunner
        let worktreeID: UUID
        let terminalID: UUID
        let defaults: UserDefaults
        let defaultsSuiteName: String
    }

    private static let paneID = "%1"
    private static let windowID = "@1"
    private static let server = "tbd-fixture"
    private static let preambleText = "HOLDER-PREAMBLE"
    private static let generation: UInt64 = 7
    /// An OSC 777 rides the preamble on purpose. It is the discriminator
    /// between `feedSnapshot` and a bare `feed`: the observer that raises a
    /// user notification is NOT a `TerminalViewDelegate` callback, so the
    /// coordinator's ingest flag does not cover it — `feedSnapshot` suspends
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
    private func makePanel(
        transport: TerminalTransport,
        fixture: TmuxBridgeFixture
    ) throws -> Panel {
        let worktreeID = UUID()
        let terminalID = UUID()
        let state = AppState()
        // A holder row carries EMPTY tmux coordinates by construction — the v1
        // schema's NOT NULL columns cannot be relaxed — so the branch must
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
        let suiteName = "TBDAppTests.HolderTransportGate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults)
        )

        let runner = RefusingTmuxRunner()
        let bridge = TmuxBridge(
            tmuxExecutableResolver: try fixture.resolvingResolver(),
            commandRunner: { _, _, args in await runner.run(args: args) }
        )

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID
        coordinator.tmuxBridge = bridge
        coordinator.tmuxServer = Self.server

        return Panel(
            state: state,
            coordinator: coordinator,
            view: view,
            bridge: bridge,
            runner: runner,
            worktreeID: worktreeID,
            terminalID: terminalID,
            defaults: defaults,
            defaultsSuiteName: suiteName
        )
    }

    @MainActor
    private func tearDown(_ panel: Panel) {
        // Releases the vended descriptor: the reader stops within a poll
        // interval and closes it on its way out.
        panel.coordinator.cleanup()
        panel.defaults.removePersistentDomain(forName: panel.defaultsSuiteName)
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

    // MARK: - startTmuxClient

    @MainActor
    @Test("startTmuxClient attaches a holder panel to its pty and paints the screen it was handed")
    func startTmuxClientAttachesHolderPanel() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let panel = try makePanel(transport: .holder, fixture: fixture)
        defer { tearDown(panel) }
        let pty = try FakePTY()
        defer { pty.closeWriteEnd() }
        let notifications = NotificationRecorder()
        panel.view.onNotification = { title, _ in notifications.record(title) }
        let stub = attachStub(panel, fd: pty.readEnd)
        // The ingest window is closed by a block on the main queue, so nothing
        // reachable through the attach RPCs can observe it still open — every
        // such probe is behind a hop that already ran that block. This is the
        // one place the ordering is visible.
        var ingestAtWiring: Bool?
        panel.coordinator.onHolderReaderWillStart = { [coordinator = panel.coordinator] in
            ingestAtWiring = coordinator.isIngestingSnapshot
        }

        await panel.coordinator.startTmuxClient(
            terminalView: panel.view,
            bridge: panel.bridge,
            server: Self.server,
            windowID: "",
            panelID: panel.terminalID
        )

        // The discriminator for the branch: `prepareSession`'s very first act
        // is a pre-emptive `kill-session`, so a single recorded invocation
        // means the branch did not run first.
        let recorded = await panel.runner.recorded()
        #expect(recorded.isEmpty,
                "a holder-backed panel must reach no tmux mechanic whatsoever, ran \(recorded)")
        #expect(panel.coordinator.localProcess == nil,
                "the holder path starts no viewer process")
        #expect(stub.attaches == 1, "the panel must request exactly one attach")
        #expect(rowText(0, panel) == Self.preambleText,
                "the screen the daemon handed back must be on the terminal")
        #expect(!didFeed(TerminalPreparationPresentation.holderTransportMessage, panel),
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
    @Test("startTmuxClient shows the placard when the daemon refuses a holder attach")
    func startTmuxClientShowsPlacardWhenAttachRefused() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let panel = try makePanel(transport: .holder, fixture: fixture)
        defer { tearDown(panel) }
        let stub = StubHolderAttach(
            attach: { throw DaemonClientError.attachUnavailable("unavailable") })
        panel.coordinator.holderAttachClient = stub

        await panel.coordinator.startTmuxClient(
            terminalView: panel.view,
            bridge: panel.bridge,
            server: Self.server,
            windowID: "",
            panelID: panel.terminalID
        )

        #expect(stub.attaches == 1)
        #expect(stub.readyCalls.isEmpty, "an attach that never happened must not be acked")
        #expect(didFeed(TerminalPreparationPresentation.holderTransportMessage, panel),
                "a refused attach must explain itself with the holder notice")
        let recorded = await panel.runner.recorded()
        #expect(recorded.isEmpty,
                "a refused holder attach must not fall back into tmux, ran \(recorded)")
    }

    @MainActor
    @Test("a holder attach whose ready is refused stops reading and shows the placard")
    func holderAttachWithRefusedReadyShowsPlacard() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let panel = try makePanel(transport: .holder, fixture: fixture)
        defer { tearDown(panel) }
        let pty = try FakePTY()
        defer { pty.closeWriteEnd() }
        let stub = attachStub(
            panel, fd: pty.readEnd,
            ready: { throw DaemonClientError.rpcError("attach.ready refused", code: nil) })

        await panel.coordinator.startTmuxClient(
            terminalView: panel.view,
            bridge: panel.bridge,
            server: Self.server,
            windowID: "",
            panelID: panel.terminalID
        )

        #expect(stub.readyCalls.count == 1)
        #expect(didFeed(TerminalPreparationPresentation.holderTransportMessage, panel),
                "a viewer the daemon has not accounted for must say so")
    }

    @MainActor
    @Test("startTmuxClient still prepares a tmux-backed panel through tmux")
    func startTmuxClientStillPreparesTmuxPanel() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let panel = try makePanel(transport: .tmux, fixture: fixture)
        defer { tearDown(panel) }

        await panel.coordinator.startTmuxClient(
            terminalView: panel.view,
            bridge: panel.bridge,
            server: Self.server,
            windowID: Self.windowID,
            panelID: panel.terminalID
        )

        let recorded = await panel.runner.recorded()
        #expect(!recorded.isEmpty,
                "the branch must not suppress the tmux path it does not own")
        #expect(!didFeed(TerminalPreparationPresentation.holderTransportMessage, panel),
                "the holder notice must never appear on a tmux-backed panel")
        // The refusing runner makes preparation fail at `new-session`, which
        // classifies as `.commandFailed` — the pre-existing copy, unchanged.
        #expect(didFeed(TerminalPreparationPresentation.commandFailedMessage, panel))
    }

    // MARK: - startControlModeClient

    @MainActor
    @Test("startControlModeClient attaches a holder panel to its pty and requests no pane attach")
    func startControlModeClientAttachesHolderPanel() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let panel = try makePanel(transport: .holder, fixture: fixture)
        defer { tearDown(panel) }
        let pty = try FakePTY()
        defer { pty.closeWriteEnd() }
        let stub = attachStub(panel, fd: pty.readEnd)

        // Two probes for state the control-mode attach path clears
        // unconditionally on its failure route, before it falls back. Surviving
        // both is the evidence that `openAttach` was never called — the tmux
        // recorder cannot show it, because the fallback's own branch would
        // suppress tmux anyway.
        panel.view.onControlModePaste = { _ in true }
        panel.state.controlModePaneAttached(
            worktreeID: panel.worktreeID, paneID: Self.paneID, generation: nil)
        let paneKey = ControlModePaneKey(worktreeID: panel.worktreeID, paneID: Self.paneID)

        await panel.coordinator.startControlModeClient(
            terminalView: panel.view,
            appState: panel.state,
            worktreeID: panel.worktreeID,
            paneID: Self.paneID,
            bridge: panel.bridge,
            server: Self.server,
            windowID: "",
            panelID: panel.terminalID
        )

        #expect(panel.view.onControlModePaste != nil,
                "the control-mode attach path's failure teardown ran, so an attach was attempted")
        #expect(panel.state.controlModeAttachedPanes.index(forKey: paneKey) != nil,
                "the control-mode attach path's failure teardown ran, so an attach was attempted")
        let recorded = await panel.runner.recorded()
        #expect(recorded.isEmpty,
                "the grouped-sessions fallback must not be reached either, ran \(recorded)")
        #expect(stub.attaches == 1, "the panel must take the holder attach from this entry point too")
        #expect(rowText(0, panel) == Self.preambleText,
                "the screen the daemon handed back must be on the terminal")
        #expect(!didFeed(TerminalPreparationPresentation.holderTransportMessage, panel),
                "the placard belongs to a refused attach, not to a live one")
    }

    @MainActor
    @Test("startControlModeClient still attempts an attach for a tmux-backed panel")
    func startControlModeClientStillAttemptsAttachForTmuxPanel() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let panel = try makePanel(transport: .tmux, fixture: fixture)
        defer { tearDown(panel) }

        panel.view.onControlModePaste = { _ in true }
        panel.state.controlModePaneAttached(
            worktreeID: panel.worktreeID, paneID: Self.paneID, generation: nil)
        let paneKey = ControlModePaneKey(worktreeID: panel.worktreeID, paneID: Self.paneID)

        await panel.coordinator.startControlModeClient(
            terminalView: panel.view,
            appState: panel.state,
            worktreeID: panel.worktreeID,
            paneID: Self.paneID,
            bridge: panel.bridge,
            server: Self.server,
            windowID: Self.windowID,
            panelID: panel.terminalID
        )

        // There is no daemon behind the fenced socket, so the attach fails and
        // its teardown clears both probes on the way to the fallback. That is
        // the pre-existing behavior the branch must leave alone.
        #expect(panel.view.onControlModePaste == nil)
        #expect(panel.state.controlModeAttachedPanes.index(forKey: paneKey) == nil)
        let recorded = await panel.runner.recorded()
        #expect(!recorded.isEmpty,
                "the grouped-sessions fallback must still run for a tmux-backed panel")
        #expect(!didFeed(TerminalPreparationPresentation.holderTransportMessage, panel),
                "the holder notice must never appear on a tmux-backed panel")
    }
}
