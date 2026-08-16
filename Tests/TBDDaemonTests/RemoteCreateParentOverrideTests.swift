import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// The TBD-local parent a `remote.create` carries: the worktree whose nested
/// `+` the user clicked.
///
/// Driven through `RemoteProviderManager.applyUpsert(_:provider:parentWorktreeID:)`
/// because that is exactly what `RPCRouter.handleRemoteCreate` calls with the
/// decoded `RemoteCreateParams.parentWorktreeID` — the mirror pins the repo,
/// then adoption reads the pin and applies the override.
///
/// The rule under test, in one line: **the override wins when present, the
/// provider's `meta["tbd_parent_worktree_id"]` stamp answers when it is
/// absent, and an override the parent rules refuse costs the edge, never the
/// session.** Tier 1 — in-memory database, no provider ever invoked.
@Suite("Remote create — parent override")
struct RemoteCreateParentOverrideTests {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let registryURL: URL

    init() throws {
        db = try TBDDatabase(inMemory: true)
        subs = StateSubscriptionManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("create-parent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        registryURL = dir.appendingPathComponent("agent-providers.json")
        try "[]".write(to: registryURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Fixtures

    /// No script: `applyUpsert` never invokes the provider, so a scripted
    /// outcome would only be dead weight.
    private func manager() -> RemoteProviderManager {
        RemoteProviderManager(
            db: db, subscriptions: subs,
            runner: FakeProviderInvoker(script: []), registryURL: registryURL)
    }

    private func makeRepo() async throws -> Repo {
        try await db.repos.create(
            path: "/tmp/create-parent-\(UUID().uuidString)", displayName: "api",
            defaultBranch: "main", remoteURL: "https://github.com/acme/api")
    }

    private func lane(
        _ name: String, repo: Repo, status: WorktreeStatus = .active, parent: UUID? = nil
    ) async throws -> Worktree {
        try await db.worktrees.create(
            repoID: repo.id, name: name, branch: name,
            path: "/tmp/\(name)-\(UUID().uuidString)", tmuxServer: "t",
            status: status, parentWorktreeID: parent)
    }

    private func session(
        _ id: String, meta: [String: String]? = ["repo": "acme/api"]
    ) -> RemoteSessionPayload {
        RemoteSessionPayload(
            id: id, title: nil, state: .running, agentState: .working, meta: meta)
    }

    private func remoteRows() async throws -> [Worktree] {
        try await db.worktrees.list().filter { !$0.location.isLocal }
    }

    // MARK: - The override lands

    /// The whole point: a lane started from a worktree's nested `+` is minted
    /// under that worktree, with nothing said to the provider.
    @Test func theOverrideNestsTheNewRow() async throws {
        let repo = try await makeRepo()
        let parent = try await lane("lane", repo: repo)
        let m = manager()

        await m.applyUpsert(session("s-1"), provider: "fake", parentWorktreeID: parent.id)

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.parentWorktreeID == parent.id)
    }

    /// TBD knows which `+` was clicked; a stamp that says otherwise is a
    /// provider's guess about a lane it did not place.
    @Test func theOverrideBeatsAConflictingParentStamp() async throws {
        let repo = try await makeRepo()
        let clicked = try await lane("clicked", repo: repo)
        let stamped = try await lane("stamped", repo: repo)
        let m = manager()

        await m.applyUpsert(
            session("s-1", meta: ["repo": "acme/api",
                                  "tbd_parent_worktree_id": stamped.id.uuidString]),
            provider: "fake", parentWorktreeID: clicked.id)

        #expect(try await remoteRows().first?.parentWorktreeID == clicked.id)
    }

    /// With no override the stamp is still the answer — the create path is an
    /// addition to adoption, not a replacement for it.
    @Test func noOverrideStillHonoursTheParentStamp() async throws {
        let repo = try await makeRepo()
        let stamped = try await lane("stamped", repo: repo)
        let m = manager()

        await m.applyUpsert(
            session("s-1", meta: ["repo": "acme/api",
                                  "tbd_parent_worktree_id": stamped.id.uuidString]),
            provider: "fake")

        #expect(try await remoteRows().first?.parentWorktreeID == stamped.id)
    }

    /// The other side of the same branch: no override and no stamp is still a
    /// top-level lane.
    @Test func noOverrideAndNoStampStaysTopLevel() async throws {
        _ = try await makeRepo()
        let m = manager()

        await m.applyUpsert(session("s-1"), provider: "fake")

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.parentWorktreeID == nil)
    }

    // MARK: - A refused override costs the edge, never the session

    /// The main row has no subtree in the sidebar, so an edge into it would
    /// file a live lane where nobody can see it — the same rule `move()`
    /// applies. Reachable from the UI: a `WorktreeRowView` rendered outside
    /// the repo section (the pinned dock) passes no `isMain`, so a pinned main
    /// row would draw the nested `+` like any other.
    @Test func anOverrideNamingTheMainWorktreeYieldsATopLevelRow() async throws {
        let repo = try await makeRepo()
        let mainRow = try await lane("main", repo: repo, status: .main)
        let m = manager()

        await m.applyUpsert(session("s-1"), provider: "fake", parentWorktreeID: mainRow.id)

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.parentWorktreeID == nil)
    }

