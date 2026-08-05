import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Thread-safe collector for broadcast StateDeltas, mirroring the pattern in
/// `RPCRouterWorktreeCreateBroadcastTests` / `OrphanGCTests`.
private final class BroadcastDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }
}

/// Router-level coverage for Task 9: `gc.list` / `gc.restore` / `gc.sweepNow`
/// / `config.setGCEnabled`.
@Suite("GC RPC handlers")
struct GCHandlersTests {
    /// Router construction mirrors `RPCRouterTests` / `ControlModeSettingsRPCTests`
    /// (in-memory DB, dry-run tmux). Callers that need `orphanGC` wired set
    /// `router.orphanGC` afterward, the same post-construction seam
    /// `Daemon.swift` uses for `claudeUsagePoller`.
    private func makeRouter(db: TBDDatabase, subscriptions: StateSubscriptionManager = StateSubscriptionManager())
        -> RPCRouter
    {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subscriptions,
            actuationLog: makeTestActuationLog()
        )
    }

    private func makeGC(db: TBDDatabase, broadcaster: BroadcastDeltas, now: @escaping @Sendable () -> Date = Date.init) -> OrphanGC {
        OrphanGC(
            db: db,
            git: GitManager(),
            broadcast: { broadcaster.append($0) },
            lsofProvider: { [] },
            now: now
        )
    }

    @discardableResult
    private func makeAgentWorktree(repo: URL, name: String, branch: String? = nil) async throws -> String {
        try await shell("mkdir -p .claude/worktrees", at: repo)
        try await shell("git worktree add .claude/worktrees/\(name) -b \(branch ?? name)", at: repo)
        guard let cReal = realpath(repo.path + "/.claude/worktrees/" + name, nil) else {
            return repo.path + "/.claude/worktrees/" + name
        }
        defer { free(cReal) }
        return String(cString: cReal)
    }

    // MARK: - gc.list

    @Test("gc.list returns inserted records")
    func listReturnsInsertedRecords() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db)

        let record = ReapRecord(
            kind: .agentWorktree, repoPath: "/tmp/gc-list-repo", worktreePath: "/tmp/gc-list-repo/wt-a"
        )
        try await db.reapRecords.insert(record)

        let request = try RPCRequest(method: RPCMethod.gcList, params: GCListParams())
        let response = await router.handle(request)
        #expect(response.success)
        let records = try response.decodeResult([ReapRecord].self)
        #expect(records.count == 1)
        #expect(records.first?.id == record.id)
    }

    @Test("gc.list honors the repoPath filter")
    func listHonorsRepoPathFilter() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db)

        let matching = ReapRecord(
            kind: .agentWorktree, repoPath: "/tmp/gc-filter-a", worktreePath: "/tmp/gc-filter-a/wt-a"
        )
        let other = ReapRecord(
            kind: .agentWorktree, repoPath: "/tmp/gc-filter-b", worktreePath: "/tmp/gc-filter-b/wt-b"
        )
        try await db.reapRecords.insert(matching)
        try await db.reapRecords.insert(other)

        let request = try RPCRequest(method: RPCMethod.gcList, params: GCListParams(repoPath: "/tmp/gc-filter-a"))
        let response = await router.handle(request)
        #expect(response.success)
        let records = try response.decodeResult([ReapRecord].self)
        #expect(records.count == 1)
        #expect(records.first?.id == matching.id)
    }

    // MARK: - gc.sweepNow

    @Test("gc.sweepNow dryRun=true returns non-empty planned and mutates nothing")
    func sweepNowDryRunPlansWithoutMutating() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        _ = try await db.repos.create(path: repo.path, displayName: "acme", defaultBranch: "main")
        let wtPath = try await makeAgentWorktree(repo: repo, name: "agent-x")

        let router = makeRouter(db: db)
        let broadcaster = BroadcastDeltas()
        // Far-future `now` clears the default grace window so the freshly
        // created worktree above is immediately eligible.
        router.orphanGC = makeGC(db: db, broadcaster: broadcaster, now: { Date().addingTimeInterval(3 * 3600) })

        let request = try RPCRequest(method: RPCMethod.gcSweepNow, params: GCSweepNowParams(dryRun: true))
        let response = await router.handle(request)
        #expect(response.success)
        let result = try response.decodeResult(GCSweepResult.self)

        #expect(!result.planned.isEmpty)
        #expect(result.planned.contains { $0.contains("REAP agent-worktree") && $0.contains(wtPath) })
        #expect(result.reaped == 0)
        #expect(FileManager.default.fileExists(atPath: wtPath), "dry run must not touch disk")

        let records = try await db.reapRecords.list(repoPath: nil)
        #expect(records.isEmpty, "dry run must not mutate the DB")
    }

    @Test("gc.sweepNow returns an error when orphanGC is unavailable (mock mode)")
    func sweepNowUnavailableWhenOrphanGCNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db)
        // router.orphanGC left nil, mirroring mock mode.

        let request = try RPCRequest(method: RPCMethod.gcSweepNow, params: GCSweepNowParams(dryRun: true))
        let response = await router.handle(request)
        #expect(!response.success)
        #expect(response.error != nil)
    }

    // MARK: - gc.restore

    @Test("gc.restore round-trips a reaped record")
    func restoreRoundTrips() async throws {
        let (tmp, repo) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = try TBDDatabase(inMemory: true)
        _ = try await db.repos.create(path: repo.path, displayName: "acme", defaultBranch: "main")
        let wtPath = try await makeAgentWorktree(repo: repo, name: "agent-x")

        let router = makeRouter(db: db)
        let broadcaster = BroadcastDeltas()
        let gc = makeGC(db: db, broadcaster: broadcaster, now: { Date().addingTimeInterval(3 * 3600) })
        router.orphanGC = gc

        // Reap for real via the actor directly (not via RPC — sweepNow's own
        // reap path is covered by OrphanGCTests) so restore has a record to
        // round-trip.
        let sweepResult = await gc.sweep()
        #expect(sweepResult.reaped == 1)
        #expect(!FileManager.default.fileExists(atPath: wtPath))

        let record = try #require(try await db.reapRecords.list(repoPath: nil).first)

        let request = try RPCRequest(method: RPCMethod.gcRestore, params: GCRestoreParams(recordID: record.id))
        let response = await router.handle(request)
        #expect(response.success)

        #expect(FileManager.default.fileExists(atPath: wtPath))
        let restored = try await db.reapRecords.get(id: record.id)
        #expect(restored?.restoredAt != nil)
    }

    @Test("gc.restore returns an error when orphanGC is unavailable (mock mode)")
    func restoreUnavailableWhenOrphanGCNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db: db)

        let request = try RPCRequest(method: RPCMethod.gcRestore, params: GCRestoreParams(recordID: UUID()))
        let response = await router.handle(request)
        #expect(!response.success)
        #expect(response.error != nil)
    }

    // MARK: - config.setGCEnabled

    @Test("config.setGCEnabled flips the config and broadcasts")
    func setGCEnabledFlipsConfigAndBroadcasts() async throws {
        let db = try TBDDatabase(inMemory: true)
        let subs = StateSubscriptionManager()
        let deltas = BroadcastDeltas()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let router = makeRouter(db: db, subscriptions: subs)

        #expect(try await db.config.get().gcEnabled == true, "default is enabled")

        let request = try RPCRequest(method: RPCMethod.configSetGCEnabled, params: ConfigSetGCEnabledParams(enabled: false))
        let response = await router.handle(request)
        #expect(response.success)

        #expect(try await db.config.get().gcEnabled == false)
        let modelProfilesChangedCount = deltas.snapshot().filter {
            if case .modelProfilesChanged = $0 { return true }; return false
        }.count
        #expect(modelProfilesChangedCount == 1)

        // Flip back on to also exercise the true branch end-to-end.
        let request2 = try RPCRequest(method: RPCMethod.configSetGCEnabled, params: ConfigSetGCEnabledParams(enabled: true))
        let response2 = await router.handle(request2)
        #expect(response2.success)
        #expect(try await db.config.get().gcEnabled == true)
    }
}
