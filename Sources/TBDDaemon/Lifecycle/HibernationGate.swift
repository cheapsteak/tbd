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
        // Rails that don't depend on idle duration, ordered so the returned
        // reason is the most specific blocker.
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
            break
        }
        // Idle-duration rail: needs a marker and enough elapsed time.
        guard let idleSince, now.timeIntervalSince(idleSince) >= idleTimeout else {
            return .notIdleLongEnough
        }
        return .eligible
    }
}
