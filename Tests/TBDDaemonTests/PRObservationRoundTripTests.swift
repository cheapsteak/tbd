import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

// DEFECT UNDER TEST: `.none` and `.undetermined` survive at the manager and
// then quietly collapse somewhere on the way out — a JSON column that drops the
// cause, an RPC result that only carries statuses, a hydrate that turns a
// recorded outage back into "no attempt on record". Each layer is asserted
// separately here, on composed output, because a collapse at any ONE of them
// restores the original bug in full while every other layer's test still passes.
//
// Layers traced: manager → persist callback → `worktree.prObservation` column →
// `worktree.list` model → `hydrateObservations` after a restart → `pr.list`
// RPC → `pr.refresh` RPC.

@Suite("PR observation round trip")
struct PRObservationRoundTripTests {

    private static let stamp = Date(timeIntervalSince1970: 1_760_000_000)

    private static func makeDB() async throws -> (db: TBDDatabase, worktreeID: UUID) {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/repoPRO-\(UUID().uuidString)", displayName: "repoPRO", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "tbd/w",
            path: "/tmp/repoPRO/w-\(UUID().uuidString)", tmuxServer: "s")
        return (db, wt.id)
    }

    private static func wire(_ manager: PRStatusManager, to db: TBDDatabase) async {
        await manager.setOnObservationPersist { id, observation in
            try? await db.worktrees.setPRObservation(id: id, observation: observation)
        }
    }

    // MARK: - Persistence

    @Test("a .none and an .undetermined persist and reload as different outcomes")
    func persistedOutcomesStayDistinct() async throws {
        let (db, wtID) = try await Self.makeDB()
        let repo2 = try await db.repos.create(
            path: "/tmp/repoPRO2-\(UUID().uuidString)", displayName: "repoPRO2", defaultBranch: "main")
        let other = try await db.worktrees.create(
            repoID: repo2.id, name: "o", branch: "tbd/o",
            path: "/tmp/repoPRO/o-\(UUID().uuidString)", tmuxServer: "s")

        try await db.worktrees.setPRObservation(
            id: wtID, observation: PRObservation(outcome: .none, observedAt: Self.stamp))
        try await db.worktrees.setPRObservation(
            id: other.id,
            observation: PRObservation(outcome: .undetermined(cause: PRUndeterminedCause.queryFailed),
                                       observedAt: Self.stamp))

        let reloaded = try await db.worktrees.allPRObservations()
        #expect(reloaded[wtID]?.outcome == PRObservation.Outcome.none)
        #expect(reloaded[other.id]?.outcome
                == .undetermined(cause: PRUndeterminedCause.queryFailed))
        #expect(reloaded[wtID]?.outcome != reloaded[other.id]?.outcome)
        #expect(reloaded[wtID]?.observedAt == Self.stamp)
    }

    @Test("a worktree with no attempt on record reads as neither outcome")
    func noAttemptIsNeitherOutcome() async throws {
        // The third state. A row that has never been polled must not decode as
        // `.none` (which would claim the forge answered) nor as `.undetermined`
        // (which would claim an attempt failed).
        let (db, wtID) = try await Self.makeDB()

        let observations = try await db.worktrees.allPRObservations()
        #expect(observations[wtID] == nil)
        let model = try #require(try await db.worktrees.get(id: wtID))
        #expect(model.prObservation == nil)
    }

    @Test("the manager's recorded outcome reaches the worktree row verbatim")
    func recordedOutcomeReachesTheRow() async throws {
        let (db, wtID) = try await Self.makeDB()
        let manager = PRStatusManager(now: { Self.stamp })
        await Self.wire(manager, to: db)

        // No gh at all: the poll cannot ask, and must say so rather than
        // reporting an empty fleet.
        await manager.fetchAll(worktrees: [(
            id: wtID, branch: "tbd/w", upstreamBranch: "main", defaultBranch: "main",
            pushBranch: .noPushDestination, worktreePath: "/wt/acme-prod", prNumber: 7)])

        let row = try #require(try await db.worktrees.get(id: wtID))
        let outcome = try #require(row.prObservation?.outcome)
        guard case .undetermined(let cause) = outcome else {
            Issue.record("expected .undetermined on the row, observed \(outcome)")
            return
        }
        #expect(!cause.isEmpty)
        #expect(row.prObservation?.observedAt == Self.stamp)
    }

    /// nil on this column is the third value — "the forge was never asked" —
    /// and a blob that will not decode has no business asserting it. Bytes are
    /// on the row, so an attempt happened; what it concluded is all that was
    /// lost, and that is precisely `.undetermined`.
    @Test("an unreadable recorded outcome is ignorance, not 'never attempted'")
    func anUnreadableObservationBlobIsUndeterminedNotAbsent() async throws {
        let (db, wtID) = try await Self.makeDB()
        // A truncated blob — the shape a partial write or a schema change
        // leaves behind.
        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: "UPDATE worktree SET prObservation = ? WHERE id = ?",
                arguments: [#"{"outcome":"und"#, wtID.uuidString])
        }

        let model = try #require(try await db.worktrees.get(id: wtID))
        let observation = try #require(
            model.prObservation,
            "an unreadable record decoded as 'no attempt has ever been made'")
        guard case .undetermined(let cause) = observation.outcome else {
            Issue.record("expected .undetermined, observed \(observation.outcome)")
            return
        }
        #expect(cause == PRUndeterminedCause.unreadableRecord)
        // Nothing on hand says when the attempt was, and the safe direction to
        // be wrong in is "older than it is" — never presenting a reading nobody
        // took as the freshest anyone has.
        #expect(observation.observedAt == .distantPast)
    }

    /// The map hydrated from these rows is handed out whole in every `pr.list`,
    /// on a thirty-second cadence. "Every worktree ever created" is not a set
    /// that stops growing, and an archived worktree's pull request is one
    /// nothing will ever refresh — the poller enumerates active worktrees only.
    @Test("archived worktrees are not hydrated into the PR maps")
    func hydrationIsScopedToActiveWorktrees() async throws {
        let (db, activeID) = try await Self.makeDB()
        let repo = try #require(try await db.repos.list().first)
        let archived = try await db.worktrees.create(
            repoID: repo.id, name: "old", branch: "tbd/old",
            path: "/tmp/repoPRO/old-\(UUID().uuidString)", tmuxServer: "s")
        for id in [activeID, archived.id] {
            try await db.worktrees.setPRObservation(
                id: id, observation: PRObservation(outcome: .observed, observedAt: Self.stamp))
            try await db.worktrees.setPRStatus(
                id: id,
                status: PRStatus(number: 5, url: "https://github.com/acme/acme-prod/pull/5",
                                 state: .mergeable, observedAt: Self.stamp))
        }
        try await db.worktrees.updateStatus(id: archived.id, status: .archived)

        let observations = try await db.worktrees.allPRObservations()
        let statuses = try await db.worktrees.allPRStatuses()
        #expect(observations.keys.sorted() == [activeID].sorted())
        #expect(statuses.keys.sorted() == [activeID].sorted())
    }

    @Test("hydrate restores a recorded .undetermined across a daemon restart")
    func hydrateRestoresUndetermined() async throws {
        // Without this, every daemon start would downgrade a recorded outage to
        // "no attempt on record" — losing exactly the fact that spans a restart.
        let (db, wtID) = try await Self.makeDB()
        try await db.worktrees.setPRObservation(
            id: wtID,
            observation: PRObservation(outcome: .undetermined(cause: PRUndeterminedCause.cliUnavailable),
                                       observedAt: Self.stamp))

        let restarted = PRStatusManager(now: { Self.stamp })
        await restarted.hydrateObservations(try await db.worktrees.allPRObservations())

        #expect(await restarted.observation(for: wtID)?.outcome
                == .undetermined(cause: PRUndeterminedCause.cliUnavailable))
    }

    // MARK: - RPC

    @Test("pr.list carries both outcomes, distinctly, alongside the statuses")
    func prListCarriesBothOutcomes() async throws {
        let (db, answeredID) = try await Self.makeDB()
        let repo2 = try await db.repos.create(
            path: "/tmp/repoPRO2-\(UUID().uuidString)", displayName: "repoPRO2", defaultBranch: "main")
        let unreachable = try await db.worktrees.create(
            repoID: repo2.id, name: "u", branch: "tbd/u",
            path: "/tmp/repoPRO/u-\(UUID().uuidString)", tmuxServer: "s")
        let manager = PRStatusManager(now: { Self.stamp })
        await manager.hydrateObservations([
            answeredID: PRObservation(outcome: .none, observedAt: Self.stamp),
            unreachable.id: PRObservation(
                outcome: .undetermined(cause: PRUndeterminedCause.queryFailed), observedAt: Self.stamp)
        ])
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            prManager: manager,
            actuationLog: makeTestActuationLog())

        let response = await router.handle(RPCRequest(method: RPCMethod.prList))
        #expect(response.success)
        let result = try response.decodeResult(PRListResult.self)

        #expect(result.observations[answeredID]?.outcome == PRObservation.Outcome.none)
        #expect(result.observations[unreachable.id]?.outcome
                == .undetermined(cause: PRUndeterminedCause.queryFailed))
        #expect(result.observations[answeredID]?.outcome != result.observations[unreachable.id]?.outcome)
        // Both are absent from `statuses`. That absence is exactly what used to
        // be the only signal, and it says nothing on its own.
        #expect(result.statuses[answeredID] == nil)
        #expect(result.statuses[unreachable.id] == nil)
    }

    @Test("the pr.list wire form survives a JSON round trip")
    func prListWireFormSurvivesEncoding() throws {
        // The RPC crosses a socket as JSON, so the tagged-object encoding has to
        // preserve the cause text — a wire form that dropped it would leave
        // `.undetermined` decoding as a bare, cause-less "something went wrong".
        let id = UUID()
        let original = PRListResult(
            statuses: [:],
            observations: [id: PRObservation(
                outcome: .undetermined(cause: PRUndeterminedCause.unparseableResponse),
                observedAt: Self.stamp)])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PRListResult.self, from: data)

        #expect(decoded.observations[id]?.outcome
                == .undetermined(cause: PRUndeterminedCause.unparseableResponse))
        #expect(decoded.observations[id]?.observedAt == Self.stamp)
    }

    @Test("a pr.list result from an older daemon decodes with no observations, not empty outcomes")
    func olderDaemonDecodesWithoutObservations() throws {
        let id = UUID()
        // Encoded through a shape with NO `observations` key, which is exactly
        // what an older daemon puts on the wire. (Hand-writing the JSON would
        // get the `[UUID: PRStatus]` encoding wrong — Foundation emits a
        // non-String-keyed dictionary as a flat array.)
        let legacy = try JSONEncoder().encode(LegacyPRListResult(
            statuses: [id: PRStatus(number: 3, url: "u", state: .mergeable)]))

        let decoded = try JSONDecoder().decode(PRListResult.self, from: legacy)

        #expect(decoded.statuses[id]?.number == 3)
        #expect(decoded.observations.isEmpty, "an absent field means no attempt is on record — not `.none`")
    }

    @Test("pr.refresh reports the attempt's own outcome beside the retained value")
    func prRefreshCarriesItsObservation() async throws {
        // The doc comment this fixes claimed a nil status meant "no PR found".
        // Here the status is non-nil (a value was retained) while the attempt
        // itself did not resolve — the pair the old shape could not express.
        let (db, wtID) = try await Self.makeDB()
        let manager = PRStatusManager(now: { Self.stamp })
        await manager.seedForTesting(
            worktreeID: wtID,
            status: PRStatus(number: 5, url: "https://github.com/acme/acme-prod/pull/5", state: .mergeable))
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            prManager: manager,
            actuationLog: makeTestActuationLog())

        // No gh available in the test environment's sandbox → the refresh
        // cannot resolve, keeps the cached value, and says the attempt failed.
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.prRefresh, params: PRRefreshParams(worktreeID: wtID)))
        let result = try response.decodeResult(PRRefreshResult.self)

        #expect(result.status?.number == 5, "the retained value is still the newest anyone has")
        let outcome = try #require(result.observation?.outcome)
        if case .undetermined = outcome {} else {
            Issue.record("expected the unresolved attempt to be .undetermined, observed \(outcome)")
        }
        #expect(outcome != PRObservation.Outcome.none)
    }

    @Test("pr.refresh for an unknown worktree reports no observation at all")
    func prRefreshOnUnknownWorktreeReportsNoAttempt() async throws {
        let (db, _) = try await Self.makeDB()
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            actuationLog: makeTestActuationLog())

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.prRefresh, params: PRRefreshParams(worktreeID: UUID())))
        let result = try response.decodeResult(PRRefreshResult.self)

        #expect(result.status == nil)
        #expect(result.observation == nil, "no attempt was made — which is neither outcome")
    }
}

/// The `pr.list` result as a daemon that predates `observations` encodes it.
private struct LegacyPRListResult: Encodable {
    let statuses: [UUID: PRStatus]
}
