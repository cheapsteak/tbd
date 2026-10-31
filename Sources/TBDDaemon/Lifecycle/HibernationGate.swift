import Foundation
import TBDShared

/// Pure decision logic for whether a terminal may be AUTO-hibernated right now.
///
/// Split out from `HibernationCoordinator` so every gating branch — the hard
/// safety rails plus the idle-duration check — is unit-testable without an
/// actor, a tmux server, or a database. The rails themselves (running turn,
/// permission prompt, unknown activity, keep-warm, already-hibernated/
/// suspended, resumable Claude) live on `Terminal.isAutoHibernationEligible()`;
/// this adds the two inputs that pure method can't see: whether the feature
/// is enabled and how long the terminal has been idle relative to the
/// configured timeout.
public enum HibernationGate {
    /// Why a terminal was or wasn't selected for auto-hibernation. `.eligible`
    /// is the only go; every other case names the rail that blocked it, so the
    /// idle-sweep can log a precise reason and tests can assert on the exact
    /// gate.
    public enum Decision: Equatable, Sendable {
        case eligible
        case featureDisabled
        case notClaudeResumable
        case alreadyHibernated
        case suspended
        case keepWarm
        case running            // actively running a turn — never eat an in-flight generation
        case waitingForUser     // a raised permission hand — hibernating would eat it
        case unknownActivity    // no agent report: TBD does not know whether a turn is running
        case notIdleLongEnough  // idle, but not past the timeout yet
    }

    /// Evaluate the auto-hibernate decision for `terminal`.
    ///
    /// - Parameters:
    ///   - terminal: the candidate.
    ///   - autoHibernateEnabled: the global master switch.
    ///   - idleTimeout: how long a terminal must be idle before it qualifies.
    ///   - idleSince: when the terminal last went idle (its `hibernationIdleSince`
    ///     marker). `nil` means "no idle marker yet" — treated as not-yet-idle,
    ///     since we can't prove it has been at rest long enough.
    ///   - now: the reference time (injectable for tests).
    public static func decide(
        terminal: Terminal,
        autoHibernateEnabled: Bool,
        idleTimeout: TimeInterval,
        idleSince: Date?,
        now: Date
    ) -> Decision {
        guard autoHibernateEnabled else { return .featureDisabled }
        // Hard safety rails that don't depend on idle duration (returns the most
        // specific blocker, or nil when all pass).
        if let blocked = blockingRail(terminal: terminal) { return blocked }
        // Idle-duration rail: needs a marker and enough elapsed time.
        guard let idleSince, now.timeIntervalSince(idleSince) >= idleTimeout else {
            return .notIdleLongEnough
        }
        return .eligible
    }

    /// The hard safety rails shared by EVERY park path — the ones that don't
    /// depend on the idle-sweep master switch or the idle-duration window.
    /// Returns the blocking `Decision` (the most specific blocker) or `nil` when
    /// all rails pass.
    ///
    /// Ordered so the returned reason is the most specific blocker; callers rely
    /// on this exact precedence (e.g. an already-hibernated running terminal
    /// reports `.alreadyHibernated`, not `.running`). Kept identical to the cascade
    /// that used to be inlined in `decide` so existing behavior is preserved.
    ///
    /// `.unknown` activity blocks, last: the agent has not reported its
    /// state, so TBD cannot tell a finished turn from a running one, and a
    /// park could end a turn in flight. Only a reported `.idle` parks.
    ///
    /// Transport does not appear here. Park and wake exist on every transport,
    /// so a holder-backed row passes or fails these rails on exactly the facts
    /// a tmux-backed one does. Mirrors `Terminal.isAutoHibernationEligible`,
    /// which this cascade deliberately re-implements rather than calls (it
    /// needs per-rail reasons). A manual park (`isManuallyHibernatable`) skips
    /// the keep-warm and unknown-activity rails and keeps the rest.
    static func blockingRail(terminal: Terminal) -> Decision? {
        guard terminal.isClaudeResumable else { return .notClaudeResumable }
        guard terminal.hibernatedAt == nil else { return .alreadyHibernated }
        guard terminal.suspendedAt == nil else { return .suspended }
        guard !terminal.keepWarm else { return .keepWarm }
        switch terminal.activityState {
        case .working:
            return .running
        case .waitingForUser:
            return .waitingForUser
        case .unknown:
            return .unknownActivity
        case .idle:
            return nil
        }
    }

    /// The park decision for a MERGE-triggered hibernate (PR merged →
    /// auto-park the worktree's idle sessions).
    ///
    /// Deliberately consults NEITHER the idle-sweep master switch NOR the
    /// idle-duration window — and this is the single most likely thing a future
    /// reader gets wrong, so it is spelled out:
    ///
    ///  - No master switch: `config.autoHibernateEnabled` is the *idle sweep's*
    ///    on/off. Merge-park is an independent feature armed by the per-worktree
    ///    tri-state + `config.autoHibernateOnMergeDefault`, so gating it on the
    ///    idle sweep's switch would wrongly couple the two.
    ///  - No idle window: the trigger is the merge event, not "has been at rest
    ///    for N minutes". A session that just went idle when its PR merged is a
    ///    valid park target.
    ///
    /// It still honors every hard safety rail via `blockingRail` — including
    /// keep-warm, unlike `manualHibernate` — because this is system-initiated,
    /// not an explicit user request. An unsent draft in the composer is the
    /// session mod's to guard, not this gate's: see `ComposerDraftParkGate`.
    public static func decideForMerge(terminal: Terminal) -> Decision {
        blockingRail(terminal: terminal) ?? .eligible
    }
}
