import Foundation

/// Decides whether the tmux control-mode path is active.
///
/// Phase 1 keeps control mode opt-in: it runs only when the
/// `TBD_TMUX_CONTROL_MODE` environment variable is truthy AND the local tmux
/// supports the control-mode feature set. Otherwise the daemon's existing
/// grouped-sessions path is unaffected.
enum ControlModeGate {
    static let environmentKey = "TBD_TMUX_CONTROL_MODE"

    /// Whether the env var opts in. Accepts `1`, `true`, `yes` (case-insensitive).
    static func optedIn(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[environmentKey]?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    /// Final decision: opted in AND tmux ≥ the control-mode minimum.
    /// `tmuxVersion` is nil when version detection failed.
    static func shouldEnable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tmuxVersion: TmuxVersion?
    ) -> Bool {
        guard optedIn(environment: environment), let version = tmuxVersion else { return false }
        return version >= TmuxVersion.controlModeMinimum
    }
}
