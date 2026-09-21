import Foundation
import Testing
import TBDShared
import TestSupport

@testable import TBDDaemonLib

/// Surfacing a stale account (design 2026-09-05 §6.1): a balanced pick that
/// skips an otherwise-eligible account for `noFreshReading` tells the person
/// once, on the spawning worktree.
@Suite("StaleAccountAlerts")
struct StaleAccountAlertsTests {

    // MARK: - Fixture

    actor Recorder {
        private(set) var posts: [(worktreeID: UUID, message: String)] = []
        func record(_ worktreeID: UUID, _ message: String) { posts.append((worktreeID, message)) }
        var messages: [String] { posts.map(\.message) }
    }

    struct Fixture {
        let db: TBDDatabase
        let resolver: ModelProfileResolver
        let alerts: StaleAccountAlerts
        let recorder: Recorder
        let dates: TestDateSource
        let worktreeID: UUID
        /// Always fresh and eligible, so every balanced pick has a winner.
        let freshID: UUID
    }

    private static func snapshot(fetchedAt: Date?, percent: Double = 10, attemptAt: Date) -> ProfileUsageSnapshot {
        ProfileUsageSnapshot(
            buckets: [ClaudeUsageLimitBucket(kind: "session", group: "session", percent: percent)],
            fetchedAt: fetchedAt,
            lastAttemptAt: attemptAt,
            status: "ok",
            statusKind: .ok)
    }

