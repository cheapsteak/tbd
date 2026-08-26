import Foundation

/// Parses the ISO-8601 timestamps the provider contract puts on the Session
/// object (`created_at`, `agent_state_at`).
///
/// Both spellings a conforming provider may emit are accepted: with and
/// without fractional seconds. A default-options `ISO8601DateFormatter`
/// rejects the fractional form outright, which is the kind of silent,
/// provider-specific loss that makes a timestamp field useless for anything
/// but display.
public enum RemoteTimestamp {
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The instant `value` names, or nil when it is absent or unparseable.
    /// Never throws and never guesses: an unparseable stamp is treated as no
    /// stamp at all, so a provider with a malformed timestamp loses ordering
    /// information rather than gaining a wrong instant.
    public static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return fractional.date(from: value) ?? plain.date(from: value)
    }
}

/// Whether a sighting of a session is fresh enough to overwrite what the
/// mirror already holds.
///
/// The mirror is fed from two independent channels — the periodic `list`
/// poll and the `events` stream — plus one-off verb responses, and nothing
/// serializes them against each other. A `list` response that spent four
/// seconds in flight can therefore land *after* an `events` line that
/// observed the same session later, and last-writer-wins then reinstates the
/// older state. For the agent axis that is not a cosmetic problem: it
/// restores a `waiting_input` a human already dealt with, and the sidebar
/// puts the attention hand back on a session that has been working for
/// minutes.
///
/// The contract already carries the fact needed to detect this —
/// `agent_state_at`, the instant the agent state was determined — and TBD
/// never read it. This is where it gets read.
public enum RemoteSnapshotOrdering {
    public enum Decision: Equatable {
        /// Take the sighting as the session's current state.
        case apply
        /// The sighting is demonstrably older than what the mirror holds.
        /// It is still evidence the session EXISTS — presence bookkeeping
        /// (last-seen, absence counting, `gone`) must be refreshed from it —
        /// but its state must not overwrite newer state.
        case presenceOnly
    }

    /// The decision for one session.
    ///
    /// Deliberately conservative, in three ways, because the cost of wrongly
    /// rejecting a sighting (a row frozen at a state the provider has moved
    /// on from) is worse than the cost of wrongly accepting one (the
    /// pre-existing behavior):
    ///
    /// - **No stamp on either side means apply.** `agent_state_at` is
    ///   optional, and most providers will never send it. Absent ordering
    ///   information, last-writer-wins is exactly what TBD did before, and
    ///   this function must not change behavior for those providers at all.
    /// - **Equal stamps apply.** A provider stamping at second granularity
    ///   would otherwise have every update after the first within the same
    ///   second dropped, and re-applying an identical state is harmless.
    /// - **A future-dated stored stamp disables the check.** A provider
    ///   whose clock ran ahead (or that stamped a state it had not yet
    ///   observed) would otherwise make every subsequent sighting "older"
    ///   forever, freezing the row permanently — the one failure mode worse
    ///   than the bug being fixed. `tolerance` allows for ordinary skew
    ///   between the provider's clock and this machine's.
    public static func decide(
        incomingAgentStateAt: String?,
        storedAgentStateAt: String?,
        now: Date,
        tolerance: TimeInterval = 60
    ) -> Decision {
        guard let stored = RemoteTimestamp.parse(storedAgentStateAt),
              let incoming = RemoteTimestamp.parse(incomingAgentStateAt) else {
            return .apply
        }
        guard stored <= now.addingTimeInterval(tolerance) else { return .apply }
        return incoming < stored ? .presenceOnly : .apply
    }
}
