import Foundation
import TBDShared

/// What a provider's session list currently IS — five readings that used to
/// collapse into two empty-state strings.
///
/// The distinction that motivates the type: **"this provider reports no
/// sessions" and "TBD has no inventory to show" are different facts**, and
/// only the first is evidence about the backend. A registered-but-never-
/// polled provider, a provider whose freshness record the daemon couldn't
/// read, a provider whose last good inventory is going stale, and a provider
/// that successfully reported nothing all produced roughly the same reassuring
/// blank page — under a green badge, since none of them is unhealthy.
///
/// Pure and view-free: every sentence the desk renders is asserted here.
enum RemoteProviderInventoryState: Equatable {
    /// A successful inventory with rows in it.
    case populated(count: Int, at: Date?)
    /// A successful inventory that reported nothing. The only one of these
    /// five that is evidence the backend really has no sessions.
    case emptySuccess(at: Date?)
    /// No successful inventory has ever been accepted for this provider.
    case noInventoryYet
    /// The daemon could not read the freshness record, so it cannot say
    /// whether anything on screen is current — distinct from never having
    /// snapshotted, because here TBD doesn't even know which of the two it is.
    case freshnessUnknown
    /// A prior good inventory that is no longer being refreshed. Rows may
    /// still be on screen; they are history, not current state.
    case stale(since: Date?, cachedCount: Int)

    /// `sessionCount` is the number of mirror rows the desk is about to
    /// render for this provider — the caller's own filtered count, so this
    /// type never re-derives (and never disagrees with) what is on screen.
    static func make(provider: RemoteProviderStatus, sessionCount: Int) -> RemoteProviderInventoryState {
        if provider.hasStaleSnapshot {
            // `hasStaleSnapshot` is true for an unreadable freshness row even
            // with no known snapshot; say what is actually unknown rather
            // than quoting an age TBD doesn't have.
            if provider.lastSuccessfulSnapshotAt == nil { return .freshnessUnknown }
            return .stale(since: provider.lastSuccessfulSnapshotAt, cachedCount: sessionCount)
        }
        guard let at = provider.lastSuccessfulSnapshotAt else {
            return provider.freshnessUnreadable ? .freshnessUnknown : .noInventoryYet
        }
        return sessionCount == 0 ? .emptySuccess(at: at) : .populated(count: sessionCount, at: at)
    }

    /// The headline a reader sees in place of (or above) the session list.
    var title: String {
        switch self {
        case .populated: return "Inventory current"
        case .emptySuccess: return "This provider reports no sessions"
        case .noInventoryYet: return "No inventory yet"
        case .freshnessUnknown: return "Inventory freshness unknown"
        case .stale: return "Showing the last good inventory"
        }
    }

    /// The sentence under the headline. `now` is injected so the age it
    /// quotes is deterministic in a test.
    func detail(now: Date = Date()) -> String {
        switch self {
        case .populated(let count, let at):
            let rows = count == 1 ? "1 session" : "\(count) sessions"
            guard let at else { return "\(rows) reported." }
            return "\(rows) reported \(RemoteProviderDeskSummary.agePhrase(since: at, now: now))."
        case .emptySuccess(let at):
            let base = "The provider answered and its inventory was empty"
            guard let at else { return base + "." }
            return base + " \(RemoteProviderDeskSummary.agePhrase(since: at, now: now))."
        case .noInventoryYet:
            return "TBD has not yet accepted a complete inventory from this provider, "
                + "so an empty list here is not evidence that the provider has no sessions."
        case .freshnessUnknown:
            return "TBD could not read this provider's freshness record, so it cannot say whether "
                + "anything shown here is current."
        case .stale(let since, let cachedCount):
            let rows = cachedCount == 1 ? "1 cached row" : "\(cachedCount) cached rows"
            guard let since else {
                return "\(rows) from an earlier inventory. Their states are history, not current."
            }
            return "\(rows) from the inventory of "
                + "\(RemoteProviderDeskSummary.agePhrase(since: since, now: now)). "
                + "Their states are history, not current."
        }
    }

    /// Whether what the user is looking at may be presented as current.
    var isCurrent: Bool {
        switch self {
        case .populated, .emptySuccess: return true
        case .noInventoryYet, .freshnessUnknown, .stale: return false
        }
    }

    /// Whether the desk should say anything at all beyond the list — a
    /// populated, current inventory speaks for itself.
    var warrantsNotice: Bool {
        switch self {
        case .populated: return false
        case .emptySuccess, .noInventoryYet, .freshnessUnknown, .stale: return true
        }
    }

    /// "3 sessions are registered under other providers (agentbox-staging: 3)."
    ///
    /// The direct answer to "did I just inspect the wrong provider" — stated
    /// by TBD at the moment the question arises, rather than left to a user
    /// to reconstruct by clicking every other header. Nil when no other
    /// provider holds anything, which is the common case and would otherwise
    /// be noise.
    ///
    /// Counts the same rows the desk counts: not dismissed, and keyed on the
    /// registry name, so two entries of the same KIND are two different
    /// providers here exactly as they are everywhere else.
    static func crossProviderNote(
        currentProvider: String,
        sessions: [RemoteSessionInfo]
    ) -> String? {
        var counts: [String: Int] = [:]
        for session in sessions where !session.dismissed && session.provider != currentProvider {
            counts[session.provider, default: 0] += 1
        }
        guard !counts.isEmpty else { return nil }
        let total = counts.values.reduce(0, +)
        let breakdown = counts.keys.sorted().map { "\($0): \(counts[$0] ?? 0)" }.joined(separator: ", ")
        let noun = total == 1 ? "session is" : "sessions are"
        let where_ = counts.count == 1 ? "another provider" : "other providers"
        return "\(total) \(noun) registered under \(where_) (\(breakdown))."
    }
}
