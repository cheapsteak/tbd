import SwiftUI
import SwiftTerm
import AppKit
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "TerminalPanel")

enum TerminalPreparationAction: Equatable, Sendable {
    case startViewer(TmuxPreparedSession)
    case showMessage(String)
    case requestAutomaticRecovery(failedStage: TmuxPreparationStage)
}

struct TerminalRecoveryDiagnosticContext: Equatable, Sendable {
    let terminalID: UUID
    let worktreeID: UUID?
}

/// User-facing copy for a terminal that could not be prepared.
enum TerminalPreparationPresentation {
    static let commandFailedMessage =
        "TBD couldn't attach to this terminal. The terminal was left unchanged. Check diagnostics for details or close the tab."
    static let tmuxExecutableUnavailableMessage =
        "TBD couldn't find tmux — it is not in PATH and no fallback path is saved. Locate the tmux executable in Settings → Terminal, then reopen this terminal."
}

enum TerminalRecoveryPresentation {
    static let failedMessage =
        "Automatic terminal recovery failed. Retry manually or close the tab."
    static let exhaustedMessage =
        "The terminal window is still unavailable after two automatic recovery attempts. Retry manually or close the tab."
    static let retryTitle = "Retry"
}

/// Sendable wrapper for a weak TerminalView reference, used to pass the
/// reference into an `NSEvent` local monitor closure under strict concurrency.
private final class WeakTerminalRef: @unchecked Sendable {
    weak var view: TerminalView?
    init(_ view: TerminalView) { self.view = view }
}

// MARK: - TerminalPanelView

/// SwiftUI view that hosts a SwiftTerm-backed terminal panel and, for terminals
/// pinned to a proxy profile (`baseURL != nil`), shows a one-shot
/// proxy-unreachable banner driven by a TCP-connect health probe.
struct TerminalPanelView: View {
    let terminalID: UUID
    let tmuxServer: String
    let tmuxWindowID: String
    let tmuxBridge: TmuxBridge
    var tabCloseContext: TabCloseContext? = nil
    var worktreePath: String = ""
    var remoteURL: String?
    var onFilePathClicked: ((String) -> Void)?
    var onTerminalNotification: ((String, String) -> Void)?
    @Environment(AppState.self) var appState
    @EnvironmentObject var appearance: AppearanceSettings
    /// Called only after tmux positively confirms the requested window is absent.
    /// The callback owns the persistent automatic-recovery budget and recreation.
    var onMissingWindow: (@MainActor () async -> AutomaticTerminalRecreationOutcome)?
    /// When set, this ANSI text is fed into the terminal buffer before the tmux
    /// client connects. The live tmux output overwrites it seamlessly.
    /// See docs/superpowers/specs/2026-03-31-snapshot-display-approaches.md for
    /// alternative approaches that were tried and why they failed.
    var initialSnapshot: String?
    /// When true, the terminal was suspended at view creation time. The view
    /// feeds the snapshot but does NOT start a tmux client — the old window's
    /// shell would overwrite the snapshot. Once resume completes and
    /// `tmuxWindowID` changes, the view is recreated (`.id` changes) with
    /// this flag false, and tmux connects normally.
    var isSuspendedSnapshot: Bool = false
    /// Reason-phrased hibernate notice for a PARKED pane (see
    /// `HibernatedBannerModel.message(for:)`). When set alongside
    /// `isSuspendedSnapshot`, the notice is composed INTO the fed snapshot as
    /// its last rows — in the terminal's own grid/font — via
    /// `ParkedSnapshotComposer` (render-time only; the stored snapshot stays
    /// clean). nil for live terminals: the snapshot is fed untouched (it is
    /// the reconnect backdrop on wake).
    var parkedNoticeMessage: String? = nil
    /// Called on every scroll/click event. When it returns `true`, both
    /// NSEvent monitors short-circuit — the terminal does NOT consume the
    /// event, leaving it for whatever SwiftUI overlay (currently a
    /// transcript-card overlay; see #129) is rendered on top. Must be
    /// `@MainActor` since it is invoked from inside `assumeIsolated` blocks.
    var shouldSuppressEvents: @MainActor () -> Bool = { false }

    @State private var proxyWarning: String?
    @State private var didProbe = false
    @State private var recoveryGuidanceMessage: String?

    /// Profile id pinned to this terminal (if any). Used as the `.task` id so
    /// the probe re-fires once AppState populates. `nil` while AppState hasn't
    /// loaded the terminal yet — the probe just returns without consuming its
    /// one-shot gate.
    private var pinnedProfileID: UUID? {
        appState.terminals.values.flatMap({ $0 })
            .first(where: { $0.id == terminalID })?.profileID
    }

    /// This terminal's control-mode pane key, for the input-health indicator.
    /// `nil` while AppState hasn't loaded the terminal yet.
    private var controlModePaneKey: ControlModePaneKey? {
        appState.terminals.values.flatMap({ $0 })
            .first(where: { $0.id == terminalID })
            .map { ControlModePaneKey(worktreeID: $0.worktreeID, paneID: $0.tmuxPaneID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let warning = proxyWarning,
               !appState.dismissedProxyWarnings.contains(terminalID) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(warning).font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        appState.dismissedProxyWarnings.insert(terminalID)
                    }
                        .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.yellow.opacity(0.2))
            }
            // Passive input-delivery indicator (#318 polish): shows only while
            // this pane is control-mode attached AND the daemon has flagged
            // its input failing (edge-triggered deltas); clears itself on the
            // recovery delta or on detach — no dismiss affordance.
            if let paneKey = controlModePaneKey, appState.isInputDeliveryFailing(paneKey) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Input not being delivered — keystrokes are not reaching this pane")
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.18))
            }
            if let recoveryGuidanceMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(recoveryGuidanceMessage)
                        .font(.caption)
                    Spacer()
                    Button(TerminalRecoveryPresentation.retryTitle) {
                        Task {
                            await appState.recreateTerminalWindow(terminalID: terminalID)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.18))
            }
            TerminalPanelRepresentable(
                terminalID: terminalID,
                tmuxServer: tmuxServer,
                tmuxWindowID: tmuxWindowID,
                tmuxBridge: tmuxBridge,
                tabCloseContext: tabCloseContext,
                worktreePath: worktreePath,
                remoteURL: remoteURL,
                onFilePathClicked: onFilePathClicked,
                onTerminalNotification: onTerminalNotification,
                onMissingWindow: onMissingWindow,
                onRecoveryGuidance: { recoveryGuidanceMessage = $0 },
                initialSnapshot: initialSnapshot,
                isSuspendedSnapshot: isSuspendedSnapshot,
                parkedNoticeMessage: parkedNoticeMessage,
                shouldSuppressEvents: shouldSuppressEvents
            )
        }
        .task(id: pinnedProfileID) {
            await maybeProbeProxy()
        }
    }

    @MainActor
    private func maybeProbeProxy() async {
        if didProbe { return }

        // Look up the pinned profile for this terminal. Only proxy profiles
        // (baseURL != nil) get probed — Claude-direct has nothing to be
        // unreachable. If the lookup fails (AppState hasn't populated yet),
        // return WITHOUT setting `didProbe` so a later `.task` fire — once
        // `pinnedProfileID` settles — gets another chance.
        guard let terminal = appState.terminals.values.flatMap({ $0 })
            .first(where: { $0.id == terminalID }),
              let profileID = terminal.profileID,
              let profile = appState.modelProfiles
                  .first(where: { $0.profile.id == profileID })?.profile,
              let baseURL = profile.baseURL, !baseURL.isEmpty
        else {
            return
        }

        didProbe = true   // gate further attempts only once we actually probe

        // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
        try? await Task.sleep(nanoseconds: 500_000_000)
        let result = await appState.healthCheckProfile(baseURL: baseURL)
        if !result.reachable {
            proxyWarning = "Proxy unreachable at \(baseURL). Is your local proxy running?"
            logger.debug("proxy unreachable for terminal \(terminalID, privacy: .public) base=\(baseURL, privacy: .public) detail=\(result.detail ?? "nil", privacy: .public)")
        }
    }

    /// Builds the environment for the SwiftTerm PTY that runs the tmux attach client.
    ///
    /// The viewer environment must have `TMUX` and `TMUX_PANE` removed to prevent
    /// nested-attach errors. When TBD.app itself is launched from inside a tmux session
    /// (e.g., running `scripts/restart.sh` from a TBD pane), the parent environment
    /// contains these variables. tmux's `attach` client refuses with:
    /// "sessions should be nested with care, unset $TMUX to force" (exit 1) if run
    /// in a nested context. The attach client must always be a fresh top-level tmux client.
    ///
    /// - Parameter base: Base environment dict (typically ProcessInfo.processInfo.environment)
    /// - Returns: Cleaned environment with TMUX/TMUX_PANE removed and TERM set to xterm-256color
    nonisolated static func makeViewerEnvironment(base: [String: String]) -> [String: String] {
        var env = base
        env.removeValue(forKey: "TMUX")
        env.removeValue(forKey: "TMUX_PANE")
        env["TERM"] = "xterm-256color"
        return env
    }
}

