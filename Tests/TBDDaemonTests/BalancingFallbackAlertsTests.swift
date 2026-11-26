import Foundation
import Testing
import TBDShared
import TestSupport

@testable import TBDDaemonLib

/// The balanced pick's fallback (design 2026-09-05 §6.3): when no account may
/// be routed on, the session lands on the least bad account in the pool rather
/// than on the global default, and the person is told.
@Suite("BalancingFallbackAlerts")
struct BalancingFallbackAlertsTests {

    // MARK: - Fixture

    actor Recorder {
        private(set) var posts: [(worktreeID: UUID, message: String)] = []
        func record(_ worktreeID: UUID, _ message: String) { posts.append((worktreeID, message)) }
        var messages: [String] { posts.map(\.message) }
    }

    struct Fixture {
        let db: TBDDatabase
        let resolver: ModelProfileResolver
        let reservations: ProfilePickReservations
        let alerts: BalancingFallbackAlerts
        let recorder: Recorder
        let dates: TestDateSource
        let worktreeID: UUID
        /// The configured global default, nearly full.
        let defaultID: UUID
        /// Over the default ceiling, but the emptiest account in the pool.
        let spareID: UUID
    }

    private static func snapshot(percent: Double, fetchedAt: Date?, attemptAt: Date) -> ProfileUsageSnapshot {
        ProfileUsageSnapshot(
            buckets: [ClaudeUsageLimitBucket(kind: "session", group: "session", percent: percent)],
            fetchedAt: fetchedAt,
            lastAttemptAt: attemptAt,
            status: "ok",
            statusKind: .ok)
    }

    private func setReading(_ f: Fixture, _ id: UUID, percent: Double, minutesOld: Double = 0) async throws {
        try await f.db.oauthUsageSnapshots.upsert(
            profileID: id,
            snapshot: Self.snapshot(
                percent: percent,
                fetchedAt: f.dates.now.addingTimeInterval(-minutesOld * 60),
                attemptAt: f.dates.now))
    }

