import Foundation

/// The rule that a watch mode (`nightwatchMode` other than `.off`) and the
/// pty-holder transport are never both on. Nightwatch is deprecated: the
/// fleet-supervision redesign replaces it, and it is not ported to the holder
/// (cheapsteak/tbd#907 records the deferred port). On the holder its desk
/// liveness check reads an empty tmux window id and leaks one Claude session
/// per tick, so the combination is made unreachable rather than tolerated.
///
/// "Holder on" is always the EFFECTIVE `Config.ptyHolderEnabled` — the column
/// resolved through `Config.ptyHolderDefault` — so the rule reaches installs
/// that never touched the toggle when the default graduates.
///
/// Spec: docs/specs/2026-09-22-nightwatch-deprecation-holder-gate-design.md
public enum NightwatchHolderGate {
    /// Why `nightwatch.setMode` refuses a watch mode while the holder is on.
    /// Shared by the RPC error, the boot-reconcile log and notification, the
    /// app's disabled-control tooltip, and the CLI.
    public static let modeRefusal = """
        Nightwatch is deprecated and does not run with the pty-holder transport \
        (pty_holder_enabled, Settings → "Run new sessions without tmux"). It is \
        being replaced by fleet supervision. To keep using it on tmux, turn the \
        pty-holder transport off first.
        """

    /// Why `config.setPtyHolderEnabled` refuses `true` while a watch mode is active.
    public static let holderRefusal = """
        The pty-holder transport cannot be turned on while Nightwatch or \
        Daywatch is active: Nightwatch is deprecated and does not run with the \
        pty-holder transport. Turn Nightwatch off first.
        """

    /// The standing deprecation sentence for Settings help and `tbd nightwatch status`.
    public static let deprecationNotice = """
        Nightwatch and Daywatch are deprecated and being replaced by fleet \
        supervision, and do not run with the pty-holder transport.
        """

    /// `.off` is never refused.
    public static func refusesMode(_ requested: NightwatchMode, holderEnabled: Bool) -> Bool {
        requested != .off && holderEnabled
    }

    /// Turning the holder off is never refused.
    public static func refusesHolder(enabling: Bool, currentMode: NightwatchMode) -> Bool {
        enabling && currentMode != .off
    }

    /// True only for an install that combined the two on a daemon older than
    /// the gate; the refusals mean the state can never be re-entered.
    public static func bootMustTurnModeOff(_ config: Config) -> Bool {
        config.nightwatchMode != .off && config.ptyHolderEnabled
    }
}
