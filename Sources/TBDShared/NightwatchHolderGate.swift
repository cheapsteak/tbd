import Foundation

/// The rule that a watch mode (`nightwatchMode` other than `.off`) and the
/// pty-holder transport are never both on. Nightwatch is deprecated: the
/// fleet-supervision redesign replaces it, and it is not ported to the holder
/// (cheapsteak/tbd#907 records the deferred port). On the holder its desk
/// liveness check reads an empty tmux window id and leaks one Claude session
/// per tick, so the combination is made unreachable rather than tolerated.
///
/// **The hazard, not the flag, is what gets refused.** A watch mode is blocked
/// when a holder-backed session can actually come into existence: the EFFECTIVE
/// `Config.ptyHolderEnabled` — the column resolved through
/// `Config.ptyHolderDefault`, so the rule reaches installs that never touched
/// the toggle, which the graduated default makes the ordinary case — *and* this
/// daemon's ability to start a holder at all (`HolderRegistry.canSpawn`, the
/// `TBDHolder` helper beside the daemon binary). Without the helper every spawn
/// falls back to tmux, so no holder session can exist and there is nothing to
/// refuse; a gate that fired there would take Nightwatch away from an install
/// that can still run it, and name as the remedy a transport change that would
/// have no effect.
///
/// `watchModesBlocked` composes the two terms once, and both deciders read it,
/// so no surface can accidentally ask only half the question.
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

    /// Whether the pty-holder hazard is live on this daemon: the flag is on
    /// *and* a holder can actually be started. Composed once here; the two
    /// deciders below take the answer rather than the parts.
    public static func watchModesBlocked(holderEnabled: Bool, holderSupported: Bool) -> Bool {
        holderEnabled && holderSupported
    }

    /// `.off` is never refused. `whileBlocked` is `watchModesBlocked(...)`,
    /// computed by whichever surface holds the flag/supported pair — the
    /// daemon from its own registry, the app from `daemon.capabilities`.
    public static func refusesMode(_ requested: NightwatchMode, whileBlocked: Bool) -> Bool {
        requested != .off && whileBlocked
    }

    /// Turning the holder off is never refused.
    ///
    /// **No `holderSupported` term, deliberately.** This guards a gesture that
    /// would deliberately persist the forbidden pair, and the written `1`
    /// outlives this daemon's inability to find the helper — an upgrade or a
    /// reinstall restores it, and the pair would then be live. The refusal
    /// stays, and it is actionable: turn the watch mode off first.
    public static func refusesHolder(enabling: Bool, currentMode: NightwatchMode) -> Bool {
        enabling && currentMode != .off
    }

    /// True for an install carrying a watch mode while the hazard is live —
    /// one that combined the two on a daemon older than the gate, or one that
    /// left a watch mode on and never touched the holder toggle, whose
    /// effective flag reads on through the shipped default. The refusals mean
    /// the pair can never be deliberately re-entered, and the reconcile's own
    /// write means a later boot reads `.off`.
    public static func bootMustTurnModeOff(_ config: Config, holderSupported: Bool) -> Bool {
        config.nightwatchMode != .off
            && watchModesBlocked(
                holderEnabled: config.ptyHolderEnabled, holderSupported: holderSupported)
    }
}
