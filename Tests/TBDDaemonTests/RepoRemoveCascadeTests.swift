import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// Thread-safe `StateDelta` collector, matching the other RPC suites.
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
    func containsRepoRemoved(_ repoID: UUID) -> Bool {
        snapshot().contains {
            if case .repoRemoved(let delta) = $0 { return delta.repoID == repoID }
            return false
        }
    }
}

/// Parks `completeArchiveWorktree` at a known point, per worktree path.
///
/// Wired through `WorktreeLifecycle.onWorktreeRemoved`, which phase 2 awaits
/// after the deletion-queue rename and before the drain — i.e. squarely inside
/// the "archive still in flight" window these tests are about. Waiting is
/// bounded rather than indefinite on purpose: if the cleanup tail were
/// synchronous again, `router.handle` would park here, and a bounded wait turns
/// that into a clean assertion failure a few seconds later instead of a hang.
private final class PathGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: Set<String> = []
    private var entered: [String] = []

    func open(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        opened.insert(path)
    }

    func enteredPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return entered
    }

    private func isOpen(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return opened.contains(path)
    }

    func wait(_ path: String, timeout: TimeInterval = 10) async {
        lock.withLock { entered.append(path) }
        let deadline = Date().addingTimeInterval(timeout)
        while !isOpen(path), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Carries the observed state on the primary failure line (assertion-hygiene
/// rule 4: only `Issue.record(_: some Error)` — which a thrown error becomes —
/// survives into the CI summary).
private struct CascadeWaitTimeout: Error, CustomStringConvertible {
    let what: String
    let observed: String
    let seconds: TimeInterval
    var description: String {
        "timed out waiting for \(what) — observed \(observed) after polling up to \(seconds) seconds"
    }
}

@Suite("repo.remove cascade cleanup ordering")
struct RepoRemoveCascadeTests {

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 10,
        observed: @Sendable () async -> String = { "still false" },
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Fresh read before giving up: the loop tests the deadline before the
        // condition, so its last sample is up to `timeout` old, and a poller
        // whose 10 ms step aside returns its turn late under the fast parallel
        // pass would otherwise throw a timeout at a condition that already
        // holds. Same re-read as `SidecarTestSupport.waitUntil`.
        if await condition() { return }
        throw CascadeWaitTimeout(what: what, observed: await observed(), seconds: timeout)
    }

    /// Router sharing one `StateSubscriptionManager` with its lifecycle, with
    /// every broadcast delta captured. `gate`, when supplied, parks phase 2 of
    /// each archive at `onWorktreeRemoved`.
    private func makeRouter(
        db: TBDDatabase, gate: PathGate? = nil
    ) -> (router: RPCRouter, deltas: BroadcastDeltas) {
        let deltas = BroadcastDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver())
        if let gate {
            lifecycle.onWorktreeRemoved = { path, _ in await gate.wait(path) }
        }
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: TmuxManager(dryRun: true),
            subscriptions: subs, actuationLog: makeTestActuationLog())
        return (router, deltas)
    }

    /// A real directory holding a file, so the deletion queue's `rename(2)`
    /// succeeds and phase 2 reaches `onWorktreeRemoved` on its success path.
    private func makeActiveWorktree(
        db: TBDDatabase, repoID: UUID, sandbox: URL, name: String
    ) async throws -> Worktree {
        let path = sandbox.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try "content".write(toFile: path + "/file.txt", atomically: true, encoding: .utf8)
        return try await db.worktrees.create(
            repoID: repoID, name: name, branch: name, path: path, tmuxServer: "tbd-test")
    }

    private func makeSandbox() throws -> URL {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("repo-remove-cascade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox
    }

    /// Branch 1 of the gating conditional: no active worktrees, so there is
    /// nothing to await and the tail must stay inline. The RPC may not return
    /// until the rows are deleted and `.repoRemoved` has been broadcast.
    @Test func removalWithoutACascadeFinishesBeforeTheRPCReturns() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let repo = try await db.repos.create(
            path: sandbox.appendingPathComponent("repo").path,
            displayName: "acme", defaultBranch: "main")
        // An archived row: still deleted by the tail, but it puts no archive in
        // flight, so this stays the no-cascade branch.
        let archived = try await makeActiveWorktree(
            db: db, repoID: repo.id, sandbox: sandbox, name: "already-archived")
        try await db.worktrees.archive(id: archived.id)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.repoRemove, params: RepoRemoveParams(repoID: repo.id, force: true)))
        #expect(response.success)

        // Asserted with no intervening wait: the work has to be done already.
        #expect(deltas.containsRepoRemoved(repo.id),
                "the no-cascade path must broadcast .repoRemoved before returning")
        let repoRow = try await db.repos.get(id: repo.id)
        #expect(repoRow == nil, "the no-cascade path must delete the repo row before returning")
        let worktreeRow = try await db.worktrees.get(id: archived.id)
        #expect(worktreeRow == nil, "the no-cascade path must delete worktree rows before returning")
    }

    /// Branch 2: a cascade is in flight, so the tail detaches. The RPC returns
    /// while phase 2 is still parked, and the rows and the broadcast arrive
    /// only once every completion has finished.
    @Test func forcedRemovalReturnsBeforeTheCleanupTailAndFinishesItAfterwards() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let db = try TBDDatabase(inMemory: true)
        let gate = PathGate()
        let (router, deltas) = makeRouter(db: db, gate: gate)
        let repo = try await db.repos.create(
            path: sandbox.appendingPathComponent("repo").path,
            displayName: "acme", defaultBranch: "main")
        let worktree = try await makeActiveWorktree(
            db: db, repoID: repo.id, sandbox: sandbox, name: "in-flight")

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.repoRemove, params: RepoRemoveParams(repoID: repo.id, force: true)))
        #expect(response.success)

        // Phase 2 is parked in the gate, so a tail that had NOT been detached
        // could not have reached any of this.
        #expect(!deltas.containsRepoRemoved(repo.id),
                "the RPC returned only after the detached tail broadcast — it was not detached")
        let repoWhileParked = try await db.repos.get(id: repo.id)
        #expect(repoWhileParked != nil)
        let rowWhileParked = try await db.worktrees.get(id: worktree.id)
        #expect(rowWhileParked?.status == .archived,
                "phase 1 must have run synchronously, flipping the row before the RPC answered")

        gate.open(worktree.localPath)

        try await waitUntil("the detached tail to delete the repo row") {
            ((try? await db.repos.get(id: repo.id)) ?? nil) == nil
        }
        let rowAfter = try await db.worktrees.get(id: worktree.id)
        #expect(rowAfter == nil, "the tail must delete the worktree rows too")
        #expect(deltas.containsRepoRemoved(repo.id),
                "the tail must still broadcast .repoRemoved once it completes")
    }

    /// The invariant the detached tail exists to preserve: rows outlive
    /// directories. `OrphanGC` builds its pool scan from `db.repos.list()` and
    /// `db.worktrees.list(status: .archived)`, so while any archive is still
    /// draining, both must still name this repo — otherwise an interrupted
    /// drain leaves a `.deleting/` entry no sweep can ever see.
    ///
    /// Two worktrees, released one at a time: after the first completion has
    /// finished, the rows must STILL be there, because the second is parked.
    /// That distinguishes "awaits every completion" from "awaits the first".
    @Test func rowsSurviveUntilEveryCascadedCompletionHasFinished() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let db = try TBDDatabase(inMemory: true)
        let gate = PathGate()
        let (router, _) = makeRouter(db: db, gate: gate)
        let repo = try await db.repos.create(
            path: sandbox.appendingPathComponent("repo").path,
            displayName: "acme", defaultBranch: "main")
        let first = try await makeActiveWorktree(
            db: db, repoID: repo.id, sandbox: sandbox, name: "first")
        let second = try await makeActiveWorktree(
            db: db, repoID: repo.id, sandbox: sandbox, name: "second")

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.repoRemove, params: RepoRemoveParams(repoID: repo.id, force: true)))
        #expect(response.success)

        // Both rows and the repo are still visible to the two lists the sweep
        // scans, while their directories are mid-drain.
        let archivedWhileParked = try await db.worktrees.list(status: .archived)
        #expect(archivedWhileParked.contains { $0.id == first.id })
        #expect(archivedWhileParked.contains { $0.id == second.id })
        let reposWhileParked = try await db.repos.list()
        #expect(reposWhileParked.contains { $0.id == repo.id })

        // Release whichever archive got there first — the cascade follows the
        // DB's list order, not creation order, so the pair is identified by
        // what actually parked rather than by name.
        try await waitUntil(
            "a cascaded archive to reach phase 2",
            observed: { "entered=\(gate.enteredPaths())" }
        ) { !gate.enteredPaths().isEmpty }
        let released = gate.enteredPaths()[0]
        let stillParked = try #require([first, second].first { $0.localPath != released })
        gate.open(released)

        // Its completion finishes; the other is still parked, so nothing
        // downstream of it may have run.
        try await waitUntil(
            "the second archive to reach phase 2",
            observed: { "entered=\(gate.enteredPaths())" }
        ) { gate.enteredPaths().contains(stillParked.localPath) }

        let reposAfterFirst = try await db.repos.list()
        #expect(reposAfterFirst.contains { $0.id == repo.id },
                "the tail must await EVERY completion, not just the first")
        let archivedAfterFirst = try await db.worktrees.list(status: .archived)
        #expect(archivedAfterFirst.contains { $0.id == stillParked.id })

        gate.open(stillParked.localPath)
        try await waitUntil("the detached tail to delete the repo row") {
            ((try? await db.repos.get(id: repo.id)) ?? nil) == nil
        }
        let remaining = try await db.worktrees.list(repoID: repo.id)
        #expect(remaining.isEmpty)
    }
}