// MARK: - TerminalPanelRepresentable

/// Wraps SwiftTerm's `TerminalView` in a SwiftUI `NSViewRepresentable`.
///
/// Uses tmux grouped sessions for session persistence:
/// 1. TmuxBridge creates a grouped session pointing at the right window
/// 2. SwiftTerm spawns `tmux attach -t <grouped-session>` in a native PTY
/// 3. All input, output, and resize handled natively by the terminal driver
struct TerminalPanelRepresentable: NSViewRepresentable {
    let terminalID: UUID
    let tmuxServer: String
    let tmuxWindowID: String
    let tmuxBridge: TmuxBridge
    var tabCloseContext: TabCloseContext? = nil
    var worktreePath: String = ""
    var remoteURL: String?
    var onFilePathClicked: ((String) -> Void)?
    var onTerminalNotification: ((String, String) -> Void)?
    @Environment(AppState.self) var appState
    @EnvironmentObject var appearance: AppearanceSettings
    var onMissingWindow: (@MainActor () async -> AutomaticTerminalRecreationOutcome)?
    var onRecoveryGuidance: (@MainActor (String) -> Void)?
    var initialSnapshot: String?
    var isSuspendedSnapshot: Bool = false
    var parkedNoticeMessage: String? = nil
    var shouldSuppressEvents: @MainActor () -> Bool = { false }

    func makeNSView(context: Context) -> TBDTerminalView {
        let tv = TBDTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: appearance.font,
            appearance: appearance
        )

        // Disable mouse reporting so click-drag selects text locally
        // instead of forwarding mouse events to tmux
        tv.allowMouseReporting = false

        // Wire up Cmd+Click file path detection
        tv.worktreePath = worktreePath
        tv.remoteURL = remoteURL
        tv.onFilePathClicked = onFilePathClicked
        tv.onNotification = onTerminalNotification
        tv.isCodexTerminal = appState.terminals.values
            .flatMap { $0 }
            .first(where: { $0.id == terminalID })?
            .isCodexTerminal == true
        tv.onCloseTab = {
            appState.closeFocusedTab()
        }

        // Set delegate for terminal events
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv
        context.coordinator.tmuxBridge = tmuxBridge
        context.coordinator.tmuxServer = tmuxServer
        context.coordinator.panelID = terminalID
        context.coordinator.appState = appState
        context.coordinator.syncTabCloseContext(tabCloseContext, for: terminalID)
        context.coordinator.onMissingWindow = onMissingWindow
        context.coordinator.onRecoveryGuidance = onRecoveryGuidance
        context.coordinator.shouldSuppressEvents = shouldSuppressEvents

        // Feed snapshot before tmux connects so the user sees the last state
        let snapshot = initialSnapshot
        let suspendedOnCreate = isSuspendedSnapshot
        let parkedMessage = parkedNoticeMessage
        // Control-mode branch (Phase 2, opt-in): gate on the DAEMON-reported
        // capability — the app cannot read TBD_TMUX_CONTROL_MODE itself (it is
        // launched via `open`, which drops shell env). Resolve the terminal's
        // worktreeID + paneID up front; if the lookup fails, fall back to the
        // grouped-sessions path.
        let controlModeAttach: (worktreeID: UUID, paneID: String)? =
            appState.daemonCapabilities?.controlModeEnabled == true
                ? appState.terminals.values.flatMap({ $0 })
                    .first(where: { $0.id == terminalID })
                    .map { ($0.worktreeID, $0.tmuxPaneID) }
                : nil
        let appStateRef = appState
        // Start tmux client as soon as the view has real dimensions from layout
        tv.onReady = { [weak tv] in
            guard let tv else { return }
            // PARKED pane: compose the hibernate notice INTO the snapshot as
            // its last rows (a notice block overwriting the frozen status-bar
            // chrome), padded to the
            // view's REAL column count — onReady fires once layout has given
            // the terminal its true dimensions, so `tv.terminalDimensions.cols` is the
            // same source the resize paths use. A nil snapshot still yields
            // the block alone (a capture-less parked pane used to be pitch
            // black). The live/wake path (`suspendedOnCreate == false`) feeds
            // the snapshot untouched — it is the reconnect backdrop.
            let feedText: String?
            if suspendedOnCreate, let parkedMessage {
                feedText = ParkedSnapshotComposer.compose(
                    snapshot: snapshot, message: parkedMessage, columns: tv.terminalDimensions.cols)
            } else {
                feedText = snapshot
            }
            if let feedText {
                // SwiftTerm expects \r\n line endings. Normalize first to avoid
                // doubling any \r\n that might already exist in the snapshot.
                // The composed notice block rides the same normalization so
                // it cannot stair-step.
                let normalized = feedText
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\n", with: "\r\n")
                tv.feed(text: normalized)
            }
            // Skip tmux connect for suspended terminals — the old window's shell
            // would overwrite the snapshot. The view will be recreated with a new
            // .id when tmuxWindowID changes after resume completes.
            guard !suspendedOnCreate else { return }
            // Detach to a Task so `prepareSession` (which spawns tmux subprocesses)
            // doesn't block the main thread. `startTmuxClient` hops back to
            // `@MainActor` once the tmux args come back.
            Task { [weak coordinator = context.coordinator, weak tv] in
                guard let coordinator, let tv else { return }
                if let controlModeAttach {
                    await coordinator.startControlModeClient(
                        terminalView: tv,
                        appState: appStateRef,
                        worktreeID: controlModeAttach.worktreeID,
                        paneID: controlModeAttach.paneID,
                        bridge: tmuxBridge,
                        server: tmuxServer,
                        windowID: tmuxWindowID,
                        panelID: terminalID
                    )
                } else {
                    await coordinator.startTmuxClient(
                        terminalView: tv,
                        bridge: tmuxBridge,
                        server: tmuxServer,
                        windowID: tmuxWindowID,
                        panelID: terminalID
                    )
                }
            }
        }

        // Register snapshot provider so SidebarContextMenu can capture this view
        let captureID = terminalID
        appState.snapshotProviders[captureID] = { [weak tv] in
            tv?.captureScreenshot()
        }
        appState.registerTerminalView(tv, for: terminalID)