    /// `noIdentity` profiles report no login identity, so they are skipped as
    /// `noCredential`.
    private func makeFixture(
        balancing: Bool = true,
        noIdentity: @escaping @Sendable (String) -> Bool = { _ in false },
        notify: StaleAccountAlerts.Notify? = nil
    ) async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let dates = TestDateSource()
        let fresh = try await db.modelProfiles.create(name: "Work", kind: .oauth)
        try await db.oauthUsageSnapshots.upsert(
            profileID: fresh.id,
            snapshot: Self.snapshot(fetchedAt: dates.now, attemptAt: dates.now))
        try await db.config.setProfileBalancingEnabled(balancing)
        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { id in noIdentity(id.uuidString) ? nil : "\(id.uuidString)@example.com" },
            now: dates.provider)
        let recorder = Recorder()
        let recording: StaleAccountAlerts.Notify = { wt, message in
            await recorder.record(wt, message)
        }
        let alerts = StaleAccountAlerts(notify: notify ?? recording)
        let resolver = ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config,
            candidateSource: source,
            reservations: ProfilePickReservations(now: dates.provider),
            staleAlerts: alerts,
            now: dates.provider)
        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/wt-stale-\(UUID().uuidString)", tmuxServer: "@wt")
        return Fixture(
            db: db, resolver: resolver, alerts: alerts, recorder: recorder,
            dates: dates, worktreeID: worktree.id, freshID: fresh.id)
    }

    /// Adds an oauth profile whose last successful reading is `minutesOld` old.
    @discardableResult
    private func addStale(_ f: Fixture, name: String = "Personal", minutesOld: Double = 42) async throws -> UUID {
        let profile = try await f.db.modelProfiles.create(name: name, kind: .oauth)
        try await setReading(f, profile.id, minutesOld: minutesOld)
        return profile.id
    }

    private func setReading(_ f: Fixture, _ id: UUID, minutesOld: Double, percent: Double = 10) async throws {
        try await f.db.oauthUsageSnapshots.upsert(
            profileID: id,
            snapshot: Self.snapshot(
                fetchedAt: f.dates.now.addingTimeInterval(-minutesOld * 60),
                percent: percent, attemptAt: f.dates.now))
    }

    private func spawn(_ f: Fixture, balance: Bool = true, worktree: Bool = true) async throws {
        let resolved = try await f.resolver.resolve(
            repoID: nil, balance: balance, worktreeID: worktree ? f.worktreeID : nil)
        await f.resolver.settleReservation(resolved?.reservationID)
    }

    // MARK: - Once, then latched

    @Test func firstStaleSkipNotifiesOnceOnTheSpawningWorktree() async throws {
        let f = try await makeFixture()
        try await addStale(f)

        try await spawn(f)

        let posts = await f.recorder.posts
        #expect(posts.count == 1)
        #expect(posts.first?.worktreeID == f.worktreeID)
        #expect(posts.first?.message
            == "Usage for Personal hasn't refreshed in 42 min — balancing is skipping it; check its login")
    }

    @Test func aSecondStaleSkipDoesNotNotifyAgain() async throws {
        let f = try await makeFixture()
        let stale = try await addStale(f)

        try await spawn(f)
        try await spawn(f)

        #expect(await f.recorder.posts.count == 1)
        #expect(await f.alerts.isLatched(stale))
    }

    @Test func aFreshReadingClearsTheLatchSoARelapseNotifiesAgain() async throws {
        let f = try await makeFixture()
        let stale = try await addStale(f)
        try await spawn(f)
        #expect(await f.recorder.posts.count == 1)

        try await setReading(f, stale, minutesOld: 0)
        try await spawn(f)
        #expect(await f.recorder.posts.count == 1)
        #expect(await f.alerts.isLatched(stale) == false)

        try await setReading(f, stale, minutesOld: 10)
        try await spawn(f)
        let messages = await f.recorder.messages
        #expect(messages.count == 2)
        #expect(messages.last?.contains("hasn't refreshed in 10 min") == true)
    }

    @Test func anExhaustedFreshReadingAlsoClearsTheLatch() async throws {
        let f = try await makeFixture()
        let stale = try await addStale(f)
        try await spawn(f)

        try await setReading(f, stale, minutesOld: 0, percent: 99)
        try await spawn(f)
        #expect(await f.alerts.isLatched(stale) == false)
        #expect(await f.recorder.posts.count == 1)
    }

    // MARK: - Never notifies

    @Test func otherSkipReasonsNeverNotify() async throws {
        let ids = StaleAlertsIDSet()
        let f = try await makeFixture(noIdentity: { ids.contains($0) })
        // Opted out, with a stale reading.
        let optedOut = try await addStale(f, name: "OptedOut")
        try await f.db.modelProfiles.setPoolOptOut(id: optedOut, optOut: true)
        // No credential, with a stale reading.
        let noCred = try await addStale(f, name: "NoLogin")
        ids.insert(noCred.uuidString)
        // Wrong kind.
        _ = try await f.db.modelProfiles.create(name: "Bedrock", kind: .bedrock)
        // Exhausted on a fresh reading.
        let full = try await f.db.modelProfiles.create(name: "Full", kind: .oauth)
        try await setReading(f, full.id, minutesOld: 0, percent: 99)

        try await spawn(f)

        #expect(await f.recorder.posts.isEmpty)
    }

    @Test func balancingOffNeverNotifies() async throws {
        let f = try await makeFixture(balancing: false)
        try await addStale(f)

        try await spawn(f)

        #expect(await f.recorder.posts.isEmpty)
    }

    @Test func aResumeNeverNotifies() async throws {
        let f = try await makeFixture()
        let stale = try await addStale(f)

        try await spawn(f, balance: false)

        #expect(await f.recorder.posts.isEmpty)
        #expect(await f.alerts.isLatched(stale) == false)
    }

    @Test func aNilWorktreeNeverNotifiesAndLeavesTheProfileUnlatched() async throws {
        let f = try await makeFixture()
        let stale = try await addStale(f)

        try await spawn(f, worktree: false)
        #expect(await f.recorder.posts.isEmpty)
        #expect(await f.alerts.isLatched(stale) == false)

        // The next spawn that names its worktree still tells the person.
        try await spawn(f)
        #expect(await f.recorder.posts.count == 1)
    }

    // MARK: - Wording

    @Test func noReadingYetWordingWhenThereIsNoSnapshot() async throws {
        let f = try await makeFixture()
        _ = try await f.db.modelProfiles.create(name: "Personal", kind: .oauth)

        try await spawn(f)

        #expect(await f.recorder.messages
            == ["Usage for Personal has no usage reading yet — balancing is skipping it; check its login"])
    }

    @Test func messageFloorsTheAgeAndTreatsANeverSucceededFetchAsNoReading() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nearly43 = Self.snapshot(fetchedAt: now.addingTimeInterval(-(42 * 60 + 59)), attemptAt: now)
        #expect(StaleAccountAlerts.message(profileName: "P", snapshot: nearly43, now: now)
            == "Usage for P hasn't refreshed in 42 min — balancing is skipping it; check its login")
        let neverFetched = Self.snapshot(fetchedAt: nil, attemptAt: now)
        #expect(StaleAccountAlerts.message(profileName: "P", snapshot: neverFetched, now: now)
            == "Usage for P has no usage reading yet — balancing is skipping it; check its login")
    }

    // MARK: - Failure and production wiring

    struct PostFailed: Error {}

    @Test func aFailedPostDoesNotFailTheSpawnAndRetriesNextTime() async throws {
        let f = try await makeFixture(notify: { _, _ in throw PostFailed() })
        let stale = try await addStale(f)

        let resolved = try await f.resolver.resolve(repoID: nil, worktreeID: f.worktreeID)

        #expect(resolved?.profileID == f.freshID)
        #expect(await f.alerts.isLatched(stale) == false)
    }

    @Test func theProductionNotifierPersistsAnAttentionNeededRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/wt-stale-\(UUID().uuidString)", tmuxServer: "@wt")
        let notify = StaleAccountAlerts.notifier(db: db, subscriptions: StateSubscriptionManager())

        try await notify(worktree.id, "Usage for P has no usage reading yet")

        let rows = try await db.notifications.unread(worktreeID: worktree.id)
        #expect(rows.count == 1)
        #expect(rows.first?.type == .attentionNeeded)
        #expect(rows.first?.message == "Usage for P has no usage reading yet")
    }
}

/// A thread-safe set the fixture's `loginIdentity` closure reads, so a test can
/// mark a profile credential-less after creating it.
private final class StaleAlertsIDSet: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String> = []
    func insert(_ value: String) { lock.withLock { _ = values.insert(value) } }
    func contains(_ value: String) -> Bool { lock.withLock { values.contains(value) } }
}