    private func makeFixture(balancing: Bool = true) async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let dates = TestDateSource()
        let defaultProfile = try await db.modelProfiles.create(name: "Main", kind: .oauth)
        let spare = try await db.modelProfiles.create(name: "Spare", kind: .oauth)
        try await db.config.setDefaultProfileID(defaultProfile.id)
        try await db.config.setProfileBalancingEnabled(balancing)
        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { "\($0.uuidString)@example.com" },
            now: dates.provider)
        let recorder = Recorder()
        let alerts = BalancingFallbackAlerts(notify: { wt, message in
            await recorder.record(wt, message)
        })
        let reservations = ProfilePickReservations(now: dates.provider)
        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: source,
            reservations: reservations,
            fallbackAlerts: alerts,
            now: dates.provider)
        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/wt-fallback-\(UUID().uuidString)", tmuxServer: "@wt")
        let f = Fixture(
            db: db, resolver: resolver, reservations: reservations, alerts: alerts,
            recorder: recorder, dates: dates, worktreeID: worktree.id,
            defaultID: defaultProfile.id, spareID: spare.id)
        try await setReading(f, defaultProfile.id, percent: 99)
        try await setReading(f, spare.id, percent: 88)
        return f
    }

    @discardableResult
    private func spawn(_ f: Fixture, worktree: Bool = true) async throws -> ResolvedModelProfile? {
        let resolved = try await f.resolver.resolve(
            repoID: nil, worktreeID: worktree ? f.worktreeID : nil)
        await f.resolver.settleReservation(resolved?.reservationID)
        return resolved
    }

    // MARK: - Where the session lands

    /// The incident shape: every account over the ceiling, and the global
    /// default the fullest of them. Before the fallback, the spawn went to the
    /// default regardless.
    @Test func nothingEligibleLandsOnTheLeastUsedAccountNotTheDefault() async throws {
        let f = try await makeFixture()

        let resolved = try await f.resolver.resolve(repoID: nil, worktreeID: f.worktreeID)

        #expect(resolved?.profileID == f.spareID)
        // A fallback places a session, so it holds a reservation like any pick.
        #expect(resolved?.reservationID != nil)
        #expect(await f.reservations.heldCount == 1)
    }

    @Test func aRaisedCeilingMakesTheSameAccountAnOrdinaryPick() async throws {
        let f = try await makeFixture()
        try await f.db.config.setProfileBalancingUsageCeilingPercent(95)

        let resolved = try await spawn(f)

        #expect(resolved?.profileID == f.spareID)
        #expect(await f.recorder.posts.isEmpty)
    }

    @Test func balancingOffKeepsTheDefaultAndSaysNothing() async throws {
        let f = try await makeFixture(balancing: false)

        let resolved = try await spawn(f)

        #expect(resolved?.profileID == f.defaultID)
        #expect(await f.recorder.posts.isEmpty)
    }

    @Test func aPoolWithNothingInItFallsThroughToTheDefault() async throws {
        let f = try await makeFixture()
        try await f.db.modelProfiles.setPoolOptOut(id: f.defaultID, optOut: true)
        try await f.db.modelProfiles.setPoolOptOut(id: f.spareID, optOut: true)

        let resolved = try await spawn(f)

        #expect(resolved?.profileID == f.defaultID)
        #expect(await f.recorder.posts.isEmpty)
    }

    // MARK: - Telling the person

    @Test func aFallbackNotifiesOnTheSpawningWorktree() async throws {
        let f = try await makeFixture()

        try await spawn(f)

        let posts = await f.recorder.posts
        #expect(posts.count == 1)
        #expect(posts.first?.worktreeID == f.worktreeID)
        #expect(posts.first?.message
            == "No account is under the 85% balancing limit with a fresh reading — this session started on Spare, the least used (5h 88%)")
    }

    @Test func aSecondFallbackToTheSameAccountDoesNotNotifyAgain() async throws {
        let f = try await makeFixture()

        try await spawn(f)
        try await spawn(f)

        #expect(await f.recorder.posts.count == 1)
        #expect(await f.alerts.isLatched(f.spareID))
    }

    @Test func anEligiblePickEndsTheEpisodeSoARelapseNotifiesAgain() async throws {
        let f = try await makeFixture()
        try await spawn(f)

        try await setReading(f, f.defaultID, percent: 10)
        let recovered = try await spawn(f)
        #expect(recovered?.profileID == f.defaultID)
        #expect(await f.alerts.isLatched(f.spareID) == false)

        try await setReading(f, f.defaultID, percent: 99)
        try await spawn(f)
        #expect(await f.recorder.posts.count == 2)
    }

    /// The message quotes the reading at the resolver's pick time, the same
    /// instant the pick judged it at. Spare's weekly window resets exactly
    /// then, years after the wall clock, so only the pick's `now` reads it as
    /// reset; its 5-hour window is still open and over the ceiling, so the
    /// pick falls back to it.
    @Test func aFallbackQuotesAnEndedWindowAsResetAtThePickTime() async throws {
        let f = try await makeFixture()
        let pickTime = Date(timeIntervalSince1970: 2_000_000_000)
        f.dates.now = pickTime
        try await setReading(f, f.defaultID, percent: 99)
        try await f.db.oauthUsageSnapshots.upsert(
            profileID: f.spareID,
            snapshot: ProfileUsageSnapshot(
                buckets: [
                    ClaudeUsageLimitBucket(kind: "session", group: "session", percent: 88,
                                           resetsAt: pickTime.addingTimeInterval(3_600)),
                    ClaudeUsageLimitBucket(kind: "weekly_all", group: "weekly", percent: 97,
                                           resetsAt: pickTime),
                ],
                fetchedAt: pickTime, lastAttemptAt: pickTime, status: "ok", statusKind: .ok))

        let resolved = try await spawn(f)

        #expect(resolved?.profileID == f.spareID)
        #expect(await f.recorder.messages
            == ["No account is under the 85% balancing limit with a fresh reading — this session started on Spare, the least used (5h 88% · week reset)"])
    }

    @Test func aNilWorktreeNotifiesNobodyAndLatchesNothing() async throws {
        let f = try await makeFixture()

        let resolved = try await spawn(f, worktree: false)

        #expect(resolved?.profileID == f.spareID)
        #expect(await f.recorder.posts.isEmpty)
        #expect(await f.alerts.isLatched(f.spareID) == false)
    }

    // MARK: - Wording

    @Test func messagesNameTheReasonTheAccountAndItsReading() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let policy = ProfilePoolPolicy(usageCeilingPercent: 80)
        let stale = ProfileUsageSnapshot(
            buckets: [
                ClaudeUsageLimitBucket(kind: "session", group: "session", percent: 20),
                ClaudeUsageLimitBucket(kind: "weekly_all", group: "weekly", percent: 41),
            ],
            fetchedAt: now.addingTimeInterval(-(42 * 60 + 59)),
            lastAttemptAt: now, status: "ok", statusKind: .ok)
        #expect(BalancingFallbackAlerts.message(
            profileName: "P", reason: .staleReading, snapshot: stale, policy: policy, now: now)
            == "No account has a fresh usage reading under the 80% balancing limit — this session started on P by its last reading (5h 20% · week 41%, 42 min old)")
        #expect(BalancingFallbackAlerts.message(
            profileName: "P", reason: .staleReading, snapshot: nil, policy: policy, now: now)
            == "No account has a fresh usage reading under the 80% balancing limit — this session started on P, which has no usage reading yet")

        let full = ProfileUsageSnapshot(
            buckets: [ClaudeUsageLimitBucket(kind: "session", group: "session", percent: 100)],
            fetchedAt: now, lastAttemptAt: now, status: "ok", statusKind: .ok)
        #expect(BalancingFallbackAlerts.message(
            profileName: "P", reason: .full, snapshot: full, policy: policy, now: now)
            == "Every account is at its usage limit — this session started on P (5h 100%) and may stop on its first turn")
    }

    /// A window whose reset is at or before `now` says it reset instead of
    /// quoting its old percent; an open window keeps its percent.
    @Test func messagesSayAnEndedWindowResetAndKeepAnOpenWindowsPercent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let policy = ProfilePoolPolicy(usageCeilingPercent: 80)

        let open = ProfileUsageSnapshot(
            buckets: [
                ClaudeUsageLimitBucket(kind: "session", group: "session", percent: 100,
                                       resetsAt: now.addingTimeInterval(3_600)),
                ClaudeUsageLimitBucket(kind: "weekly_all", group: "weekly", percent: 64,
                                       resetsAt: now.addingTimeInterval(86_400)),
            ],
            fetchedAt: now, lastAttemptAt: now, status: "ok", statusKind: .ok)
        #expect(BalancingFallbackAlerts.message(
            profileName: "P", reason: .full, snapshot: open, policy: policy, now: now)
            == "Every account is at its usage limit — this session started on P (5h 100% · week 64%) and may stop on its first turn")

        let sessionEndedAtNow = ProfileUsageSnapshot(
            buckets: [
                ClaudeUsageLimitBucket(kind: "session", group: "session", percent: 95, resetsAt: now),
                ClaudeUsageLimitBucket(kind: "weekly_all", group: "weekly", percent: 88,
                                       resetsAt: now.addingTimeInterval(86_400)),
            ],
            fetchedAt: now, lastAttemptAt: now, status: "ok", statusKind: .ok)
        #expect(BalancingFallbackAlerts.message(
            profileName: "P", reason: .aboveCeiling, snapshot: sessionEndedAtNow, policy: policy, now: now)
            == "No account is under the 80% balancing limit with a fresh reading — this session started on P, the least used (5h reset · week 88%)")

        let weeklyEndedBeforeNow = ProfileUsageSnapshot(
            buckets: [
                ClaudeUsageLimitBucket(kind: "session", group: "session", percent: 20,
                                       resetsAt: now.addingTimeInterval(3_600)),
                ClaudeUsageLimitBucket(kind: "weekly_all", group: "weekly", percent: 97,
                                       resetsAt: now.addingTimeInterval(-60)),
            ],
            fetchedAt: now.addingTimeInterval(-(42 * 60)), lastAttemptAt: now,
            status: "ok", statusKind: .ok)
        #expect(BalancingFallbackAlerts.message(
            profileName: "P", reason: .staleReading, snapshot: weeklyEndedBeforeNow, policy: policy, now: now)
            == "No account has a fresh usage reading under the 80% balancing limit — this session started on P by its last reading (5h 20% · week reset, 42 min old)")
    }
}
