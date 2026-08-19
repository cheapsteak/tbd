import Clocks
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 1 (docs/specs/2026-07-24-test-hardening-design.md §3): in-process,
// deterministic, driven entirely by virtual time. The only real sleeping is the
// scheduling handshake inside `advanceWhenSuspended`.
//
// DEFECT UNDER TEST: PR facts are a side effect of an app being open. Before
// `PRPoller`, `PRStatusManager.fetchAll` ran only inside the `pr.list` RPC
// handler, so the moment the app stopped polling — overnight, which is exactly
// when a fleet supervisor needs them — nothing learned anything about any pull
// request. A regression here is silent: every existing test drives `fetchAll`
// directly or through the RPC, so a poller that never fires would keep them all
// green.
//
// The second thing these tests defend is that exactly ONE driver runs the
// periodic fetch. The merged-PR transition is edge-triggered on a cache change,
// so a second driver would race for the edge and the loser's consumers
// (auto-archive, auto-hibernate-on-merge) would silently stop firing. `pr.list`
// is that second driver's obvious hiding place, so it gets its own test.

/// A `gh` stand-in that counts viewer-batch queries and answers with a fixed
/// node list. `acme/acme-prod` is a placeholder, as everywhere in this suite.
private actor CountingGH {
    private let nodes: [String]
    private(set) var viewerQueries = 0

    init(nodes: [String] = []) {
        self.nodes = nodes
    }

    func run(args: [String], repoPath: String) -> GHCommandResult? {
        if args.first == "repo" { return GHCommandResult(stdout: #"{"nameWithOwner":"acme/acme-prod","url":"https://github.com/acme/acme-prod"}"#) }
        guard let query = args.first(where: { $0.hasPrefix("query=") }) else { return nil }
        guard query.contains("viewer {") else { return nil }
        viewerQueries += 1
        return GHCommandResult(
            stdout: #"{"data":{"viewer":{"pullRequests":{"nodes":[\#(nodes.joined(separator: ","))]}}}}"#)
    }
}

/// Records every merged transition the manager fired.
private actor MergedRecorder {
    private(set) var transitions: [(id: UUID, number: Int)] = []
    func record(_ id: UUID, _ number: Int) { transitions.append((id, number)) }
    var count: Int { transitions.count }
}

@Suite(.clockDriven, .serialized)
struct PRPollerTests {

    /// Injected pacing, not production values: with a 150s tick the foreground
    /// cadence (30s) is due after one advance and the background cadence (300s)
    /// after two, so both thresholds are crossed inside a single-digit chain
    /// while still being the real `GitPollCadence` numbers.
    private static let tick: Duration = .seconds(150)

    private static func nodeJSON(number: Int, head: String, state: String = "OPEN") -> String {
        """
        {"number": \(number), "url": "https://github.com/acme/acme-prod/pull/\(number)",
         "state": "\(state)", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED",
         "headRefName": "\(head)", "createdAt": "2026-07-01T00:00:00Z", "isDraft": false,
         "statusCheckRollup": {"state": "SUCCESS"}}
        """
    }

    /// A DB holding one active worktree on branch `tbd/w`, plus its repo.
    private static func makeDB() async throws -> (db: TBDDatabase, worktreeID: UUID) {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/repoPRP-\(UUID().uuidString)", displayName: "repoPRP", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "tbd/w",
            path: "/tmp/repoPRP/w-\(UUID().uuidString)", tmuxServer: "s")
        return (db, wt.id)
    }

    /// A router carrying the manager under test. It owns the poll pass — the
    /// enumeration helpers are shared with `pr.refresh`, so they cannot move
    /// into the poller — and its own `prPoller` is never started, so nothing but
    /// the poller built below drives anything.
    private static func makeRouter(db: TBDDatabase, manager: PRStatusManager) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            prManager: manager,
            actuationLog: makeTestActuationLog())
    }

    /// A poller on injected pacing, driving `router`'s real pass. Everything
    /// these tests assert — cadence, one driver, the prune — is a property of
    /// the timer around that pass, so the pass itself stays the production one.
    private static func makePoller(
        router: RPCRouter,
        isForeground: @escaping @Sendable () async -> Bool,
        clock: any Clock<Duration>
    ) -> PRPoller {
        let poller = PRPoller(
            isForeground: isForeground,
            pollTick: Self.tick,
            clock: clock)
        poller.installPass { try await router.runPollPass() }
        return poller
    }

    // MARK: - The loop runs on the daemon's clock, with no app

    @Test("the poller fetches on its own clock with no app connected")
    func fetchesWithNoAppConnected() async throws {
        // `isForeground` returns false exactly as it does when no client is
        // connected (GitPollCadence.isEffectivelyForeground), so this is the
        // overnight case: nothing is polling `pr.list`, and the facts must
        // still arrive.
        let (db, wtID) = try await Self.makeDB()
        let gh = CountingGH(nodes: [Self.nodeJSON(number: 41, head: "tbd/w")])
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        let clock = TestClock<Duration>()
        let poller = Self.makePoller(
            router: Self.makeRouter(db: db, manager: manager),
            isForeground: { false }, clock: clock)

        await poller.start()
        // 300s background cadence, 150s tick: due on the second advance.
        await clock.advanceWhenSuspended(by: Self.tick)
        await clock.advanceWhenSuspended(by: Self.tick)
        await clock.waitForSuspension()

        let queries = await gh.viewerQueries
        #expect(queries == 1, "expected 1 daemon-driven fetch with no app connected, observed \(queries)")
        #expect(await manager.allStatuses()[wtID]?.number == 41)
        await poller.stop()
    }

    @Test("the poller honors the foreground cadence")
    func honorsForegroundCadence() async throws {
        // Same clock, same tick, opposite gate: 30s foreground is due after the
        // FIRST advance, where 300s background was not.
        let (db, _) = try await Self.makeDB()
        let gh = CountingGH()
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        let clock = TestClock<Duration>()
        let poller = Self.makePoller(
            router: Self.makeRouter(db: db, manager: manager),
            isForeground: { true }, clock: clock)

        await poller.start()
        await clock.advanceWhenSuspended(by: Self.tick)
        await clock.waitForSuspension()

        let queries = await gh.viewerQueries
        #expect(queries == 1, "expected the 30s foreground cadence to be due after one 150s tick, observed \(queries) fetches")
        await poller.stop()
    }

    @Test("the background cadence is not due after one tick")
    func backgroundCadenceIsNotDueEarly() async throws {
        // The falsifying half of the cadence pair: without it, a poller that
        // ignored the gate entirely and fired every tick would pass the two
        // tests above.
        let (db, _) = try await Self.makeDB()
        let gh = CountingGH()
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        let clock = TestClock<Duration>()
        let poller = Self.makePoller(
            router: Self.makeRouter(db: db, manager: manager),
            isForeground: { false }, clock: clock)

        await poller.start()
        await clock.advanceWhenSuspended(by: Self.tick)
        await clock.waitForSuspension()

        let early = await gh.viewerQueries
        #expect(early == 0, "150s waited against the 300s background cadence should not have fetched; observed \(early)")

        await clock.advanceWhenSuspended(by: Self.tick)
        await clock.waitForSuspension()
        let after = await gh.viewerQueries
        #expect(after == 1, "the 300s background cadence should be due after two 150s ticks, observed \(after)")
        await poller.stop()
    }

    // MARK: - One owner for the merged-transition edge

    @Test("the merged transition fires exactly once across repeated polls")
    func mergedTransitionFiresOnce() async throws {
        // The edge is owned by `PRStatusManager.apply`, and moving the clock
        // must not change that: a second poll of the same merged PR observes no
        // new edge.
        let (db, wtID) = try await Self.makeDB()
        let gh = CountingGH(nodes: [Self.nodeJSON(number: 77, head: "tbd/w", state: "MERGED")])
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        let recorder = MergedRecorder()
        await manager.setOnMergedTransition { id, number in await recorder.record(id, number) }
        let poller = Self.makePoller(
            router: Self.makeRouter(db: db, manager: manager),
            isForeground: { true }, clock: TestClock<Duration>())

        await poller.tick()
        await poller.tick()

        let transitions = await recorder.transitions
        #expect(transitions.count == 1, "expected exactly 1 merged transition, observed \(transitions.count)")
        #expect(transitions.first?.id == wtID)
        #expect(transitions.first?.number == 77)
    }

    @Test("pr.list serves the snapshot and cannot swallow the edge")
    func prListDoesNotFetchWhilePollDrives() async throws {
        // The split that would silently break auto-archive: if `pr.list` also
        // fetched, whichever driver landed first would consume the edge and the
        // other's consumers would never fire. `pr.list` performs no fetch at all
        // — so the transition is the poller's, exactly once, and the RPC still
        // reports it.
        let (db, wtID) = try await Self.makeDB()
        let gh = CountingGH(nodes: [Self.nodeJSON(number: 77, head: "tbd/w", state: "MERGED")])
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        let recorder = MergedRecorder()
        await manager.setOnMergedTransition { id, number in await recorder.record(id, number) }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            prManager: manager,
            actuationLog: makeTestActuationLog())

        // `pr.list` first: it must not fetch, so nothing is learned yet.
        let beforeResponse = await router.handle(RPCRequest(method: RPCMethod.prList))
        #expect(beforeResponse.success)
        let before = try beforeResponse.decodeResult(PRListResult.self)
        #expect(before.statuses.isEmpty)
        #expect(await gh.viewerQueries == 0, "pr.list must not fetch while the daemon clock owns the poll")

        // Now the poller's tick supplies the fact — and the edge.
        await router.prPoller.tick()
        let afterResponse = await router.handle(RPCRequest(method: RPCMethod.prList))
        let after = try afterResponse.decodeResult(PRListResult.self)

        #expect(after.statuses[wtID]?.state == .merged)
        #expect(await recorder.count == 1)
        #expect(await gh.viewerQueries == 1, "exactly one driver should have fetched")
    }

    @Test("repeated pr.list calls neither fetch nor re-fire the edge")
    func repeatedPRListNeitherFetchesNorRefires() async throws {
        // The falsifying half of the pair above. `prListDoesNotFetchWhilePollDrives`
        // would still pass if `pr.list` fetched only on calls after the first;
        // this drives it repeatedly, before and after the one tick that supplies
        // the fact, and pins the fetch count and the edge count to exactly one.
        let (db, wtID) = try await Self.makeDB()
        let gh = CountingGH(nodes: [Self.nodeJSON(number: 77, head: "tbd/w", state: "MERGED")])
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        let recorder = MergedRecorder()
        await manager.setOnMergedTransition { id, number in await recorder.record(id, number) }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            prManager: manager,
            actuationLog: makeTestActuationLog())

        for _ in 0..<3 {
            _ = await router.handle(RPCRequest(method: RPCMethod.prList))
        }
        let beforeFetches = await gh.viewerQueries
        #expect(beforeFetches == 0, "pr.list must never fetch; observed \(beforeFetches) fetches over 3 calls")
        #expect(await recorder.count == 0)

        await router.prPoller.tick()

        for _ in 0..<3 {
            _ = await router.handle(RPCRequest(method: RPCMethod.prList))
        }
        let response = await router.handle(RPCRequest(method: RPCMethod.prList))
        let result = try response.decodeResult(PRListResult.self)

        #expect(result.statuses[wtID]?.state == .merged)
        let fetches = await gh.viewerQueries
        #expect(fetches == 1, "only the poller's single tick should have fetched, observed \(fetches)")
        let count = await recorder.count
        #expect(count == 1, "expected exactly 1 merged transition, observed \(count)")
    }

    // MARK: - The prune happens on every pass, including the empty one

    /// `fetchOnce` used to return early when the enumeration came back empty,
    /// taking the branch-cache prune with it — a silent behavior change from
    /// the extraction, since the `computePRList` it replaced pruned
    /// unconditionally. The empty pass is the one with the most to drop: it is
    /// what a fleet that has just been archived wholesale looks like.
    @Test("a pass with nothing to poll still prunes the branch cache")
    func anEmptyPassStillPrunesTheBranchCache() async throws {
        let (db, wtID) = try await Self.makeDB()
        try await db.worktrees.updateStatus(id: wtID, status: .archived)
        let fetches = CallCounter()
        let router = Self.makeRouter(db: db, manager: PRStatusManager(ghRunner: { _, _ in nil }))
        let cache = router.branchTrackingCache
        let poller = Self.makePoller(
            router: router, isForeground: { false }, clock: TestClock<Duration>())

        // Prime an entry for a worktree that is about to leave the poll set.
        _ = await cache.upstreamBranchName(worktreePath: "/gone", branch: "tbd/w") {
            await fetches.bump(); return "main"
        }
        #expect(await fetches.count == 1)

        try await poller.fetchOnce()

        // A cache miss — i.e. the entry was pruned — makes the fetch run again.
        _ = await cache.upstreamBranchName(worktreePath: "/gone", branch: "tbd/w") {
            await fetches.bump(); return "main"
        }
        #expect(await fetches.count == 2,
                "the pass kept the branch cache of a fleet that no longer exists")
    }

    /// The same contract for the PR facts themselves, and the wiring that makes
    /// `PRStatusManager.retain` more than a method nobody calls.
    ///
    /// The persisted side is already bounded — `allPRObservations` reads
    /// unarchived rows only, so a restarted daemon hydrates active worktrees and
    /// nothing else. A running daemon has to hold the same shape, or an outcome
    /// recorded while a worktree was active outlives its archival for the life
    /// of the process and rides in every 30-second `pr.list` payload.
    @Test("a worktree that left the fleet does not keep its recorded outcome")
    func anArchivedWorktreesRecordedOutcomeIsDroppedByThePass() async throws {
        let (db, wtID) = try await Self.makeDB()
        let gh = CountingGH()   // the forge answers, with no pull requests
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        let poller = Self.makePoller(
            router: Self.makeRouter(db: db, manager: manager),
            isForeground: { false }, clock: TestClock<Duration>())

        try await poller.fetchOnce()
        #expect(await manager.observation(for: wtID) != nil,
                "the pass recorded no outcome for an active worktree, so this case proves nothing")

        try await db.worktrees.updateStatus(id: wtID, status: .archived)
        try await poller.fetchOnce()

        #expect(await manager.observation(for: wtID) == nil,
                "the outcome of an attempt on an archived worktree outlived it")
    }
}

/// Counts how many times a cache miss reached the underlying fetch.
private actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
