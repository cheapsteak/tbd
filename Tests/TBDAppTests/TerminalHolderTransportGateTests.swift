import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import TBDApp
import TBDShared

/// Tier 2: drives the **two real attach entry points** —
/// `Coordinator.startTmuxClient` and `Coordinator.startControlModeClient` —
/// for a holder-backed panel, and requires that neither reaches the machinery
/// behind it.
///
/// `TerminalPanelViewTests` covers the pure decision function
/// (`transportPreparationNotice(for:)`) and the `panelTransport()` lookup under
/// it. Those would all stay green if someone deleted or reordered the
/// `if handleUnsupportedTransport(into:) { return }` line at the top of either
/// attach path, which is the whole defect this gate exists to prevent — a
/// holder row would go back to being classified as a broken tmux window and
/// the false "recovery" banner would return. So the assertions here are about
/// **what did not run**, observed on the production call path:
///
/// - **No tmux command was issued.** `TmuxBridge` takes an injected
///   `TmuxCommandRunner`; a holder panel must leave its log empty. This is the
///   discriminator for `startTmuxClient`: dropping its guard sends
///   `prepareSession` straight into `kill-session` / `new-session`.
/// - **No control-mode attach was requested.** `startControlModeClient`'s
///   failure path unconditionally clears two pieces of state before it falls
///   back — the view's `onControlModePaste` interceptor and the pane's
///   `controlModeAttachedPanes` record. Both are seeded here as probes, so a
///   holder panel that leaves them untouched has demonstrably never called
///   `openAttach`. Dropping that guard clears both, and the tmux recorder
///   cannot see it: the fallback lands in `startTmuxClient`, whose own guard
///   still suppresses tmux. The probes are the only thing that separates the
///   two mutations.
///
/// Each gate also has a positive control on the same entry point with a
/// `.tmux` panel, so a gate that suppressed *everything* would fail too.
///
/// **Nothing here talks to a live daemon or a live tmux.** Every tmux command
/// goes through the recorder (the resolver points at a stub binary the runner
/// never executes), and the control-mode positive control's `openAttach` runs
/// against `TBD_SOCKET_PATH`, which `scripts/test.sh` fences onto a scratch
/// path with no listener — the connect fails with ENOENT and returns at once.
@Suite("A holder-backed panel is gated out of both attach paths", .timeLimit(.minutes(1)))
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

    @MainActor
    private func makePanel(
        transport: TerminalTransport,
        fixture: TmuxBridgeFixture
    ) throws -> Panel {
        let worktreeID = UUID()
        let terminalID = UUID()
        let state = AppState()
        // A holder row carries EMPTY tmux coordinates by construction — the v1
        // schema's NOT NULL columns cannot be relaxed — so the gate must
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

    // MARK: - startTmuxClient

    @MainActor
    @Test("startTmuxClient issues no tmux command at all for a holder-backed panel")
    func startTmuxClientRunsNoTmuxCommandForHolderPanel() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let panel = try makePanel(transport: .holder, fixture: fixture)
        defer { tearDown(panel) }

        await panel.coordinator.startTmuxClient(
            terminalView: panel.view,
            bridge: panel.bridge,
            server: Self.server,
            windowID: "",
            panelID: panel.terminalID
        )

        // The discriminator: `prepareSession`'s very first act is a
        // pre-emptive `kill-session`, so a single recorded invocation means
        // the guard did not run first.
        let recorded = await panel.runner.recorded()
        #expect(recorded.isEmpty,
                "a holder-backed panel must reach no tmux mechanic whatsoever, ran \(recorded)")
        #expect(panel.coordinator.localProcess == nil,
                "no viewer process may be started for a transport the app cannot render")
        #expect(didFeed(TerminalPreparationPresentation.holderTransportMessage, panel),
                "the panel must explain itself with the holder notice")
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
                "the gate must not suppress the tmux path it does not own")
        #expect(!didFeed(TerminalPreparationPresentation.holderTransportMessage, panel),
                "the holder notice must never appear on a tmux-backed panel")
        // The refusing runner makes preparation fail at `new-session`, which
        // classifies as `.commandFailed` — the pre-existing copy, unchanged.
        #expect(didFeed(TerminalPreparationPresentation.commandFailedMessage, panel))
    }

    // MARK: - startControlModeClient

    @MainActor
    @Test("startControlModeClient requests no attach at all for a holder-backed panel")
    func startControlModeClientRequestsNoAttachForHolderPanel() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let panel = try makePanel(transport: .holder, fixture: fixture)
        defer { tearDown(panel) }

        // Two probes for state the attach path clears unconditionally on its
        // failure route, before it falls back. Surviving both is the evidence
        // that `openAttach` was never called — the tmux recorder cannot show
        // it, because the fallback's own guard would suppress tmux anyway.
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
                "the attach path's failure teardown ran, so an attach was attempted")
        #expect(panel.state.controlModeAttachedPanes.index(forKey: paneKey) != nil,
                "the attach path's failure teardown ran, so an attach was attempted")
        let recorded = await panel.runner.recorded()
        #expect(recorded.isEmpty,
                "the grouped-sessions fallback must not be reached either, ran \(recorded)")
        #expect(didFeed(TerminalPreparationPresentation.holderTransportMessage, panel),
                "the panel must explain itself with the holder notice")
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
        // the pre-existing behavior the gate must leave alone.
        #expect(panel.view.onControlModePaste == nil)
        #expect(panel.state.controlModeAttachedPanes.index(forKey: paneKey) == nil)
        let recorded = await panel.runner.recorded()
        #expect(!recorded.isEmpty,
                "the grouped-sessions fallback must still run for a tmux-backed panel")
        #expect(!didFeed(TerminalPreparationPresentation.holderTransportMessage, panel),
                "the holder notice must never appear on a tmux-backed panel")
    }
}
