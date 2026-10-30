import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Builders shared by the matched-session tests. `info` takes only the fields
/// those tests vary; everything else takes a fixed, unremarkable value.
enum MatchedSessionFixtures {
    static func info(
        _ id: String,
        provider: String = "acme",
        createdAt: String? = nil,
        archived: Bool = false,
        dismissed: Bool = false,
        repo: UUID?,
        state: RemoteProcessState = .running,
        agent: RemoteAgentState = .idle,
        gone: Bool = false,
        lastSeen: Date = Date(timeIntervalSince1970: 0),
        pinnedAt: Date? = nil
    ) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(
                id: id, createdAt: createdAt, state: state, agentState: agent, archived: archived),
            gone: gone, dismissed: dismissed, lastSeen: lastSeen,
            resolvedRepoID: repo, pinnedAt: pinnedAt)
    }
}

/// A fixed-seed generator, so the corpus is the same on every run and every
/// machine. SplitMix64: small, and well-distributed enough for shuffling.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("RepoSectionView — matched sessions: order, parse-once")
struct RepoSectionMatchedSessionsTests {
    static let repoID = UUID()

    /// About 800 sessions for one repo, drawn from every timestamp shape the
    /// sort has to handle, plus noise the filter has to drop. Timestamps come
    /// from small pools so that duplicate stamps (ties) are common.
    static func corpus() -> (all: [RemoteSessionInfo], adopted: [Worktree]) {
        var rng = SplitMix64(state: 0x5EED_C0FF_EE01)
        var all: [RemoteSessionInfo] = []
        var adopted: [Worktree] = []

        for i in 0..<800 {
            let id = "s\(i)"
            let createdAt = stamp(&rng)
            let dismissed = rng.next() % 20 == 0
            let archived = rng.next() % 20 == 0
            all.append(MatchedSessionFixtures.info(
                id, createdAt: createdAt, archived: archived, dismissed: dismissed, repo: repoID))
            if i < 40 {
                adopted.append(SidebarGroupFixtures.row("lane-\(i)", repoID: repoID, remote: id))
            }
        }

        // Noise the filter must drop: sessions resolved to another repo or to
        // no repo at all, with the same timestamp shapes.
        for i in 0..<100 {
            let other: UUID? = i % 2 == 0 ? UUID() : nil
            all.append(MatchedSessionFixtures.info(
                "n\(i)", createdAt: stamp(&rng), repo: other))
        }
        return (all, adopted)
    }

    /// One `created_at` value, drawn from the shapes a provider may send.
    private static func stamp(_ rng: inout SplitMix64) -> String? {
        let kind = rng.next() % 12
        let slot = Int(rng.next() % 30)
        switch kind {
        case 0...4:
            // Whole seconds, from a 30-value pool, so duplicates tie.
            return String(format: "2026-03-01T10:%02d:%02dZ", slot / 6, (slot % 6) * 10)
        case 5...7:
            // Fractional seconds, from the same pool with a few millisecond values.
            let millis = [0, 250, 500, 999][Int(rng.next() % 4)]
            return String(format: "2026-03-01T10:%02d:%02d.%03dZ", slot / 6, (slot % 6) * 10, millis)
        case 8: return nil
        case 9: return ""
        case 10: return "not-a-date"
        default: return "2026-13-45T99:99:99Z"
        }
    }

    /// The pre-fix algorithm, kept here as the reference: filter, then a
    /// `sorted(by:)` whose comparator parses both sides on every comparison.
    static func referenceIDs(
        _ all: [RemoteSessionInfo], repoID: UUID, adopted: Set<WorktreeLocation>
    ) -> [UUID] {
        all
            .filter { $0.resolvedRepoID == repoID && !$0.dismissed && !$0.payload.isArchived }
            .filter { !adopted.contains(.remote(provider: $0.provider, sessionID: $0.payload.id)) }
            .sorted { a, b in
                let da = RemoteTimestamp.parse(a.payload.createdAt)
                let db = RemoteTimestamp.parse(b.payload.createdAt)
                switch (da, db) {
                case let (x?, y?) where x != y: return x < y
                case (nil, .some): return false
                case (.some, nil): return true
                default: return a.id.uuidString < b.id.uuidString
                }
            }
            .map(\.id)
    }

