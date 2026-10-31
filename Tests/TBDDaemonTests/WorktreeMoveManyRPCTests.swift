import Testing
import Foundation
import DaemonTestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// Handler-level coverage for `worktree.moveMany`: a committed move broadcasts
/// the whole destination group with the request's `moveID`, a refused move
/// answers with the error and broadcasts nothing, and a new parent is disarmed
/// for auto-archive exactly as `worktree.move` disarms it.
@Suite struct WorktreeMoveManyRPCTests {

    /// Router whose handlers broadcast into one manager, with every delta it
    /// broadcasts captured in `deltas`.
    private func makeRouter(db: TBDDatabase) -> (router: RPCRouter, deltas: MoveManyDeltas) {
        let deltas = MoveManyDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver(),
                subscriptions: subs
            ),
            tmux: TmuxManager(dryRun: true),
            subscriptions: subs,
            actuationLog: makeTestActuationLog()
        )
        return (router, deltas)
    }

    private func makeRepo(_ db: TBDDatabase) async throws -> Repo {
        try await db.repos.create(
            path: "/tmp/repo-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
    }

    private func makeWT(
        _ db: TBDDatabase, repo: Repo, name: String, parent: UUID? = nil
    ) async throws -> Worktree {
        try await db.worktrees.create(
            repoID: repo.id, name: name, branch: "tbd/\(name)",
            path: "/tmp/\(name)-\(UUID().uuidString)", tmuxServer: "srv",
            parentWorktreeID: parent)
    }

    private func moveMany(
        _ router: RPCRouter, _ params: WorktreeMoveManyParams
    ) async throws -> RPCResponse {
        let request = try RPCRequest(method: RPCMethod.worktreeMoveMany, params: params)
        return await router.handle(request)
    }

    @Test func moveManyBroadcastsGroupWithMoveID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let repo = try await makeRepo(db)
        let parent = try await makeWT(db, repo: repo, name: "parent")
        let existing = try await makeWT(db, repo: repo, name: "existing", parent: parent.id)
        let a = try await makeWT(db, repo: repo, name: "a")
        let b = try await makeWT(db, repo: repo, name: "b")
        let moveID = UUID()

        let response = try await moveMany(router, WorktreeMoveManyParams(
            moveID: moveID, worktreeIDs: [b.id, a.id],
            newParentID: parent.id, beforeWorktreeID: existing.id))
        #expect(response.success, "worktree.moveMany must succeed: \(response.error ?? "")")

        let reordered = deltas.siblingsReordered()
        #expect(reordered.count == 1)
        let delta = try #require(reordered.first)
        #expect(delta.moveID == moveID)
        // The whole destination group, as the database now holds it.
        var stored: [WorktreeOrderEntry] = []
        for id in [b.id, a.id, existing.id] {
            let row = try #require(try await db.worktrees.get(id: id))
            stored.append(WorktreeOrderEntry(
                worktreeID: id, parentWorktreeID: row.parentWorktreeID, sortOrder: row.sortOrder))
        }
        #expect(delta.entries == stored)
        #expect(delta.entries == [
            WorktreeOrderEntry(worktreeID: b.id, parentWorktreeID: parent.id, sortOrder: 0),
            WorktreeOrderEntry(worktreeID: a.id, parentWorktreeID: parent.id, sortOrder: 1),
            WorktreeOrderEntry(worktreeID: existing.id, parentWorktreeID: parent.id, sortOrder: 2),
        ])
    }

    @Test func moveManyFailureBroadcastsNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let repo = try await makeRepo(db)
        let ancestor = try await makeWT(db, repo: repo, name: "ancestor")
        let child = try await makeWT(db, repo: repo, name: "child", parent: ancestor.id)

        let response = try await moveMany(router, WorktreeMoveManyParams(
            moveID: UUID(), worktreeIDs: [ancestor.id],
            newParentID: child.id, beforeWorktreeID: nil))

        #expect(!response.success)
        #expect(response.error == WorktreeMoveError.cycle.description)
        #expect(deltas.all().isEmpty)
        #expect(try await db.worktrees.get(id: ancestor.id)?.parentWorktreeID == nil)
    }

    @Test func moveManyDisarmsAutoArchiveOnNewParent() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let repo = try await makeRepo(db)
        let parent = try await makeWT(db, repo: repo, name: "parent")
        let child = try await makeWT(db, repo: repo, name: "child")
        try await db.worktrees.setAutoArchiveOnMerge(id: parent.id, value: true)

        let response = try await moveMany(router, WorktreeMoveManyParams(
            moveID: UUID(), worktreeIDs: [child.id],
            newParentID: parent.id, beforeWorktreeID: nil))

        #expect(response.success)
        #expect(try await db.worktrees.get(id: parent.id)?.autoArchiveOnMerge == false,
                "a parent armed for auto-archive is disarmed when a row is nested under it")
    }

    /// The other branch: a move to the top level names no new parent, so the
    /// old parent stays armed.
    @Test func moveManyToTopLevelDisarmsNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, _) = makeRouter(db: db)
        let repo = try await makeRepo(db)
        let oldParent = try await makeWT(db, repo: repo, name: "old-parent")
        let child = try await makeWT(db, repo: repo, name: "child", parent: oldParent.id)
        try await db.worktrees.setAutoArchiveOnMerge(id: oldParent.id, value: true)

        let response = try await moveMany(router, WorktreeMoveManyParams(
            moveID: UUID(), worktreeIDs: [child.id],
            newParentID: nil, beforeWorktreeID: nil))

        #expect(response.success)
        #expect(try await db.worktrees.get(id: oldParent.id)?.autoArchiveOnMerge == true)
    }
}

/// Thread-safe collector for broadcast StateDeltas.
private final class MoveManyDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func all() -> [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }

    func siblingsReordered() -> [WorktreeSiblingsReorderedDelta] {
        all().compactMap { delta in
            guard case .worktreeSiblingsReordered(let payload) = delta else { return nil }
            return payload
        }
    }
}
