import Foundation

/// Decides whether the tmux control-mode path is active.
///
/// Control mode stays opt-in: it runs only when the
/// `TBD_TMUX_CONTROL_MODE` environment variable is truthy OR the persisted
/// Settings flag (`config.control_mode_enabled`, M5) is on — AND the local
/// tmux supports the control-mode feature set. Otherwise the daemon's
/// existing grouped-sessions path is unaffected.
///
/// Precedence: `gate = (env || flag) && tmux >= 3.2`. The env var is the
/// developer override — a truthy value forces the gate open even when the
/// Settings flag is off; a falsy/absent value simply defers to the flag.
enum ControlModeGate {
    static let environmentKey = "TBD_TMUX_CONTROL_MODE"

    /// Whether the env var opts in. Accepts `1`, `true`, `yes` (case-insensitive).
    static func optedIn(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[environmentKey]?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    /// Final decision: (env opt-in OR persisted flag) AND tmux ≥ the
    /// control-mode minimum. `tmuxVersion` is nil when version detection
    /// failed, which keeps the gate closed.
    static func shouldEnable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        persistedFlag: Bool = false,
        tmuxVersion: TmuxVersion?
    ) -> Bool {
        guard optedIn(environment: environment) || persistedFlag,
              let version = tmuxVersion else { return false }
        return version >= TmuxVersion.controlModeMinimum
    }
}
