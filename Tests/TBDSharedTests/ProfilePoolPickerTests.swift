import Foundation
import Testing

@testable import TBDShared

// MARK: - Test Fixtures and Helpers

/// Helper to create usage snapshots with minimal configuration.
private func makeSnapshot(
    buckets: [ClaudeUsageLimitBucket] = [],
    fetchedAt: Date? = Date(),
    lastAttemptAt: Date = Date(),
    status: String = "ok",
    statusKind: ProfileUsageStatusKind = .ok,
    organizationID: String? = nil
) -> ProfileUsageSnapshot {
    ProfileUsageSnapshot(
        buckets: buckets,
        fetchedAt: fetchedAt,
        lastAttemptAt: lastAttemptAt,
        status: status,
        statusKind: statusKind,
        organizationID: organizationID
    )
}

/// Helper to create usage buckets.
private func makeBucket(
    kind: String,
    percent: Double,
    isActive: Bool? = nil
) -> ClaudeUsageLimitBucket {
    ClaudeUsageLimitBucket(
        kind: kind,
        percent: percent,
        isActive: isActive
    )
}

/// Helper to create a candidate with sensible defaults.
private func makeCandidate(
    profileID: UUID = UUID(),
    kind: CredentialKind = .oauth,
    hasCredential: Bool = true,
    poolOptOut: Bool = false,
    accountKey: String = "account1",
    snapshot: ProfileUsageSnapshot? = nil,
    liveSessions: Int = 0,
    sortOrder: Int = 0,
    isConfiguredDefault: Bool = false
) -> ProfilePoolCandidate {
    ProfilePoolCandidate(
        profileID: profileID,
        kind: kind,
        hasCredential: hasCredential,
        poolOptOut: poolOptOut,
        accountKey: accountKey,
        snapshot: snapshot,
        liveSessions: liveSessions,
        sortOrder: sortOrder,
        isConfiguredDefault: isConfiguredDefault
    )
}

// MARK: - Tests

struct ProfilePoolPickerTests {

    // MARK: Eligibility Rules

    @Test("wrongKind: apiKey profile rejected")
    func wrongKindApiKey() {
        let candidate = makeCandidate(kind: .apiKey, snapshot: makeSnapshot())
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: Date())

