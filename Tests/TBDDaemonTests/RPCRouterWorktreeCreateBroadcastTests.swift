import Foundation
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
        setenv("TBD_HOME", home.path, 1)
        return (home, {
            unsetenv("TBD_HOME")
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
            subscriptions: subs
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

    /// Polls `condition` until it returns true or the deadline passes.
    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: @Sendable () async throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try await condition()
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

        // Background phase 2 runs on the repo serializer; wait for the flip.
        let activated = try await waitUntil {
            try await db.worktrees.get(id: pending.id)?.status == .active
        }
        #expect(activated, "background create must complete")

        let created = deltas.snapshot().filter {
            if case .worktreeCreated(let d) = $0 { return d.worktreeID == pending.id }
            return false
        }
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
        let hookSpawned = try await waitUntil {
            try await db.terminals.list(worktreeID: pending.id)
                .contains { $0.label == "pre-session" }
        }
        #expect(hookSpawned, "phase 2 must spawn the pre-session terminal")

        // Finish the hook and wait for the detached phase 3 to activate the row.
        try writeMarker(worktreeID: pending.id, exitCode: 0)
        let activated = try await waitUntil {
            try await db.worktrees.get(id: pending.id)?.status == .active
        }
        #expect(activated, "phase 3 must flip the row to .active")

        let created = deltas.snapshot().filter {
            if case .worktreeCreated(let d) = $0 { return d.worktreeID == pending.id }
            return false
        }
        #expect(created.count == 1,
                ".preSessionPending must produce exactly one .worktreeCreated total (no handler duplicate)")
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
