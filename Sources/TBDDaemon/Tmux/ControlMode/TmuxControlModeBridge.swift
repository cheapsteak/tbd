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

    init(supervisor: TmuxControlSupervisor,
         tmuxVersion: TmuxVersion?,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         fdVending: FDVendingServer,
         readyTimeout: Duration = .seconds(5)) {
        self.supervisor = supervisor
        self.tmuxVersion = tmuxVersion
        self.environment = environment
        self.fdVending = fdVending
        self.readyTimeout = readyTimeout
    }

    /// Open a logging-only `tmux -CC` connection for `serverName` when the
    /// control-mode gate passes (env opt-in AND tmux ≥ 3.2). Idempotent.
    func enableIfGated(serverName: String) async {
        guard ControlModeGate.shouldEnable(environment: environment, tmuxVersion: tmuxVersion) else { return }
        await supervisor.ensureConnection(serverName: serverName)
    }
}