        #expect(decision.chosen == nil)
        #expect(decision.verdicts[candidate.profileID] == .wrongKind)
    }

    @Test("wrongKind: bedrock profile rejected")
    func wrongKindBedrock() {
        let candidate = makeCandidate(kind: .bedrock, snapshot: makeSnapshot())
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: Date())

        #expect(decision.chosen == nil)
        #expect(decision.verdicts[candidate.profileID] == .wrongKind)
    }

    @Test("noCredential: oauth without credential rejected")
    func noCredentialOAuth() {
        let candidate = makeCandidate(kind: .oauth, hasCredential: false, snapshot: makeSnapshot())
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: Date())

        #expect(decision.chosen == nil)
        #expect(decision.verdicts[candidate.profileID] == .noCredential)
    }

    @Test("noCredential: oauthToken without credential rejected")
    func noCredentialOAuthToken() {
        let candidate = makeCandidate(kind: .oauthToken, hasCredential: false, snapshot: makeSnapshot())
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: Date())

        #expect(decision.chosen == nil)
        #expect(decision.verdicts[candidate.profileID] == .noCredential)
    }

    @Test("optedOut: profile with poolOptOut rejected")
    func optedOut() {
        let candidate = makeCandidate(poolOptOut: true, snapshot: makeSnapshot())
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: Date())

        #expect(decision.chosen == nil)
        #expect(decision.verdicts[candidate.profileID] == .optedOut)
    }

    @Test("sameAccount: profile in excludingAccountKeys rejected")
    func sameAccount() {
        let candidate = makeCandidate(accountKey: "account1", snapshot: makeSnapshot())
        let decision = ProfilePoolPicker.pick(
            candidates: [candidate],
            excludingAccountKeys: ["account1"],
            now: Date()
        )

        #expect(decision.chosen == nil)
        #expect(decision.verdicts[candidate.profileID] == .sameAccount)
    }

    @Test("noFreshReading: snapshot is nil")
    func noFreshReadingNilSnapshot() {
        let candidate = makeCandidate(snapshot: nil)
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: Date())

        #expect(decision.chosen == nil)
        #expect(decision.verdicts[candidate.profileID] == .noFreshReading)
    }

    @Test("noFreshReading: fetchedAt is nil")
    func noFreshReadingNilFetchedAt() {
        let candidate = makeCandidate(snapshot: makeSnapshot(fetchedAt: nil))
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: Date())

        #expect(decision.chosen == nil)
        #expect(decision.verdicts[candidate.profileID] == .noFreshReading)
    }

    @Test("noFreshReading: oauth snapshot too old (301s vs 300s threshold)")
    func noFreshReadingOAuthStale() {
        let now = Date()
        let fetchedAt = now.addingTimeInterval(-301)
        let candidate = makeCandidate(
            kind: .oauth,
            snapshot: makeSnapshot(fetchedAt: fetchedAt)
        )
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: now)

        #expect(decision.chosen == nil)
        #expect(decision.verdicts[candidate.profileID] == .noFreshReading)
    }

    @Test("noFreshReading: oauth snapshot fresh (299s vs 300s threshold)")
    func noFreshReadingOAuthFresh() {
        let now = Date()
        let fetchedAt = now.addingTimeInterval(-299)
        let candidate = makeCandidate(
            kind: .oauth,
            snapshot: makeSnapshot(fetchedAt: fetchedAt, buckets: [makeBucket(kind: "session", percent: 30)])
        )
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: now)

        #expect(decision.chosen == candidate.profileID)
        guard case .eligible = decision.verdicts[candidate.profileID] else {
            Issue.record("Expected eligible verdict")
            return
        }
    }

    @Test("noFreshReading: oauthToken snapshot too old (901s vs 900s threshold)")
    func noFreshReadingTokenStale() {
        let now = Date()
        let fetchedAt = now.addingTimeInterval(-901)
        let candidate = makeCandidate(
            kind: .oauthToken,
            snapshot: makeSnapshot(fetchedAt: fetchedAt)
        )
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: now)

        #expect(decision.chosen == nil)
        #expect(decision.verdicts[candidate.profileID] == .noFreshReading)
    }

    @Test("noFreshReading: oauthToken snapshot fresh (899s vs 900s threshold)")
    func noFreshReadingTokenFresh() {
        let now = Date()
        let fetchedAt = now.addingTimeInterval(-899)
        let candidate = makeCandidate(
            kind: .oauthToken,
            snapshot: makeSnapshot(fetchedAt: fetchedAt, buckets: [makeBucket(kind: "session", percent: 30)])
        )
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: now)

        #expect(decision.chosen == candidate.profileID)
        guard case .eligible = decision.verdicts[candidate.profileID] else {
            Issue.record("Expected eligible verdict")
            return
        }
    }

    @Test("exhausted: profile at headroomFloor is exhausted")
    func exhaustedAtFloor() {
        let candidate = makeCandidate(
            snapshot: makeSnapshot(buckets: [makeBucket(kind: "session", percent: 95)])
        )
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: Date())

        #expect(decision.chosen == nil)
        #expect(decision.verdicts[candidate.profileID] == .exhausted)
    }

    @Test("exhausted: profile below headroomFloor is exhausted")
    func exhaustedBelowFloor() {
        let candidate = makeCandidate(
            snapshot: makeSnapshot(buckets: [makeBucket(kind: "session", percent: 99)])
        )
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: Date())

        #expect(decision.chosen == nil)
        #expect(decision.verdicts[candidate.profileID] == .exhausted)
    }

    @Test("eligible: profile with sufficient headroom")
    func eligibleSufficientHeadroom() {
        let candidate = makeCandidate(
            snapshot: makeSnapshot(buckets: [makeBucket(kind: "session", percent: 50)])
        )
        let decision = ProfilePoolPicker.pick(candidates: [candidate], now: Date())

        #expect(decision.chosen == candidate.profileID)
        guard case let .eligible(score, headroom, accountLoad) = decision.verdicts[candidate.profileID] else {
            Issue.record("Expected eligible verdict")
            return
        }
        #expect(headroom == 0.5)
        #expect(accountLoad == 0)
        #expect(score == 1.0 / 0.5)  // (0 + 1) / 0.5
    }

    // MARK: Headroom Calculation

    @Test("headroom: snapshot with no binding buckets returns 1.0")
    func headroomNoBindingBuckets() {
        let snapshot = makeSnapshot(buckets: [
            makeBucket(kind: "unknown", percent: 50)
        ])
        let hr = ProfilePoolPicker.headroom(of: snapshot)

        #expect(hr == 1.0)
    }

    @Test("headroom: percent > 100 is clamped to 100")
    func headroomPercentClamped() {
        let snapshot = makeSnapshot(buckets: [
            makeBucket(kind: "session", percent: 150)
        ])
        let hr = ProfilePoolPicker.headroom(of: snapshot)

        #expect(hr == 0.0)
    }

    @Test("headroom: binding window is maximum across buckets")
    func headroomMaxAcrossBuckets() {
        let snapshot = makeSnapshot(buckets: [
            makeBucket(kind: "session", percent: 40),
            makeBucket(kind: "weekly_all", percent: 80),
            makeBucket(kind: "weekly_scoped", percent: 60)
        ])
        let hr = ProfilePoolPicker.headroom(of: snapshot)

        #expect(hr == 0.2)  // 1 - 80/100
    }

    @Test("headroom: inactive weekly_scoped bucket is ignored")
    func headroomInactiveIgnored() {
        let snapshot = makeSnapshot(buckets: [
            makeBucket(kind: "session", percent: 40),
            makeBucket(kind: "weekly_scoped", percent: 99, isActive: false)
        ])
        let hr = ProfilePoolPicker.headroom(of: snapshot)

        #expect(hr == 0.6)  // 1 - 40/100, ignoring the 99% inactive bucket
    }

    // MARK: Scoring and Sorting

    @Test("scoring: empty profile beats loaded one at equal usage")
    func scoringEmptyBeatsLoaded() {
        let now = Date()
        let snapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 50)])

        let empty = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            accountKey: "account1",
            snapshot: snapshot,
            liveSessions: 0
        )
        let loaded = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            accountKey: "account1",
            snapshot: snapshot,
            liveSessions: 2
        )

        let decision = ProfilePoolPicker.pick(candidates: [empty, loaded], now: now)

        #expect(decision.chosen == empty.profileID)
    }

    @Test("scoring: lower usage beats higher at equal load")
    func scoringLowerUsageBeatsHigher() {
        let now = Date()
        let loaderSnapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 80)])
        let emptierSnapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 20)])

        let emptier = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            accountKey: "account1",
            snapshot: emptierSnapshot,
            liveSessions: 1
        )
        let loader = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            accountKey: "account1",
            snapshot: loaderSnapshot,
            liveSessions: 1
        )

        let decision = ProfilePoolPicker.pick(candidates: [loader, emptier], now: now)

        #expect(decision.chosen == emptier.profileID)
    }

    // MARK: Account Grouping

    @Test("accountGrouping: two profiles with same accountKey pool live counts")
    func accountGroupingSameLiveCount() {
        let now = Date()
        let snapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 30)])

        let profile1 = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            accountKey: "same-account",
            snapshot: snapshot,
            liveSessions: 2
        )
        let profile2 = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            accountKey: "same-account",
            snapshot: snapshot,
            liveSessions: 3
        )

        let decision = ProfilePoolPicker.pick(candidates: [profile1, profile2], now: now)

        guard case let .eligible(_, _, accountLoad1) = decision.verdicts[profile1.profileID],
              case let .eligible(_, _, accountLoad2) = decision.verdicts[profile2.profileID] else {
            Issue.record("Expected eligible verdicts")
            return
        }

        #expect(accountLoad1 == 5)  // 2 + 3
        #expect(accountLoad2 == 5)  // 2 + 3
    }

    @Test("accountGrouping: excluding one account key excludes all profiles with that key")
    func accountGroupingExcludeAll() {
        let now = Date()
        let snapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 30)])

        let profile1 = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            accountKey: "account-a",
            snapshot: snapshot
        )
        let profile2 = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            accountKey: "account-a",
            snapshot: snapshot
        )
        let profile3 = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            accountKey: "account-b",
            snapshot: snapshot
        )

        let decision = ProfilePoolPicker.pick(
            candidates: [profile1, profile2, profile3],
            excludingAccountKeys: ["account-a"],
            now: now
        )

        #expect(decision.verdicts[profile1.profileID] == .sameAccount)
        #expect(decision.verdicts[profile2.profileID] == .sameAccount)
        #expect(decision.chosen == profile3.profileID)
    }

    @Test("accountGrouping: opted-out twin's live sessions still count toward account")
    func accountGroupingOptedOutCountsLoad() {
        let now = Date()
        let snapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 30)])

        let eligible = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            accountKey: "account1",
            snapshot: snapshot,
            liveSessions: 1
        )
        let optedOut = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            accountKey: "account1",
            snapshot: snapshot,
            liveSessions: 5,
            poolOptOut: true
        )

        let decision = ProfilePoolPicker.pick(candidates: [eligible, optedOut], now: now)

        guard case let .eligible(score, _, accountLoad) = decision.verdicts[eligible.profileID] else {
            Issue.record("Expected eligible verdict")
            return
        }

        #expect(accountLoad == 6)  // 1 + 5 from opted-out twin
        #expect(score == 7.0 / 0.7)  // (6 + 1) / 0.7
    }

    // MARK: Tie-breaking

    @Test("tiebreak: configured default wins over non-default at equal score")
    func tiebreakConfiguredDefault() {
        let now = Date()
        let snapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 30)])

        let nonDefault = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            snapshot: snapshot,
            isConfiguredDefault: false
        )
        let isDefault = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            snapshot: snapshot,
            isConfiguredDefault: true
        )

        let decision = ProfilePoolPicker.pick(candidates: [nonDefault, isDefault], now: now)

        #expect(decision.chosen == isDefault.profileID)
    }

    @Test("tiebreak: lower sortOrder wins over higher")
    func tiebreakSortOrder() {
        let now = Date()
        let snapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 30)])

        let higher = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            snapshot: snapshot,
            sortOrder: 5
        )
        let lower = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            snapshot: snapshot,
            sortOrder: 2
        )

        let decision = ProfilePoolPicker.pick(candidates: [higher, lower], now: now)

        #expect(decision.chosen == lower.profileID)
    }

    @Test("tiebreak: profileID string ascending")
    func tiebreakProfileID() {
        let now = Date()
        let snapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 30)])

        let later = makeCandidate(
            profileID: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            snapshot: snapshot
        )
        let earlier = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            snapshot: snapshot
        )

        let decision = ProfilePoolPicker.pick(candidates: [later, earlier], now: now)

        #expect(decision.chosen == earlier.profileID)
    }

    // MARK: Determinism

    @Test("determinism: same input always yields same output")
    func determinismConsistent() {
        let now = Date()
        let snapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 50)])
        let candidates = [
            makeCandidate(profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, snapshot: snapshot, liveSessions: 2),
            makeCandidate(profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, snapshot: snapshot, liveSessions: 1),
            makeCandidate(profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, snapshot: snapshot, liveSessions: 3),
        ]

        let result1 = ProfilePoolPicker.pick(candidates: candidates, now: now)
        let result2 = ProfilePoolPicker.pick(candidates: candidates, now: now)
        let result3 = ProfilePoolPicker.pick(candidates: candidates, now: now)

        #expect(result1.chosen == result2.chosen)
        #expect(result2.chosen == result3.chosen)
        #expect(result1.verdicts == result2.verdicts)
        #expect(result2.verdicts == result3.verdicts)
    }

    @Test("determinism: shuffled input yields same output")
    func determinismShuffledInput() {
        let now = Date()
        let snapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 50)])
        let candidates = [
            makeCandidate(profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, snapshot: snapshot, liveSessions: 2),
            makeCandidate(profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, snapshot: snapshot, liveSessions: 1),
            makeCandidate(profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, snapshot: snapshot, liveSessions: 3),
        ]

        let result1 = ProfilePoolPicker.pick(candidates: candidates, now: now)
        let result2 = ProfilePoolPicker.pick(candidates: candidates.reversed(), now: now)

        #expect(result1.chosen == result2.chosen)
        #expect(result1.verdicts == result2.verdicts)
    }

    // MARK: Empty and All-Ineligible

    @Test("emptyInput: returns nil chosen with no verdicts")
    func emptyInput() {
        let decision = ProfilePoolPicker.pick(candidates: [], now: Date())

        #expect(decision.chosen == nil)
        #expect(decision.verdicts.isEmpty)
    }

    @Test("allIneligible: returns nil chosen with every verdict populated")
    func allIneligible() {
        let now = Date()
        let candidate1 = makeCandidate(profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .apiKey)
        let candidate2 = makeCandidate(profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, poolOptOut: true)
        let candidate3 = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            snapshot: makeSnapshot(buckets: [makeBucket(kind: "session", percent: 99)])
        )

        let decision = ProfilePoolPicker.pick(candidates: [candidate1, candidate2, candidate3], now: now)

        #expect(decision.chosen == nil)
        #expect(decision.verdicts.count == 3)
        #expect(decision.verdicts[candidate1.profileID] == .wrongKind)
        #expect(decision.verdicts[candidate2.profileID] == .optedOut)
        #expect(decision.verdicts[candidate3.profileID] == .exhausted)
    }

    // MARK: Staleness Window

    @Test("stalenessWindow: oauth returns 300")
    func stalenessWindowOAuth() {
        let window = ProfilePoolPicker.stalenessWindow(for: .oauth)
        #expect(window == 300)
    }

    @Test("stalenessWindow: oauthToken returns 900")
    func stalenessWindowOAuthToken() {
        let window = ProfilePoolPicker.stalenessWindow(for: .oauthToken)
        #expect(window == 900)
    }

    @Test("stalenessWindow: apiKey returns 300")
    func stalenessWindowApiKey() {
        let window = ProfilePoolPicker.stalenessWindow(for: .apiKey)
        #expect(window == 300)
    }

    @Test("stalenessWindow: bedrock returns 300")
    func stalenessWindowBedrock() {
        let window = ProfilePoolPicker.stalenessWindow(for: .bedrock)
        #expect(window == 300)
    }

    // MARK: Ranked Function

    @Test("ranked: returns eligible profiles in score order")
    func rankedOrder() {
        let now = Date()
        let emptySnapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 10)])
        let midSnapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 50)])
        let fullSnapshot = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 80)])

        let best = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            snapshot: emptySnapshot,
            liveSessions: 0
        )
        let middle = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            snapshot: midSnapshot,
            liveSessions: 0
        )
        let worst = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            snapshot: fullSnapshot,
            liveSessions: 0
        )
        let ineligible = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            kind: .apiKey
        )

        let ranked = ProfilePoolPicker.ranked(
            candidates: [worst, ineligible, best, middle],
            now: now
        )

        #expect(ranked == [best.profileID, middle.profileID, worst.profileID])
    }

    @Test("ranked: empty input returns empty array")
    func rankedEmpty() {
        let ranked = ProfilePoolPicker.ranked(candidates: [], now: Date())
        #expect(ranked.isEmpty)
    }

    @Test("ranked: all ineligible returns empty array")
    func rankedAllIneligible() {
        let candidate1 = makeCandidate(kind: .apiKey)
        let candidate2 = makeCandidate(kind: .bedrock)

        let ranked = ProfilePoolPicker.ranked(candidates: [candidate1, candidate2], now: Date())

        #expect(ranked.isEmpty)
    }

    // MARK: Complex Scenarios

    @Test("complexScenario: mixed eligibility with account grouping")
    func complexScenarioMixed() {
        let now = Date()
        let snapshot30 = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 30)])
        let snapshot60 = makeSnapshot(buckets: [makeBucket(kind: "session", percent: 60)])

        let accountA1 = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            accountKey: "account-a",
            snapshot: snapshot30,
            liveSessions: 1
        )
        let accountA2 = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            accountKey: "account-a",
            snapshot: snapshot30,
            liveSessions: 1,
            poolOptOut: true
        )
        let accountB = makeCandidate(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            accountKey: "account-b",
            snapshot: snapshot60,
            liveSessions: 0
        )

        let decision = ProfilePoolPicker.pick(candidates: [accountA1, accountA2, accountB], now: now)

        guard case let .eligible(scoreA1, _, loadA1) = decision.verdicts[accountA1.profileID],
              case let .eligible(scoreB, _, _) = decision.verdicts[accountB.profileID] else {
            Issue.record("Expected eligible verdicts")
            return
        }

        // accountA1 carries load 2 (1 + 1 from opt-out twin)
        #expect(loadA1 == 2)
        #expect(scoreA1 == 3.0 / 0.7)  // (2 + 1) / 0.7

        // accountB carries load 0
        #expect(scoreB == 1.0 / 0.4)  // (0 + 1) / 0.4

        // accountB has lower score, so it wins
        #expect(decision.chosen == accountB.profileID)
    }
}