        return tv
    }

    func updateNSView(_ nsView: TBDTerminalView, context: Context) {
        nsView.isCodexTerminal = appState.terminals.values
            .flatMap { $0 }
            .first(where: { $0.id == terminalID })?
            .isCodexTerminal == true
        context.coordinator.syncTabCloseContext(tabCloseContext, for: terminalID)
        context.coordinator.onRecoveryGuidance = onRecoveryGuidance
    }

    static func dismantleNSView(_ nsView: TBDTerminalView, coordinator: Coordinator) {
        coordinator.appState?.unregisterTerminalView(nsView, for: coordinator.panelID)
        coordinator.cleanup()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, TerminalViewDelegate, LocalProcessDelegate, @unchecked Sendable {
        weak var terminalView: TerminalView?
        weak var appState: AppState?
        var tmuxBridge: TmuxBridge?
        var tmuxServer: String = ""
        var panelID: UUID = UUID()
        var tabCloseContext: TabCloseContext?
        var onMissingWindow: (@MainActor () async -> AutomaticTerminalRecreationOutcome)?
        var onRecoveryGuidance: (@MainActor (String) -> Void)?
        /// Returns `true` when a SwiftUI overlay (e.g. transcript card) is open
        /// over this terminal and should receive scroll/click events instead of
        /// the terminal. Set by `TerminalPanelRepresentable.makeNSView`.
        var shouldSuppressEvents: @MainActor () -> Bool = { false }
        /// Internal rather than private so `TerminalTeardownReapTests` can hand
        /// this coordinator a real `LocalProcess` and drive `cleanup()`
        /// headlessly — the reap wiring is otherwise unreachable from a test,
        /// since everything else about this type needs a live `NSView`.
        var localProcess: LocalProcess?
        /// The IO-thread feed path (`dataReceived` → `feed`) reaches the view
        /// through this lock-guarded holder rather than the main-confined
        /// `terminalView` weak var. Written before `startProcess`, cleared by
        /// `cleanup()` before the `LocalProcess` is released.
        private let viewHolder = TerminalViewHolder()
        private var groupedViewerProcessRunning = false
        private var groupedViewerProcessGeneration: UInt64 = 0
        private var groupedViewerConfirmationStarted = false
        private var groupedViewerAttachmentConfirmed = false
        private var groupedViewerConfirmationAttemptCount = 0
        private static let maximumGroupedViewerConfirmationAttempts = 2
        /// Recorded when `LocalProcess`'s own exit monitor fires — by then it
        /// has already called `waitpid`, so `cleanup()` must NOT reap this pid
        /// (it is free, and could have been recycled for another child of this
        /// process). Both sides run on the main queue with the pinned SwiftTerm
        /// revision; see `ChildExitObservation` for why it is lock-guarded
        /// anyway and for the reaper thread that also reads it.
        private let childExitObservation = ChildExitObservation()
        // `nonisolated(unsafe)`: same pattern as `TBDTerminalView.mouseMonitor`
        // — set and removed on main, but `deinit` is nonisolated and must be
        // able to remove a monitor the main-actor teardown missed.
        nonisolated(unsafe) private var scrollMonitor: Any?
        nonisolated(unsafe) private var clickMonitor: Any?
        private var fedPreparationMessages: Set<String> = []
        /// Set while this panel renders through the control-mode path (Phase 2
        /// FD vending). `cleanup()` uses these to pair the teardown correctly:
        /// `pane.detach` RPC first (daemon EOFs the pipe), then flag the
        /// reader stopped — the reader closes its own fd when the EOF lands.
        /// `windowID` is carried for `pane.resize` (M3.2): the daemon sizes per
        /// WINDOW, so resize RPCs need it.
        private var controlModeAttach:
            (worktreeID: UUID, paneID: String, windowID: String, routingKey: String, generation: UInt64?)?
        /// Debounces control-mode `pane.resize` RPCs (M3.2). Cancel-and-replace
        /// so only the tail of a window-drag flurry reaches the daemon; cancelled
        /// in `cleanup()`.
        private var resizeDebounceTask: Task<Void, Never>?
        /// Latest-wins cross-call ordering for the debounced resizes (R5-M3):
        /// at most one `paneResize` RPC in flight; a tick landing meanwhile
        /// stashes and the in-flight sender's completion drains it. MainActor-
        /// confined like `resizeDebounceTask` — mutated only from the
        /// `@MainActor` debounce path.
        private var resizeSerializer = ControlModeResizeSerializer()
        /// Set (permanently) by `cleanup()` when the view is torn down. The
        /// attach establishment in `startControlModeClient` re-checks it
        /// after every `await` resumption and self-detaches anything it
        /// committed after the teardown ran (review H2) — `cleanup()`'s own
        /// attach teardown only covers an attach that had already landed in
        /// `controlModeAttach`. MainActor-confined: `cleanup()` is called
        /// from `dismantleNSView` and every reader is a `@MainActor` method,
        /// so plain-var access is race-free.
        private var isTornDown = false

        @MainActor
        func syncTabCloseContext(_ context: TabCloseContext?, for terminalID: UUID) {
            guard tabCloseContext != context else { return }
            tabCloseContext = context
            appState?.registerTerminalCloseContext(context, for: terminalID)
        }

        nonisolated static func preparationAction(
            for result: Result<TmuxPreparedSession, TmuxPreparationFailure>
        ) -> TerminalPreparationAction {
            switch result {
            case .success(let prepared):
                return .startViewer(prepared)
            case .failure(.commandFailed):
                return .showMessage(TerminalPreparationPresentation.commandFailedMessage)
            case .failure(.windowMissing(let failedStage)):
                return .requestAutomaticRecovery(failedStage: failedStage)
            case .failure(.tmuxExecutableUnavailable):
                return .showMessage(TerminalPreparationPresentation.tmuxExecutableUnavailableMessage)
            }
        }

        nonisolated static func recoveryMessage(
            for outcome: AutomaticTerminalRecreationOutcome
        ) -> String? {
            switch outcome {
            case .failed:
                return TerminalRecoveryPresentation.failedMessage
            case .budgetExhausted:
                return TerminalRecoveryPresentation.exhaustedMessage
            case .alreadyInFlight, .terminalUnavailable, .recreated:
                return nil
            }
        }

        @MainActor
        func recoveryGuidanceDidBecomeAvailable(_ message: String) {
            onRecoveryGuidance?(message)
        }

        @MainActor
        func shouldFeedPreparationMessage(_ message: String) -> Bool {
            fedPreparationMessages.insert(message).inserted
        }

        @MainActor
        @discardableResult
        func groupedViewerProcessDidStart(processRunning: Bool) -> UInt64 {
            groupedViewerProcessGeneration &+= 1
            groupedViewerProcessRunning = processRunning
            groupedViewerConfirmationStarted = false
            groupedViewerAttachmentConfirmed = false
            groupedViewerConfirmationAttemptCount = 0
            return groupedViewerProcessGeneration
        }

        @MainActor
        func beginGroupedViewerAttachmentConfirmation() -> UInt64? {
            guard groupedViewerProcessRunning,
                  !groupedViewerConfirmationStarted,
                  !groupedViewerAttachmentConfirmed,
                  groupedViewerConfirmationAttemptCount < Self.maximumGroupedViewerConfirmationAttempts,
                  !isTornDown else { return nil }
            groupedViewerConfirmationStarted = true
            groupedViewerConfirmationAttemptCount += 1
            return groupedViewerProcessGeneration
        }

        @MainActor
        func groupedViewerDidReceiveOutput() {
            guard let tmuxBridge,
                  let processGeneration = beginGroupedViewerAttachmentConfirmation() else { return }
            let server = tmuxServer
            let panelID = panelID
            Task { [weak self] in
                let attached = await tmuxBridge.hasAttachedClient(
                    panelID: panelID,
                    server: server
                )
                let shouldRetry = self?.groupedViewerAttachmentProbeDidComplete(
                    clientAttached: attached,
                    processGeneration: processGeneration
                ) ?? false
                if shouldRetry {
                    self?.groupedViewerDidReceiveOutput()
                }
            }
        }

        @MainActor
        func groupedViewerAttachmentProbeDidComplete(
            clientAttached: Bool,
            processGeneration: UInt64
        ) -> Bool {
            guard processGeneration == groupedViewerProcessGeneration,
                  !groupedViewerAttachmentConfirmed,
                  !isTornDown else { return false }
            guard clientAttached else {
                guard groupedViewerProcessRunning,
                      groupedViewerConfirmationAttemptCount < Self.maximumGroupedViewerConfirmationAttempts else {
                    return false
                }
                // Re-arm one immediate retry. This does not depend on another
                // PTY output chunk, which an attached idle client may never emit.
                groupedViewerConfirmationStarted = false
                return true
            }
            guard groupedViewerProcessRunning else { return false }
            groupedViewerAttachmentConfirmed = true
            appState?.terminalViewerDidStart(terminalID: panelID)
            return false
        }

        @MainActor
        func groupedViewerProcessDidTerminate() {
            groupedViewerProcessRunning = false
            groupedViewerConfirmationStarted = false
        }

        @MainActor
        func controlModeViewerDidStart() {
            appState?.terminalViewerDidStart(terminalID: panelID)
        }

        @MainActor
        func worktreeIDForDiagnostics() -> UUID? {
            appState?.terminals.values
                .lazy
                .flatMap { $0 }
                .first(where: { $0.id == panelID })?
                .worktreeID
        }

        @MainActor
        func recoveryDiagnosticContext() -> TerminalRecoveryDiagnosticContext {
            TerminalRecoveryDiagnosticContext(
                terminalID: panelID,
                worktreeID: worktreeIDForDiagnostics()
            )
        }

        @MainActor
        private func feedPreparationMessage(_ message: String, into terminalView: TerminalView) {
            guard shouldFeedPreparationMessage(message) else { return }
            terminalView.feed(text: "\r\n  \(message)\r\n")
        }

        @MainActor
        private func logPreparationFailure(_ failure: TmuxPreparationFailure) {
            let worktreeID = worktreeIDForDiagnostics()?.uuidString ?? "unknown"
            switch failure {
            case .windowMissing(let failedStage):
                logger.error(
                    "terminal preparation failed terminal=\(self.panelID, privacy: .public) worktree=\(worktreeID, privacy: .public) stage=\(failedStage.rawValue, privacy: .public) category=windowMissing"
                )
            case .tmuxExecutableUnavailable:
                logger.error(
                    "terminal preparation failed terminal=\(self.panelID, privacy: .public) worktree=\(worktreeID, privacy: .public) stage=\(TmuxPreparationStage.createViewSession.rawValue, privacy: .public) category=tmuxExecutableUnavailable"
                )
            case .commandFailed(let stage, let output):
                logger.error(
                    "terminal preparation failed terminal=\(self.panelID, privacy: .public) worktree=\(worktreeID, privacy: .public) stage=\(stage.rawValue, privacy: .public) category=commandFailed"
                )
                logger.debug(
                    "terminal preparation subprocess output terminal=\(self.panelID, privacy: .public) worktree=\(worktreeID, privacy: .public) stage=\(stage.rawValue, privacy: .public) output=\(output, privacy: .private)"
                )
            }
        }

        @MainActor
        private func logAutomaticRecoveryOutcome(
            _ outcome: AutomaticTerminalRecreationOutcome,
            failedStage: TmuxPreparationStage,
            diagnosticContext: TerminalRecoveryDiagnosticContext
        ) {
            let terminalID = diagnosticContext.terminalID
            let worktreeID = diagnosticContext.worktreeID?.uuidString ?? "unknown"
            switch outcome {
            case .alreadyInFlight:
                logger.info(
                    "automatic terminal recovery terminal=\(terminalID, privacy: .public) worktree=\(worktreeID, privacy: .public) stage=\(failedStage.rawValue, privacy: .public) category=alreadyInFlight"
                )
            case .terminalUnavailable:
                logger.info(
                    "automatic terminal recovery terminal=\(terminalID, privacy: .public) worktree=\(worktreeID, privacy: .public) stage=\(failedStage.rawValue, privacy: .public) category=terminalUnavailable"
                )
            case .recreated(let attempt):
                logger.info(
                    "automatic terminal recovery terminal=\(terminalID, privacy: .public) worktree=\(worktreeID, privacy: .public) stage=\(failedStage.rawValue, privacy: .public) category=recreated attempt=\(attempt, privacy: .public)"
                )
            case .failed(let attempt):
                logger.error(
                    "automatic terminal recovery terminal=\(terminalID, privacy: .public) worktree=\(worktreeID, privacy: .public) stage=\(failedStage.rawValue, privacy: .public) category=failed attempt=\(attempt, privacy: .public)"
                )
            case .budgetExhausted:
                logger.error(
                    "automatic terminal recovery terminal=\(terminalID, privacy: .public) worktree=\(worktreeID, privacy: .public) stage=\(failedStage.rawValue, privacy: .public) category=budgetExhausted attempt=none"
                )
            }
        }

        @MainActor
        func startTmuxClient(
            terminalView: TerminalView,
            bridge: TmuxBridge,
            server: String,
            windowID: String,
            panelID: UUID
        ) async {
            // A torn-down view must never (re)start a client (review H2):
            // checked at entry AND after the await below — teardown can land
            // while `prepareSession` is in flight, and the LocalProcess +
            // NSEvent monitors committed after it would leak (cleanup()
            // already ran; only deinit would remove the monitors, nothing
            // would terminate the process).
            guard ControlModeAttachAbort.shouldStartFallback(tornDown: isTornDown) else { return }
            // `prepareSession` is non-isolated and awaits tmux subprocesses
            // off the main actor — Swift releases main while we suspend here,
            // so SwiftUI's render loop is no longer blocked while tmux runs.
            let result: Result<TmuxPreparedSession, TmuxPreparationFailure> = await bridge.prepareSession(
                panelID: panelID,
                server: server,
                windowID: windowID
            )

            // Teardown may land while preparation is in flight. Do not render,
            // recover, or start a viewer for a coordinator that is no longer live.
            guard ControlModeAttachAbort.shouldStartFallback(tornDown: isTornDown) else { return }

            let prepared: TmuxPreparedSession
            switch Self.preparationAction(for: result) {
            case .showMessage(let message):
                if case .failure(let failure) = result {
                    logPreparationFailure(failure)
                }
                feedPreparationMessage(message, into: terminalView)
                return
            case .requestAutomaticRecovery(let failedStage):
                if case .failure(let failure) = result {
                    logPreparationFailure(failure)
                }
                guard let onMissingWindow else { return }
                let diagnosticContext = recoveryDiagnosticContext()
                let outcome = await onMissingWindow()
                logAutomaticRecoveryOutcome(
                    outcome,
                    failedStage: failedStage,
                    diagnosticContext: diagnosticContext
                )
                if let message = Self.recoveryMessage(for: outcome) {
                    recoveryGuidanceDidBecomeAvailable(message)
                    feedPreparationMessage(message, into: terminalView)
                }
                return
            case .startViewer(let value):
                prepared = value
            }

            let tmuxPath = prepared.executablePath
            let processArgs = prepared.arguments

            debugLog("PANEL: Starting: \(tmuxPath) \(processArgs.joined(separator: " "))")

            // Build viewer environment with TMUX/TMUX_PANE scrubbed and TERM set correctly
            let env = TerminalPanelView.makeViewerEnvironment(base: ProcessInfo.processInfo.environment)
            let envPairs = env.map { "\($0.key)=\($0.value)" }

            // `dispatchQueue: .main` keeps the exit monitor on main (see the
            // serialization note in ChildReaper.swift); `directDelivery: true`
            // delivers `dataReceived` inline on the IO thread, where `feed`
            // parses off-main — the configuration upstream's own
            // `MacLocalTerminalView` ships.
            let process = LocalProcess(delegate: self, dispatchQueue: .main, directDelivery: true)
            self.localProcess = process
            // Written before startProcess; the IO thread reads it from
            // `dataReceived`. Cleared by `cleanup()` before the process is
            // released.
            viewHolder.set(terminalView)

            process.startProcess(
                executable: tmuxPath,
                args: processArgs,
                environment: envPairs,
                execName: nil
            )
            groupedViewerProcessDidStart(processRunning: process.running)

            // Send correct initial size from SwiftTerm's own computed dimensions
            // (accounts for scroller width and actual cell metrics).
            // The enclosing function is `@MainActor async`, so we're already
            // main-isolated here — no `assumeIsolated` wrapper needed.
            do {
                let dims = terminalView.terminalDimensions
                let cols = dims.cols
                let rows = dims.rows
                if cols > 0 && rows > 0 && process.childfd >= 0 {
                    var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
                    _ = ioctl(process.childfd, TIOCSWINSZ, &size)
                    debugLog("PANEL: initial resize \(cols)x\(rows)")
                }
            }

            // Focus on next run loop iteration (needs main actor for window access)
            DispatchQueue.main.async {
                terminalView.window?.makeFirstResponder(terminalView)
                self.appState?.focusedTabCloseContext = self.tabCloseContext
            }

            // Intercept scroll wheel events before they reach TerminalView.
            // TerminalView.scrollWheel is not `open`, so we can't override it
            // in TBDTerminalView. Instead, a local event monitor intercepts
            // scroll events and forwards them to tmux as mouse button presses.
            //
            // Visibility filter: the `tv.window != nil` guard inside the
            // closure rejects events when the terminal isn't currently part of
            // the visible UI. This is load-bearing for the worktree keep-alive
            // system (see WorktreePager + TerminalContainerView): inactive
            // worktrees keep their terminal NSViews alive but detached from the
            // window. Without the guard, every kept-alive terminal's monitor
            // would still fire for every app-wide scroll-wheel event, and the
            // `bounds.contains(point)` check below wouldn't filter them out
            // (bounds-space math works fine on detached views) — events would
            // be silently consumed and forwarded to hidden terminals' tmux
            // sessions, scrolling them invisibly. tv.window == nil ⇒ this
            // terminal isn't visible right now ⇒ no-op the monitor.
            let ref = WeakTerminalRef(terminalView)
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                let deltaY = event.deltaY
                let location = event.locationInWindow
                guard deltaY != 0 else { return event }

                let consumed = MainActor.assumeIsolated { [weak self] in
                    guard let self else { return false }
                    guard let tv = ref.view as? TBDTerminalView else { return false }
                    guard tv.window != nil else { return false }
                    // Short-circuit when a SwiftUI overlay is open on top of this
                    // terminal — pass the event through so the overlay can handle it.
                    if self.shouldSuppressEvents() { return false }
                    let point = tv.convert(location, from: nil)
                    guard tv.bounds.contains(point) else { return false }

                    // Use actual scroll position so tmux routes to the correct pane.
                    // Grid math runs OUTSIDE the lock (view API); the mouseMode
                    // guard and the sends ride one `withTerminal` block — the
                    // same calls, under the same lock, as SwiftTerm's own
                    // native mouse-reporting path.
                    guard let (col, row) = tv.gridPosition(atWindowLocation: location) else { return false }

                    let isUp = deltaY > 0
                    let lines = max(1, Int(abs(deltaY)))
                    return tv.withTerminal { term -> Bool in
                        guard term.mouseMode != .off else { return false }
                        let buttonFlags = term.encodeButton(
                            button: isUp ? 4 : 5,
                            release: false, shift: false, meta: false, control: false
                        )
                        for _ in 0..<lines {
                            term.sendEvent(buttonFlags: buttonFlags, x: col, y: row)
                        }
                        return true
                    }
                }
                return consumed ? nil : event
            }

            // Intercept clicks: claim first responder on any click (so Cmd+Arrow
            // routes to the focused terminal), and handle Cmd+Click for file paths.
            //
            // Visibility filter: each `assumeIsolated` block guards on
            // `tv.window != nil` for the same reason as scrollMonitor above —
            // the worktree keep-alive system retains terminal NSViews for
            // inactive worktrees in a detached state, and we must skip event
            // processing for those (otherwise clicks would claim first responder
            // for a hidden terminal, or fire Cmd+Click handlers against
            // invisible bounds).
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                let location = event.locationInWindow

                // Claim first responder so key equivalents route to this terminal
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    guard let tv = ref.view else { return }
                    guard tv.window != nil else { return }
                    // Short-circuit when a SwiftUI overlay is open on top of this
                    // terminal — leave first-responder where it is so the overlay
                    // receives key and click events.
                    if self.shouldSuppressEvents() { return }
                    let point = tv.convert(location, from: nil)
                    if !tv.bounds.contains(point) {
                        if self.appState?.focusedTabCloseContext == self.tabCloseContext,
                           tv.window?.firstResponder === tv {
                            self.appState?.focusedTabCloseContext = nil
                        }
                        return
                    }
                    self.appState?.focusedTabCloseContext = self.tabCloseContext
                    tv.window?.makeFirstResponder(tv)
                }

                guard event.modifierFlags.contains(.command) else { return event }

                let consumed = MainActor.assumeIsolated { [weak self] () -> Bool in
                    guard let self else { return false }
                    guard let tv = ref.view as? TBDTerminalView else { return false }
                    guard tv.window != nil else { return false }
                    if self.shouldSuppressEvents() { return false }
                    let point = tv.convert(location, from: nil)
                    guard tv.bounds.contains(point) else { return false }

                    // OSC 8 hyperlinks are handled by SwiftTerm's mouseUp path
                    // (requestOpenLink). If we also fired here on mouseDown,
                    // a single cmd+click would route through both paths and
                    // open two viewer panes.
                    if tv.hasOSC8Payload(atWindowLocation: location) {
                        logger.debug("file-click: skipping mouseDown handling — OSC 8 payload present, deferring to requestOpenLink")
                        return false
                    }

                    if let filePath = tv.extractFilePath(atWindowLocation: location) {
                        logger.debug("file-click[mouseDown/path]: \(filePath, privacy: .public)")
                        tv.onFilePathClicked?(filePath)
                        return true
                    }
                    // Fall back to hyperlink detection (PR pattern; OSC 8 was
                    // already short-circuited above).
                    if let urlString = tv.extractHyperlinkURL(atWindowLocation: location) {
                        if let resolved = tv.resolveAsFilePath(urlString) {
                            logger.debug("file-click[mouseDown/hyperlink-as-file]: \(resolved, privacy: .public)")
                            tv.onFilePathClicked?(resolved)
                            return true
                        }
                        if urlString.contains("://"), let url = URL(string: urlString) {
                            NSWorkspace.shared.open(url)
                            return true
                        }
                    }
                    return false
                }
                return consumed ? nil : event
            }
        }

        @MainActor
        func cleanup() {
            debugLog("PANEL: cleanup for \(panelID.uuidString.prefix(8))")
            // Idempotent: a second call must not re-run the teardown (it would
            // reap a pid whose `LocalProcess` this method already released).
            guard !isTornDown else { return }
            // Before anything else: any in-flight attach establishment must
            // see the teardown at its next await resumption (review H2).
            isTornDown = true
            // Capture the pid BEFORE anything releases the `LocalProcess` —
            // it is the only thing that knows it.
            let ptyChildPid = localProcess?.shellPid ?? 0
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
                clickMonitor = nil
            }
            tmuxBridge?.cleanupSession(panelID: panelID, server: tmuxServer)
            resizeDebounceTask?.cancel()
            resizeDebounceTask = nil
            (terminalView as? TBDTerminalView)?.onControlModePaste = nil
            if let attach = controlModeAttach, let appState {
                controlModeAttach = nil
                Task {
                    // Clear the attach record + any failing-input flag first
                    // so the indicator vanishes with the pane (#318 polish).
                    // Generation-scoped like the daemon-side detach below: a
                    // closing view's clear racing a new view's attach for the
                    // same pane must not drop the fresh attach's record.
                    appState.controlModePaneDetached(
                        worktreeID: attach.worktreeID, paneID: attach.paneID,
                        generation: attach.generation)
                    // Order matters: detach first so the daemon closes the
                    // pipe's write end (EOF unblocks the reader thread), then
                    // flag the reader — it closes its own fd on exit. The
                    // generation scopes the detach to THIS attach: a closing
                    // view's detach racing a new view's attach for the same
                    // pane must not kill the fresh sink.
                    try? await appState.daemonClient.paneDetach(
                        worktreeID: attach.worktreeID, paneID: attach.paneID,
                        generation: attach.generation)
                    await appState.controlModeReaders.remove(
                        routingKey: attach.routingKey, generation: attach.generation)
                }
            }
            // Release the PTY child's `LocalProcess` and reap the child.
            //
            // How the child dies is unchanged by this block. In practice the
            // dominant path is the `tmuxBridge?.cleanupSession` call above:
            // it runs `tmux kill-session`, which ends the session this client
            // is attached to, so the attach client exits on its own. Failing
            // that, `LocalProcess.deinit` closes the master fd here and the
            // child exits on the resulting SIGHUP.
            //
            // What *is* deliberate is niling `localProcess` rather than
            // leaving it to ARC. deinit then runs at a known moment and
            // cancels SwiftTerm's `childMonitor` here, which is what makes
            // `ChildReaper` the sole `waitpid` waiter for this pid. deinit
            // never calls `waitpid` itself, so without the reap the child
            // stays `<defunct>` under TBDApp forever.
            //
            // Control-mode panels have no `LocalProcess` at all, so
            // `ptyChildPid` is 0 for them and `shouldReap` rejects it.
            //
            // Clear the holder BEFORE releasing the process: a late IO batch
            // then reads nil and drops instead of feeding a view whose
            // session is being torn down.
            viewHolder.clear()
            localProcess = nil
            ChildReaper.reap(pid: ptyChildPid, unless: childExitObservation)
        }

        /// Render this panel through the control-mode path: request an attach
        /// (fd arrives via the sidecar), wire a long-lived reader that feeds
        /// SwiftTerm, then ack `attach.ready` to open the daemon's write gate.
        /// Any failure falls back to the grouped-sessions path — Phase 2 is
        /// opt-in and read-only, so degradation must be invisible.
        @MainActor
        func startControlModeClient(
            terminalView: TerminalView,
            appState: AppState,
            worktreeID: UUID,
            paneID: String,
            bridge: TmuxBridge,
            server: String,
            windowID: String,
            panelID: UUID
        ) async {
            // Reader-registry key: one reader per PANE (worktree/pane), not per
            // attach — a re-attach replaces the pane's reader. Distinct from
            // the sidecar's per-request demux key, which also carries the
            // attach nonce.
            let routingKey = "\(worktreeID.uuidString)/\(paneID)"
            do {
                let (fd, generation) = try await appState.daemonClient.openAttach(
                    worktreeID: worktreeID, paneID: paneID, windowID: windowID)
                // The view can be torn down while ANY of this function's
                // awaits is in flight, and `cleanup()`'s attach teardown
                // only covers an attach that already landed in
                // `controlModeAttach` — so every resumption that committed
                // a resource re-checks the teardown flag and unwinds what
                // it just acquired (review H2). Here: the fd (nothing owns
                // it yet) and the daemon-side attach.
                if let undo = ControlModeAttachAbort.undo(tornDown: isTornDown, at: .openAttachResolved) {
                    abortLateAttach(undo, fd: fd, appState: appState, worktreeID: worktreeID,
                                    paneID: paneID, routingKey: routingKey, generation: generation)
                    return
                }
                controlModeAttach = (worktreeID, paneID, windowID, routingKey, generation)
                let weakTV = WeakTerminalRef(terminalView)
                await appState.controlModeReaders.registerReader(
                    routingKey: routingKey, fd: fd, generation: generation) { chunk in
                        let bytes = [UInt8](chunk)
                        DispatchQueue.main.async {
                            weakTV.view?.feed(byteArray: bytes[...])
                        }
                    }
                // Teardown during registration: cleanup() ran its attach
                // teardown, but its reader removal can have raced AHEAD of
                // the registration that just completed — remove again.
                if let undo = ControlModeAttachAbort.undo(tornDown: isTornDown, at: .readerRegistered) {
                    abortLateAttach(undo, fd: fd, appState: appState, worktreeID: worktreeID,
                                    paneID: paneID, routingKey: routingKey, generation: generation)
                    return
                }
                // Echo this attach's generation so a stale ready — superseded
                // by a faster re-attach for the same pane — sends nothing on
                // the daemon's shared command client (no pause/unpause under
                // the successor's sequence).
                try await appState.daemonClient.attachReady(
                    worktreeID: worktreeID, paneID: paneID, generation: generation)
                // Teardown during the ready ack: the daemon's gate is open
                // but no viewer exists — detach before wiring anything else.
                if let undo = ControlModeAttachAbort.undo(tornDown: isTornDown, at: .attachReadyAcked) {
                    abortLateAttach(undo, fd: fd, appState: appState, worktreeID: worktreeID,
                                    paneID: paneID, routingKey: routingKey, generation: generation)
                    return
                }
                // Send one initial resize at the view's real size: the window is
                // otherwise stuck at whatever size it had until the user first
                // drags, so fullscreen Claude would render at the wrong width.
                // Same debounced path as live resizes.
                let dims = terminalView.terminalDimensions
                scheduleControlModeResize(cols: dims.cols, rows: dims.rows)
                // Intercept ALL pastes at the view level while attached (the
                // paste ruling v2) and ship them as a `.paste` sidecar frame.
                // Interception happens BEFORE SwiftTerm brackets the content,
                // so the daemon-side `paste-buffer -p` is the SOLE wrapping
                // authority — SwiftTerm's own 2004 tracking can be stale after
                // a tab-switch re-attach, so no size rides the keystroke path.
                // That sole-authority claim is CONTINGENT, not unconditional:
                // `-p` wraps in ESC[200~/ESC[201~ only because the pane's
                // application has enabled bracketed-paste mode (DECSET 2004).
                // Against a pane that has NOT, the same `-p` delivers the bytes
                // verbatim with no markers — measured on tmux 3.6a (22 wrapped
                // bytes vs 10 bare). If an agent TUI ever stops setting 2004,
                // nothing here wraps. Asserted nightly by probe P3 in
                // scripts/nightly-tmux-probes.sh (PR #523), a two-arm probe:
                // 2004 on → wrapped, 2004 off → verbatim.
                // Returns true → the paste is consumed here (frame sent, or
                // oversize refused); false → not attached, SwiftTerm's normal
                // local paste runs.
                (terminalView as? TBDTerminalView)?.onControlModePaste = { [weak self] data in
                    guard let self else { return false }
                    switch PasteInterception.decide(
                        controlModeAttached: self.controlModeAttach != nil, byteCount: data.count) {
                    case .passthrough:
                        return false
                    case .interceptAsPaste:
                        // Empty pasteboard → consume with no frame: there is
                        // nothing to paste and zero-byte `.paste` frames are
                        // never sent — but SwiftTerm must not run either.
                        if !data.isEmpty {
                            self.appState?.daemonClient.fdSidecar.sendPaste(
                                worktreeID: worktreeID, paneID: paneID, bytes: data)
                        }
                        return true
                    case .refuseOversize:
                        logger.error("""
                            control-mode paste refused: \(data.count, privacy: .public) bytes \
                            exceeds the \(SidecarFrameCodec.maxPasteBytes, privacy: .public)-byte \
                            cap; paste dropped — split the content into smaller pastes
                            """)
                        // The log alone is invisible to the user — surface the
                        // refusal in the pane itself, same "\r\n[...]\r\n"
                        // status-line style as processTerminated's messages.
                        self.terminalView?.feed(
                            text: PasteInterception.refusalMessage(byteCount: data.count))
                        return true
                    }
                }
                logger.info("control-mode attach live for pane \(paneID, privacy: .public)")
                // Gate the input-health indicator open for this pane (#318
                // polish): failing deltas only surface while attached. The
                // generation scopes the record to THIS attach so a stale
                // clear can't drop it (M3 review fix).
                appState.controlModePaneAttached(
                    worktreeID: worktreeID, paneID: paneID, generation: generation)
                controlModeViewerDidStart()
            } catch {
                logger.warning("""
                    control-mode attach failed for pane \(paneID, privacy: .public); \
                    falling back to grouped sessions: \(error.localizedDescription, privacy: .public)
                    """)
                // The failure can equally resolve AFTER the view was torn
                // down (review H2's analog hazard). Two things must NOT run
                // then: the grouped-sessions fallback (a PTY + NSEvent
                // monitors for a dead view — nothing would ever terminate
                // that attach client), and the UNCONDITIONAL nil-generation
                // teardown below — cleanup() already tore down anything that
                // had committed (generation-scoped), and a nil-generation
                // detach here could kill a SUCCESSOR view's fresh attach for
                // the same pane (the stale-cleanup class of 56029f5b).
                guard ControlModeAttachAbort.shouldStartFallback(tornDown: isTornDown) else {
                    logger.info("""
                        skipping grouped-sessions fallback for pane \
                        \(paneID, privacy: .public) — the view was torn down while the \
                        attach was in flight
                        """)
                    // cleanup() only tears down an attach that had committed
                    // into `controlModeAttach` — a failure whose generation
                    // was minted INSIDE openAttach (AttachFDVendError from
                    // the fd-vend wait) committed a daemon-side attach that
                    // cleanup() never saw, and without a detach here that
                    // attach + its router/health registration leak (R10-1).
                    // Generation-scoped ONLY: nil means nothing daemon-side
                    // exists, and an unconditional detach from a dead view
                    // could kill a successor's fresh attach for the same
                    // pane (56029f5b class) — send nothing then. No reader
                    // exists for this attach (registration happens after
                    // commit), so there is nothing registry-side to remove.
                    let tornDownGeneration = ControlModeAttachAbort.tornDownTeardownGeneration(
                        committed: controlModeAttach?.generation, error: error)
                    controlModeAttach = nil
                    (terminalView as? TBDTerminalView)?.onControlModePaste = nil
                    if let tornDownGeneration {
                        // Mirrors abortLateAttach's post-await teardown: clear
                        // any generation-scoped AppState record, then the
                        // generation-scoped daemon detach (idempotent against
                        // cleanup()'s own for the same generation).
                        appState.controlModePaneDetached(
                            worktreeID: worktreeID, paneID: paneID, generation: tornDownGeneration)
                        Task {
                            try? await appState.daemonClient.paneDetach(
                                worktreeID: worktreeID, paneID: paneID,
                                generation: tornDownGeneration)
                        }
                    }
                    return
                }
                // Scope the teardown detach to THIS attach when its generation
                // is known: from the committed attach record, or — when the
                // fd-vend wait timed out inside openAttach AFTER attach.request
                // minted one — from the AttachFDVendError that carries it
                // (R6-H2). Only a failure before attach.request succeeded
                // (truly no generation) falls back to the unconditional detach.
                let failedGeneration = ControlModeAttachAbort.teardownGeneration(
                    committed: controlModeAttach?.generation, error: error)
                controlModeAttach = nil
                (terminalView as? TBDTerminalView)?.onControlModePaste = nil
                // Clear any attach record / stale failing flag for this pane
                // — the indicator must never show over the grouped-sessions
                // fallback rendering. Scoped to this attach's generation when
                // known (nil → unconditional): a concurrent fresh attach's
                // record must survive this stale failure's cleanup.
                appState.controlModePaneDetached(
                    worktreeID: worktreeID, paneID: paneID, generation: failedGeneration)
                // Best-effort teardown of any half-completed attach (e.g. fd
                // received and reader registered, but attach.ready failed):
                // detach so the daemon EOFs the pipe, then flag the reader.
                Task {
                    try? await appState.daemonClient.paneDetach(
                        worktreeID: worktreeID, paneID: paneID, generation: failedGeneration)
                    await appState.controlModeReaders.remove(
                        routingKey: routingKey, generation: failedGeneration)
                }
                await startTmuxClient(
                    terminalView: terminalView,
                    bridge: bridge,
                    server: server,
                    windowID: windowID,
                    panelID: panelID
                )
            }
        }

        /// Unwind a late-resolving control-mode attach: the view was torn
        /// down while one of `startControlModeClient`'s awaits was in flight
        /// (review H2). Undoes exactly what the interrupted stage had
        /// committed — `undo` (see `ControlModeAttachAbort`) says who owns
        /// the fd — plus the unconditional parts: the generation-scoped
        /// daemon detach (idempotent against `cleanup()`'s own, harmless to
        /// a successor attach) and any AppState bookkeeping.
        @MainActor
        private func abortLateAttach(
            _ undo: ControlModeAttachAbort.Undo, fd: Int32, appState: AppState,
            worktreeID: UUID, paneID: String, routingKey: String, generation: UInt64?
        ) {
            logger.info("""
                control-mode attach for pane \(paneID, privacy: .public) resolved after \
                view teardown — self-detaching (gen \(generation ?? 0, privacy: .public))
                """)
            controlModeAttach = nil
            (terminalView as? TBDTerminalView)?.onControlModePaste = nil
            // Clear any attach record / failing-input flag (generation-scoped;
            // normally none exists yet — the record is created only after the
            // last teardown checkpoint).
            appState.controlModePaneDetached(
                worktreeID: worktreeID, paneID: paneID, generation: generation)
            if undo.closeFD {
                Darwin.close(fd)
            }
            Task {
                // Order matters (same as cleanup()): detach first so the
                // daemon closes the pipe's write end (EOF unblocks the reader
                // thread), then flag the reader — it closes its own fd on
                // exit.
                try? await appState.daemonClient.paneDetach(
                    worktreeID: worktreeID, paneID: paneID, generation: generation)
                if undo.removeReader {
                    await appState.controlModeReaders.remove(
                        routingKey: routingKey, generation: generation)
                }
            }
        }

        deinit {
            debugLog("PANEL: deinit for \(panelID.uuidString.prefix(8))")
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
            }
            // Reclaim the tmux view session this panel owns. `cleanup()` is
            // the only other caller and it runs solely from
            // `dismantleNSView`, which SwiftUI does not guarantee to run: the
            // bridge log recorded 15 `PANEL: deinit` lines in 35 seconds with
            // no matching `PANEL: cleanup`, each one a view session left
            // behind. That leak is not cosmetic — a view session holding a
            // linked window keeps that window, its pane process and the whole
            // tmux server alive after the owning `main` session is killed,
            // because tmux destroys a window only when its last session
            // reference drops.
            //
            // Only the tmux session is reclaimed here. The pid capture, the
            // PTY reap and the control-mode detach stay in `cleanup()`, which
            // documents why they must happen exactly once.
            //
            // Safe from a non-isolated `deinit`, and idempotent, by
            // construction: `cleanupSession` takes the bridge's own lock,
            // removes this panel from `activeSessions` and kills from a
            // detached task, so after a `cleanup()` there is no entry left and
            // this call returns without issuing a second `kill-session`. That
            // idempotence is what is relied on — NOT `isTornDown`, which is
            // `@MainActor`-confined and must not be read from here.
            tmuxBridge?.cleanupSession(panelID: panelID, server: tmuxServer)
        }

        // MARK: - LocalProcessDelegate
        //
        // `nonisolated`: the Coordinator's `TerminalViewDelegate` conformance
        // makes the class MainActor-isolated, but `LocalProcess` calls
        // `dataReceived` inline on the IO thread (`directDelivery: true`) and
        // the exit monitor's callback contract is queue-, not actor-based.

        nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            // Arrives on main already (`dispatchQueue: .main` governs the
            // exit monitor regardless of `directDelivery`), but the method is
            // nonisolated, so hop explicitly before touching actor state.
            debugLog("PANEL: process terminated, exitCode=\(exitCode ?? -1)")
            // `LocalProcess.processTerminated()` calls `waitpid` before it
            // calls us, so this child is already reaped and its pid is free to
            // be recycled — a later `cleanup()` must not wait on it. Recorded
            // before the `async` below so the flag is set as early as this
            // callback can set it.
            childExitObservation.record()
            DispatchQueue.main.async { [weak self] in
                self?.groupedViewerProcessDidTerminate()
                // This fires when the *attach client* (the on-screen tmux
                // viewer) dies. A clean exit (code 0) means the view was torn
                // down or detached while the underlying tmux window keeps
                // running (`remain-on-exit on`), so the user's shell/agent is
                // still alive — reopening reattaches. A non-zero exit (e.g. the
                // whole tmux server died on sleep/wake or OOM, exit 256) means
                // the session is NOT still running; don't claim it is. Reopening
                // does the right thing for every tab kind — reattaches a live
                // window, parks+resumes a dead Claude one, or respawns a
                // shell/Codex — so use neutral "reconnect" wording that doesn't
                // overpromise a session "recovery" for plain shell/Codex tabs.
                let message: String
                if let code = exitCode, code != 0 {
                    message = "\r\n[View disconnected (exit \(code)). Reopen this tab to reconnect.]\r\n"
                } else {
                    message = "\r\n[View detached — session is still running in the background. Reopen this tab to reattach.]\r\n"
                }
                self?.terminalView?.feed(text: message)
            }
        }

        nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
            // Feed synchronously on the calling (IO) thread — this is the
            // off-main parse the 2.0 bump exists for; `feed` is thread-safe
            // (the parse runs under SwiftTerm's terminal lock) and the view
            // reference is owned by the holder, so a batch racing teardown
            // either completes against a live view or reads nil and drops.
            viewHolder.withView { $0.feed(byteArray: slice) }
            // The viewer-MRU signal keeps its main hop.
            DispatchQueue.main.async { [weak self] in
                self?.groupedViewerDidReceiveOutput()
            }
        }

        nonisolated func getWindowSize() -> winsize {
            // Use SwiftTerm's own dimensions — they account for scroller width
            // and actual cell metrics computed from the font.
            // `assumeIsolated` is sound: the only callers are `LocalProcess`'s
            // `startProcess` paths, which TBD invokes from main.
            return MainActor.assumeIsolated {
                let dims = terminalView?.terminalDimensions
                if let dims, dims.cols > 0 && dims.rows > 0 {
                    debugLog("PANEL: getWindowSize \(dims.cols)x\(dims.rows)")
                    return winsize(
                        ws_row: UInt16(dims.rows), ws_col: UInt16(dims.cols),
                        ws_xpixel: 0, ws_ypixel: 0)
                }
                debugLog("PANEL: getWindowSize fallback 80x24")
                return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
            }
        }

        // MARK: - TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Interrupt detection (Ctrl-C / Esc) must keep working in every
            // path, so run it FIRST regardless of where the bytes go next.
            handleOutgoingInput(data)
            switch OutgoingInputRoute.decide(
                controlModeAttached: controlModeAttach != nil, byteCount: data.count) {
            case .localPTY:
                localProcess?.send(data: data)
            case .sidecarInput:
                // Keystrokes ride the sidecar. Pastes NEVER reach here while
                // attached — every paste, any size, is intercepted at the view
                // level and shipped as a `.paste` frame (or refused when
                // oversize) BEFORE SwiftTerm brackets it (see
                // TBDTerminalView.paste + the `onControlModePaste` wiring in
                // startControlModeClient).
                guard let attach = controlModeAttach else { return }
                appState?.daemonClient.fdSidecar.sendInput(
                    worktreeID: attach.worktreeID, paneID: attach.paneID, bytes: Data(data))
            }
        }

        func handleOutgoingInput(_ data: ArraySlice<UInt8>) {
            let isCtrlC = data.contains(0x03)
            // A standalone Escape keypress arrives as a single 0x1b byte. Arrow keys,
            // Alt-combos, and other escape sequences arrive as multi-byte ESC sequences
            // (0x1b 0x5b ...), so requiring count == 1 keeps navigation keys from being
            // mistaken for a halt.
            let isEsc = data.count == 1 && data.first == 0x1b
            guard isCtrlC || isEsc else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState?.handleTerminalInterrupt(terminalID: self.panelID, viaEscape: isEsc)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // SwiftTerm delivers delegate callbacks on the main thread; the
            // resize/debounce state (`resizeDebounceTask`, `resizeSerializer`,
            // `controlModeAttach`) is MainActor-confined like the rest of the
            // coordinator — same guard as `getWindowSize`/`requestOpenLink`.
            MainActor.assumeIsolated {
                // Grouped / local-PTY path (UNCHANGED): propagate resize to the PTY so
                // tmux/shell gets SIGWINCH. In control mode `localProcess` is nil, so
                // this is a no-op there and the daemon-authoritative path below runs.
                if newCols > 0, newRows > 0, let fd = localProcess?.childfd, fd >= 0 {
                    var size = winsize(ws_row: UInt16(newRows), ws_col: UInt16(newCols), ws_xpixel: 0, ws_ypixel: 0)
                    _ = ioctl(fd, TIOCSWINSZ, &size)
                    debugLog("PANEL: resize -> \(newCols)x\(newRows)")
                }
                // Control-mode path (M3.2): the daemon is the sole size authority
                // (addendum §4). Debounced so only the tail of a drag flurry lands.
                scheduleControlModeResize(cols: newCols, rows: newRows)
            }
        }

        /// Debounced `pane.resize` for the control-mode window. No-op unless this
        /// panel is control-mode attached. Cancel-and-replace ~100ms debounce so a
        /// window-drag flurry collapses to one RPC. Errors are dropped: the resize
        /// is re-sent on the next tick and self-heals (the daemon is authoritative).
        ///
        /// Cross-call ordering (R5-M3): cancel-and-replace only stops the
        /// debounce wrapper — an RPC already in flight rides its own socket
        /// task and could be processed AFTER a newer one. `resizeSerializer`
        /// makes delivery latest-wins: at most one RPC in flight; a tick that
        /// fires meanwhile stashes its size, and the in-flight sender drains
        /// the stash on completion (looping until quiescent).
        @MainActor
        private func scheduleControlModeResize(cols: Int, rows: Int) {
            guard let attach = controlModeAttach,
                  ControlModeResizeGate.shouldSend(
                    controlModeAttached: true, cols: cols, rows: rows)
            else { return }
            resizeDebounceTask?.cancel()
            let daemonClient = appState?.daemonClient
            resizeDebounceTask = Task { [weak self] in
                // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                guard var size = self.resizeSerializer.sizeToSend(cols: cols, rows: rows) else {
                    // A send is in flight; the size is stashed and ITS sender
                    // will deliver it — this tick must not race a second RPC.
                    return
                }
                // Deliberately NOT re-checking Task.isCancelled in this loop: a
                // newer tick that cancelled this wrapper has only STASHED its
                // size (see above) — this loop is the sole sender left to
                // deliver it, in order, after the in-flight call completes.
                // TEARDOWN is different (R6-M6): cleanup()'s cancel cannot
                // reach a sender already past the guard above, so every
                // iteration re-checks the torn-down flag BEFORE sending — a
                // dead view must stop draining (its stash is irrelevant; the
                // next live view sends its own initial resize).
                while ControlModeResizeSerializer.shouldContinueDraining(tornDown: self.isTornDown) {
                    try? await daemonClient?.paneResize(
                        worktreeID: attach.worktreeID, windowID: attach.windowID,
                        cols: size.cols, rows: size.rows)
                    guard let next = self.resizeSerializer.completedInFlight() else { return }
                    size = next
                }
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            MainActor.assumeIsolated {
                // Try to resolve as a file path (absolute, file://, or relative to worktree)
                if let tv = source as? TBDTerminalView,
                   let resolved = tv.resolveAsFilePath(link) {
                    logger.debug("file-click[requestOpenLink/file]: \(resolved, privacy: .public) raw=\(link, privacy: .public)")
                    tv.onFilePathClicked?(resolved)
                    return
                }

                // Only open as external URL if it has a real scheme
                if link.contains("://"), let url = URL(string: link) {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        func bell(source: TerminalView) { NSSound.beep() }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    }
}
