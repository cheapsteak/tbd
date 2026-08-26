import Foundation
import Testing
@testable import TBDShared

@Suite("Remote snapshot ordering")
struct RemoteSnapshotOrderingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Timestamp parsing

    @Test("both ISO-8601 spellings a conforming provider may emit are read")
    func parsesBothSpellings() {
        let plain = RemoteTimestamp.parse("2026-08-26T07:14:00Z")
        let fractional = RemoteTimestamp.parse("2026-08-26T07:14:00.250Z")

        #expect(plain != nil)
        #expect(fractional != nil)
        // A default-options ISO8601DateFormatter rejects the fractional form
        // outright; reading it as absent would silently disable ordering for
        // every provider that emits it.
        #expect(fractional.map { $0.timeIntervalSince(plain ?? $0) } == 0.25)
    }

    @Test("an absent or unparseable stamp is no stamp, never a guessed instant")
    func parsesNothingIntoNothing() {
        #expect(RemoteTimestamp.parse(nil) == nil)
        #expect(RemoteTimestamp.parse("") == nil)
        #expect(RemoteTimestamp.parse("yesterday") == nil)
        #expect(RemoteTimestamp.parse("2026-08-26 07:14:00") == nil)
    }

    // MARK: - The decision

    @Test("a sighting older than the mirrored state is presence-only")
    func rejectsAnOlderSighting() {
        #expect(RemoteSnapshotOrdering.decide(
            incomingAgentStateAt: "2026-08-26T07:10:00Z",
            storedAgentStateAt: "2026-08-26T07:14:00Z",
            now: now) == .presenceOnly)
    }

    @Test("a newer sighting applies")
    func acceptsANewerSighting() {
        #expect(RemoteSnapshotOrdering.decide(
            incomingAgentStateAt: "2026-08-26T07:14:00Z",
            storedAgentStateAt: "2026-08-26T07:10:00Z",
            now: now) == .apply)
    }

    @Test("an equal stamp applies")
    func acceptsAnEqualStamp() {
        // A provider stamping at second granularity would otherwise have
        // every update after the first within the same second dropped, and
        // re-applying an identical state costs nothing.
        #expect(RemoteSnapshotOrdering.decide(
            incomingAgentStateAt: "2026-08-26T07:14:00Z",
            storedAgentStateAt: "2026-08-26T07:14:00Z",
            now: now) == .apply)
    }

    @Test("no ordering information means the previous behavior, unchanged")
    func appliesWithoutStamps() {
        // `agent_state_at` is optional and most providers will never send it.
        // This check must not change anything for them.
        #expect(RemoteSnapshotOrdering.decide(
            incomingAgentStateAt: nil, storedAgentStateAt: nil, now: now) == .apply)
        #expect(RemoteSnapshotOrdering.decide(
            incomingAgentStateAt: nil,
            storedAgentStateAt: "2026-08-26T07:14:00Z", now: now) == .apply)
        #expect(RemoteSnapshotOrdering.decide(
            incomingAgentStateAt: "2026-08-26T07:10:00Z",
            storedAgentStateAt: nil, now: now) == .apply)
        #expect(RemoteSnapshotOrdering.decide(
            incomingAgentStateAt: "2026-08-26T07:10:00Z",
            storedAgentStateAt: "not a date", now: now) == .apply)
    }

    @Test("a future-dated mirrored stamp disables the check rather than freezing the row")
    func futureStoredStampFailsOpen() {
        let stored = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
        let incoming = ISO8601DateFormatter().string(from: now)

        // Worse than the bug being fixed: a provider whose clock ran ahead
        // would make every later sighting "older" forever, freezing the row
        // at a state nothing could ever replace.
        #expect(RemoteSnapshotOrdering.decide(
            incomingAgentStateAt: incoming, storedAgentStateAt: stored, now: now) == .apply)
    }

    @Test("ordinary clock skew stays inside the tolerance and still orders")
    func toleratesSmallSkew() {
        let stored = ISO8601DateFormatter().string(from: now.addingTimeInterval(30))
        let incoming = ISO8601DateFormatter().string(from: now.addingTimeInterval(10))

        // 30s ahead is skew, not a broken clock: the check still applies, so
        // the older sighting is still rejected.
        #expect(RemoteSnapshotOrdering.decide(
            incomingAgentStateAt: incoming, storedAgentStateAt: stored, now: now) == .presenceOnly)
    }
}
