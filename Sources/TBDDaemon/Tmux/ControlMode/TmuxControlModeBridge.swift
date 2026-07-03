import Foundation

/// Bundles the per-daemon `TmuxControlSupervisor` with the once-detected tmux
/// version so every `ensureServer()` call site can open a gated control-mode
/// connection through a single shared owner.
///
/// `Daemon` constructs exactly one of these at startup and hands the same
/// value to `WorktreeLifecycle` and `RPCRouter`. When the control-mode gate is
/// off (the default), `enableIfGated(serverName:)` is a no-op, so behavior is
/// unchanged.
struct TmuxControlModeBridge: Sendable {
    /// The single per-daemon supervisor. Connections are keyed by server name
    /// and `ensureConnection` is idempotent, so all call sites share one.
    let supervisor: TmuxControlSupervisor
    /// tmux version detected once at daemon startup; `nil` when detection
    /// failed (tmux missing/unparseable), which keeps the gate closed.
    let tmuxVersion: TmuxVersion?
    /// Environment the gate reads. Injectable so tests can flip the gate.
    let environment: [String: String]
    /// Sidecar over which attach handlers vend pane fds.
    let fdVending: FDVendingServer
    /// How long an attach may sit un-acked before the daemon cancels it
    /// (spec, pane lifecycle: "App fails to send attach.ready within timeout
    /// (e.g. 5 s) → daemon cancels attach"). Injectable for tests.
    let readyTimeout: Duration
    /// Routes app → daemon input frames to `send-keys -H` on the correct
    /// server's FIFO correlator (M2.2). A reference type shared by every copy
    /// of this (value) struct, so the daemon's `setOnInput` sink and the attach
    /// handlers' register/unregister all touch the same router.
    let inputRouter: ControlModeInputRouter
    /// Arbitrates window resizes with echo suppression (M3.1, addendum §4). Like
    /// `inputRouter`, a reference type shared across every copy of this struct,
    /// so the `pane.resize` handler and the supervisor's layout-change filter
    /// touch the same coordinator.
    let resizeCoordinator: ControlModeResizeCoordinator

    init(supervisor: TmuxControlSupervisor,
         tmuxVersion: TmuxVersion?,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         fdVending: FDVendingServer,
         readyTimeout: Duration = .seconds(5),
         inputRouter: ControlModeInputRouter? = nil,
         resizeCoordinator: ControlModeResizeCoordinator? = nil) {
        self.supervisor = supervisor
        self.tmuxVersion = tmuxVersion
        self.environment = environment
        self.fdVending = fdVending
        self.readyTimeout = readyTimeout
        // Default-wire the router to this supervisor's correlators so callers
        // (and tests) that don't care about input get a correctly-wired router
        // for free; the daemon can still inject one it also holds a handle to.
        self.inputRouter = inputRouter
            ?? ControlModeInputRouter(commandProvider: { [supervisor] server in
                await supervisor.command(server: server)
            })
        self.resizeCoordinator = resizeCoordinator
            ?? ControlModeResizeCoordinator(commandProvider: { [supervisor] server in
                await supervisor.command(server: server)
            })
        // Install the echo-suppression filter on the supervisor BEFORE any
        // `ensureConnection` (this init runs at daemon startup, well before the
        // first attach) so the drain loop consults it from the first event. The
        // setter is nonisolated, so this synchronous init can call it directly.
        let coordinator = self.resizeCoordinator
        supervisor.setLayoutChangeFilter { server, windowID in
            coordinator.shouldApplyLayoutChange(server: server, windowID: windowID)
        }
    }

    /// Open a logging-only `tmux -CC` connection for `serverName` when the
    /// control-mode gate passes (env opt-in AND tmux ≥ 3.2). Idempotent.
    func enableIfGated(serverName: String) async {
        guard ControlModeGate.shouldEnable(environment: environment, tmuxVersion: tmuxVersion) else { return }
        await supervisor.ensureConnection(serverName: serverName)
    }
}
