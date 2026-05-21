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

    /// Open a logging-only `tmux -CC` connection for `serverName` when the
    /// control-mode gate passes (env opt-in AND tmux ≥ 3.2). Idempotent.
    func enableIfGated(serverName: String) async {
        guard ControlModeGate.shouldEnable(tmuxVersion: tmuxVersion) else { return }
        await supervisor.ensureConnection(serverName: serverName)
    }
}
