import Foundation
import TBDShared

/// Pure decision logic for whether a terminal may be AUTO-hibernated right now.
///
/// Split out from `HibernationCoordinator` so every gating branch — the hard
/// safety rails plus the idle-duration check — is unit-testable without an
/// actor, a tmux server, or a database. The rails themselves (running turn,
/// permission prompt, keep-warm, already-hibernated/suspended, resumable
/// Claude) live on `Terminal.isAutoHibernationEligible`; this adds the two
/// inputs that pure property can't see: whether the feature is enabled and how
/// long the terminal has been idle relative to the configured timeout.
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
        case notIdleLongEnough  // idle, but not past the timeout yet
        case pendingTypedInput  // idle, but input arrived after it went to rest
    }

    /// Evaluate the auto-hibernate decision for `terminal`.
    ///
    /// - Parameters:
    ///   - terminal: the candidate.
    ///   - autoHibernateEnabled: the global master switch.
    ///   - inputVetoEnabled: soak flag for the input-pipeline pending-input veto.
    ///   - idleTimeout: how long a terminal must be idle before it qualifies.
    ///   - idleSince: when the terminal last went idle (its `hibernationIdleSince`
    ///     marker). `nil` means "no idle marker yet" — treated as not-yet-idle,
    ///     since we can't prove it has been at rest long enough.
    ///   - lastInputAt: the timestamp of the last keystroke/paste routed to this
    ///     terminal's pane (from InputActivityTracker). `nil` means "no input
    ///     recorded" (e.g. post-restart, or a pane never typed into).
    ///   - now: the reference time (injectable for tests).
    public static func decide(
        terminal: Terminal,
        autoHibernateEnabled: Bool,
        inputVetoEnabled: Bool = false,
        idleTimeout: TimeInterval,
        idleSince: Date?,
        lastInputAt: Date? = nil,
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
        // Input veto: if the soak flag is on and input arrived at or after the
        // session went idle, block the park — pending typed input should not be eaten.
        if inputVetoEnabled, let lastInputAt, lastInputAt >= idleSince {
            return .pendingTypedInput
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
        case .idle, .unknown:
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
    /// not an explicit user request.
    public static func decideForMerge(terminal: Terminal) -> Decision {
        blockingRail(terminal: terminal) ?? .eligible
    }
}