    @Test func anOverrideNamingAnArchivedWorktreeYieldsATopLevelRow() async throws {
        let repo = try await makeRepo()
        let archived = try await lane("archived", repo: repo)
        try await db.worktrees.archive(id: archived.id)
        let m = manager()

        await m.applyUpsert(session("s-1"), provider: "fake", parentWorktreeID: archived.id)

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.parentWorktreeID == nil)
    }

    /// The parent was deleted between the click and the provider's answer.
    @Test func anOverrideNamingNoRowYieldsATopLevelRow() async throws {
        _ = try await makeRepo()
        let m = manager()

        await m.applyUpsert(session("s-1"), provider: "fake", parentWorktreeID: UUID())

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.parentWorktreeID == nil)
    }

    /// Self-parenting is only reachable through the echo — the session names
    /// the id its row will take AND asks to nest under it — but the shared
    /// rules refuse it, so it degrades like every other refusal.
    @Test func anOverrideNamingTheRowItselfYieldsATopLevelRow() async throws {
        _ = try await makeRepo()
        let echoed = UUID()
        let m = manager()

        await m.applyUpsert(
            session("s-1", meta: ["repo": "acme/api", "tbd_worktree_id": echoed.uuidString]),
            provider: "fake", parentWorktreeID: echoed)

        let rows = try await remoteRows()
        #expect(rows.map(\.id) == [echoed])
        #expect(rows.first?.parentWorktreeID == nil)
    }

    /// A refused override does NOT fall back to the stamp. Substituting a
    /// parent the user never asked for would be a worse answer than the top
    /// level, which is at least visible and draggable.
    @Test func aRefusedOverrideDoesNotFallBackToTheParentStamp() async throws {
        let repo = try await makeRepo()
        let mainRow = try await lane("main", repo: repo, status: .main)
        let stamped = try await lane("stamped", repo: repo)
        let m = manager()

        await m.applyUpsert(
            session("s-1", meta: ["repo": "acme/api",
                                  "tbd_parent_worktree_id": stamped.id.uuidString]),
            provider: "fake", parentWorktreeID: mainRow.id)

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.parentWorktreeID == nil)
    }

    // MARK: - A row a poll already minted

    /// The create response can lose the race to a `list` poll that mints the
    /// row top-level first. The override still lands, through the same
    /// nil→value healing a late stamp uses — nothing is overwritten.
    @Test func theOverrideAlsoNestsARowAPollAlreadyMintedTopLevel() async throws {
        let repo = try await makeRepo()
        let parent = try await lane("lane", repo: repo)
        let m = manager()

        try await m.apply(snapshot: [session("s-1")], provider: "fake")
        #expect(try await remoteRows().first?.parentWorktreeID == nil)

        await m.applyUpsert(session("s-1"), provider: "fake", parentWorktreeID: parent.id)

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.parentWorktreeID == parent.id)
    }

    /// Strictly nil→value on that path too: where a lane sits once the user
    /// can see it is the user's decision, and a create response arriving late
    /// does not get to undo a drag.
    @Test func theOverrideNeverReparentsARowThatAlreadyHasAParent() async throws {
        let repo = try await makeRepo()
        let placed = try await lane("placed", repo: repo)
        let clicked = try await lane("clicked", repo: repo)
        let m = manager()

        try await m.apply(
            snapshot: [session("s-1", meta: ["repo": "acme/api",
                                             "tbd_parent_worktree_id": placed.id.uuidString])],
            provider: "fake")

        await m.applyUpsert(session("s-1"), provider: "fake", parentWorktreeID: clicked.id)

        #expect(try await remoteRows().first?.parentWorktreeID == placed.id)
    }

    /// Validation on the already-minted path is the store's, not a relaxed
    /// copy: an override naming a descendant of the row would close a cycle,
    /// and is refused with the row left at top level.
    @Test func anOverrideThatWouldCloseACycleIsRefused() async throws {
        let repo = try await makeRepo()
        let m = manager()

        try await m.apply(snapshot: [session("s-1")], provider: "fake")
        let row = try #require(try await remoteRows().first)
        let descendant = try await lane("descendant", repo: repo, parent: row.id)

        await m.applyUpsert(session("s-1"), provider: "fake", parentWorktreeID: descendant.id)

        #expect(try await remoteRows().first?.parentWorktreeID == nil)
    }
}
