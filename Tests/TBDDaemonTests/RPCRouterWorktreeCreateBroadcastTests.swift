import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: hook resolution and the pre-session
// completion marker live under TBD_HOME, so these tests redirect it to a
// temp dir (see TBDHomeSerializedSuites.swift).
extension TBDHomeSerialized {
/// Handler-level coverage for `handleWorktreeCreate`'s broadcast gate: the
/// `.ready` completion is broadcast by the handler itself, while the
/// `.preSessionPending` completion was already broadcast early by the
/// lifecycle — the handler must NOT broadcast a duplicate.
@Suite("worktree.create handler broadcast gate")
struct RPCRouterWorktreeCreateBroadcastTests {

    private func isolateTBDHome() -> (home: URL, cleanup: () -> Void) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-create-broadcast-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(home.path)
        return (home, {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: home)
        })
    }

    /// Router whose lifecycle and handlers share one StateSubscriptionManager,
    /// with every broadcast delta captured in `deltas`.
    private func makeRouter(db: TBDDatabase) -> (router: RPCRouter, deltas: BroadcastDeltas) {
        let deltas = BroadcastDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver(),
            subscriptions: subs,
            preSessionPollInterval: 0.05
        )
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: TmuxManager(dryRun: true),
            subscriptions: subs,
            actuationLog: makeTestActuationLog()
        )
        return (router, deltas)
    }

    private func installPreSessionHook(repoDir: URL) async throws {
        let hooksDir = repoDir.appendingPathComponent(".worktree-hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let hookPath = hooksDir.appendingPathComponent("preSession")
        try "#!/bin/sh\nexit 0\n".write(to: hookPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hookPath.path
        )
        try await shell("git add -A && git commit -m 'add preSession hook'", at: repoDir)
    }

    private func writeMarker(worktreeID: UUID, exitCode: Int) throws {
        let path = WorktreeLifecycle.preSessionMarkerPath(worktreeID: worktreeID)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "\(exitCode)\n".write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Polls `condition` through `pollUntilTrue` until it holds, on the shared
    /// saturated-pass budget rather than a literal: what these wait for is
    /// produced by a detached task no test owns, which SE-0417 leaves on the
    /// cooperative pool behind the whole fast pass — see `gateHoldingTask` in
    /// `Tests/TestSupport/BoundedGateSupport.swift`.
    ///
    /// A timeout is recorded as a `BoundedWaitTimeout` carrying what `observed`
    /// read and how long the wait took, so the diagnostic reaches the CI
    /// summary (Tests/CLAUDE.md, assertion-hygiene rule 4), and returns false.
    /// `observed` is read before one last check of `condition`, so an event
    /// that lands while the diagnostic is composed passes instead of printing
    /// a contradiction. Cancellation throws: the harness ended the test, and
    /// no timeout is invented for it.
    private func waitUntil(
        _ what: String,
        observed: @Sendable () async -> String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @Sendable () async -> Bool
    ) async throws -> Bool {
        let start = ContinuousClock.now
        let outcome = await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(50), condition)
        switch outcome {
        case .satisfied:
            return true
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            let seen = await observed()
            if await condition() { return true }
            let elapsed = ContinuousClock.now - start
            Issue.record(
                BoundedWaitTimeout(
                    what: what, observed: "\(seen) (waited \(elapsed))",
                    deadline: TestDeadlines.saturatedPass),
                sourceLocation: sourceLocation)
            return false
        }
    }

    /// The `.worktreeCreated` deltas broadcast for `worktreeID`.
    private static func createdDeltas(_ deltas: [StateDelta], for worktreeID: UUID) -> [StateDelta] {
        deltas.filter {
            if case .worktreeCreated(let d) = $0 { return d.worktreeID == worktreeID }
            return false
        }
    }

    /// The broadcast deltas as a diagnostic reads them: each case's name, in
    /// order.
    private static func describe(_ deltas: [StateDelta]) -> String {
        let names = deltas.map { delta in String(String(describing: delta).prefix { $0 != "(" }) }
        return "\(deltas.count) delta(s) \(names)"
    }

    /// The worktree row's status as a diagnostic reads it.
    private static func describeRow(db: TBDDatabase, id: UUID) async -> String {
        do {
            guard let row = try await db.worktrees.get(id: id) else { return "no row" }
            return "row status \(row.status)"
        } catch {
            return "row read failed: \(error)"
        }
    }

    @Test func readyCompletionBroadcastsExactlyOneWorktreeCreated() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // No preSession hook → phase 2 completes `.ready` and the HANDLER
        // broadcasts `.worktreeCreated`.
        let request = try RPCRequest(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repo.id)
        )
        let response = await router.handle(request)
        #expect(response.success)
        let pending = try response.decodeResult(Worktree.self)
        #expect(pending.status == .creating)

        // Background phase 2 runs on the repo serializer. Wait for the
        // broadcast itself, not for the row: the lifecycle sets the row
        // `.active` and returns `.ready`, and only then does the handler
        // re-read the row and broadcast, so an `.active` row does not yet mean
        // the broadcast has happened.
        let broadcast = try await waitUntil(
            "the handler's .worktreeCreated broadcast",
            observed: {
                let row = await Self.describeRow(db: db, id: pending.id)
                return "\(row); \(Self.describe(deltas.snapshot()))"
            }
        ) {
            !Self.createdDeltas(deltas.snapshot(), for: pending.id).isEmpty
        }
        #expect(broadcast, "background create must complete and broadcast")

        let row = try await db.worktrees.get(id: pending.id)
        #expect(row?.status == .active, "the row is active before the handler broadcasts")

        let created = Self.createdDeltas(deltas.snapshot(), for: pending.id)
        #expect(created.count == 1,
                ".ready completion must produce exactly one .worktreeCreated broadcast")
    }

    @Test func preSessionPendingCompletionBroadcastsExactlyOneWorktreeCreated() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        // preSession hook present → the lifecycle broadcasts `.worktreeCreated`
        // early; the handler's `.preSessionPending` branch must NOT duplicate it.
        let request = try RPCRequest(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repo.id)
        )
        let response = await router.handle(request)
        #expect(response.success)
        let pending = try response.decodeResult(Worktree.self)

        // Wait for phase 2 to spawn the pre-session terminal (the marker file
        // is wiped at spawn, so writing it after this point is race-free).
        let hookSpawned = try await waitUntil(
            "phase 2 to spawn the pre-session terminal",
            observed: {
                guard let terminals = try? await db.terminals.list(worktreeID: pending.id) else {
                    return "terminal list read failed"
                }
                return "terminal labels \(terminals.map { $0.label })"
            }
        ) {
            let terminals = try? await db.terminals.list(worktreeID: pending.id)
            return terminals?.contains { $0.label == "pre-session" } == true
        }
        #expect(hookSpawned, "phase 2 must spawn the pre-session terminal")

        // Finish the hook and wait for the detached phase 3 to activate the row.
        try writeMarker(worktreeID: pending.id, exitCode: 0)
        let activated = try await waitUntil(
            "phase 3 to flip the row to .active",
            observed: { await Self.describeRow(db: db, id: pending.id) }
        ) {
            (try? await db.worktrees.get(id: pending.id))?.status == .active
        }
        #expect(activated, "phase 3 must flip the row to .active")

        let created = Self.createdDeltas(deltas.snapshot(), for: pending.id)
        #expect(created.count == 1,
                ".preSessionPending must produce exactly one .worktreeCreated total (no handler duplicate)")
    }

    // Branching-conditional coverage (CLAUDE.md): the handler arms the
    // per-worktree auto-archive-on-merge override only when the param is
    // non-nil. Both branches are asserted below.

    @Test func createWithAutoArchiveTrueArmsOverride() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let request = try RPCRequest(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repo.id, autoArchiveOnMerge: true)
        )
        let response = await router.handle(request)
        #expect(response.success)
        let pending = try response.decodeResult(Worktree.self)

        let row = try #require(try await db.worktrees.get(id: pending.id))
        #expect(row.autoArchiveOnMerge == true)
    }

    @Test func createWithoutAutoArchiveLeavesOverrideNil() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // Omitted (nil) → the row follows the global default (override unset).
        let request = try RPCRequest(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repo.id)
        )
        let response = await router.handle(request)
        #expect(response.success)
        let pending = try response.decodeResult(Worktree.self)

        let row = try #require(try await db.worktrees.get(id: pending.id))
        #expect(row.autoArchiveOnMerge == nil)
    }

    /// A creation that fails in the background with a first message parked in
    /// its row: the handler's rollback saves the message under the (fenced)
    /// `TBD_HOME` and the failure broadcast names the file.
    @Test func failedCreateWithAParkedPromptBroadcastsTheSavedPath() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // Hold the repo's lane so phase 2 cannot start until the prompt is
        // parked and the repo is broken.
        let gate = AsyncStream<Void>.makeStream()
        await router.repoSerializer.submit(repoID: repo.id) {
            for await _ in gate.stream { break }
        }

        let request = try RPCRequest(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repo.id)
        )
        let response = await router.handle(request)
        #expect(response.success)
        let pending = try response.decodeResult(Worktree.self)

        try await db.worktrees.setPendingPrompt(
            worktreeID: pending.id, text: "the parked first message", submit: true)
        // No repository left at the path for `git worktree add` to work in.
        // Moved rather than removed: git leaves read-only objects behind.
        try FileManager.default.moveItem(
            at: repoDir, to: tempDir.appendingPathComponent("moved-away", isDirectory: true))
        gate.continuation.yield(())
        gate.continuation.finish()

        let failed = try await waitUntil(
            "the background create's failure broadcast",
            observed: { Self.describe(deltas.snapshot()) }
        ) {
            deltas.snapshot().contains {
                if case .worktreeArchived(let d) = $0 { return d.worktreeID == pending.id }
                return false
            }
        }
        #expect(failed, "the background create must fail and broadcast")

        let delta = try #require(deltas.snapshot().compactMap { delta -> WorktreeIDDelta? in
            if case .worktreeArchived(let d) = delta, d.worktreeID == pending.id { return d }
            return nil
        }.first)
        #expect(delta.creationFailed)
        let path = try #require(delta.unsentPromptPath)
        #expect(path.hasPrefix(TBDConstants.unsentPromptsDir(repoID: repo.id).path + "/"))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "the parked first message\n")
        #expect(try await db.worktrees.get(id: pending.id) == nil)
    }
}
}

/// Thread-safe collector for broadcast StateDeltas.
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