    @Test func sortOrderMatchesThePreFixAlgorithm() {
        let (all, adopted) = Self.corpus()
        let expected = Self.referenceIDs(
            all, repoID: Self.repoID, adopted: RepoSectionView.adoptedLocations(adopted))
        let actual = RepoSectionView.matchedRemoteSessions(
            all, repoID: Self.repoID, worktrees: adopted).map(\.id)
        #expect(actual == expected)
        #expect(expected.count > 500, "the corpus should leave most of the 800 sessions in play")
    }

    @Test func shuffledInputGivesTheSameOrder() {
        let (all, adopted) = Self.corpus()
        var rng = SplitMix64(state: 0xABCD_1234)
        let shuffled = all.shuffled(using: &rng)
        let forward = RepoSectionView.matchedRemoteSessions(
            all, repoID: Self.repoID, worktrees: adopted).map(\.id)
        let backward = RepoSectionView.matchedRemoteSessions(
            shuffled, repoID: Self.repoID, worktrees: adopted).map(\.id)
        #expect(forward == backward)
    }

    @Test func parsesEachSurvivingSessionExactlyOnce() {
        let (all, adopted) = Self.corpus()
        let survivors = Self.referenceIDs(
            all, repoID: Self.repoID, adopted: RepoSectionView.adoptedLocations(adopted)).count
        var parseCalls = 0
        let indices = RepoSectionView.matchedRemoteSessionIndices(
            all, repoID: Self.repoID, adopted: RepoSectionView.adoptedLocations(adopted),
            parse: { raw in
                parseCalls += 1
                return RemoteTimestamp.parse(raw)
            })
        #expect(indices.count == survivors)
        // Exact, not merely at least: a parse for a filtered-out session would
        // push this above the survivor count.
        #expect(parseCalls == survivors)
    }

    @Test func sameMatchInputsPinsExactlyTheFilterAndSortFields() {
        let repo = Self.repoID
        let base = MatchedSessionFixtures.info("s", createdAt: "2026-03-01T10:00:00Z", repo: repo)

        // Each field the filter or the sort reads must flip the answer.
        #expect(!RepoSectionView.sameMatchInputs(base, MatchedSessionFixtures.info(
            "s", provider: "other", createdAt: "2026-03-01T10:00:00Z", repo: repo)))
        #expect(!RepoSectionView.sameMatchInputs(base, MatchedSessionFixtures.info(
            "t", createdAt: "2026-03-01T10:00:00Z", repo: repo)))
        #expect(!RepoSectionView.sameMatchInputs(base, MatchedSessionFixtures.info(
            "s", createdAt: "2026-03-02T10:00:00Z", repo: repo)))
        #expect(!RepoSectionView.sameMatchInputs(base, MatchedSessionFixtures.info(
            "s", createdAt: "2026-03-01T10:00:00Z", archived: true, repo: repo)))
        #expect(!RepoSectionView.sameMatchInputs(base, MatchedSessionFixtures.info(
            "s", createdAt: "2026-03-01T10:00:00Z", dismissed: true, repo: repo)))
        #expect(!RepoSectionView.sameMatchInputs(base, MatchedSessionFixtures.info(
            "s", createdAt: "2026-03-01T10:00:00Z", repo: UUID())))

        // Fields that change on every sighting or drive row state must not.
        #expect(RepoSectionView.sameMatchInputs(base, MatchedSessionFixtures.info(
            "s", createdAt: "2026-03-01T10:00:00Z", repo: repo,
            lastSeen: Date(timeIntervalSince1970: 9_999))))
        #expect(RepoSectionView.sameMatchInputs(base, MatchedSessionFixtures.info(
            "s", createdAt: "2026-03-01T10:00:00Z", repo: repo, gone: true)))
        #expect(RepoSectionView.sameMatchInputs(base, MatchedSessionFixtures.info(
            "s", createdAt: "2026-03-01T10:00:00Z", repo: repo, state: .exited)))
        #expect(RepoSectionView.sameMatchInputs(base, MatchedSessionFixtures.info(
            "s", createdAt: "2026-03-01T10:00:00Z", repo: repo, agent: .waitingInput)))
        #expect(RepoSectionView.sameMatchInputs(base, MatchedSessionFixtures.info(
            "s", createdAt: "2026-03-01T10:00:00Z", repo: repo,
            pinnedAt: Date(timeIntervalSince1970: 500))))
    }
}
