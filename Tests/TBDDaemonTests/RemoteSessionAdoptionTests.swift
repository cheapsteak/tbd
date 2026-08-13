import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Adoption: a sighted provider session that resolves to a registered repo
/// gets exactly one `worktree` row, created once and never re-derived.
///
/// Driven through `RemoteProviderManager.apply(snapshot:provider:)` and
/// `applyUpsert(_:provider:)` rather than the adopter alone, because the
/// ordering these tests depend on — mirror pins the repo, THEN adoption reads
/// the pin — is a property of those two call sites.
@Suite("RemoteSessionAdoption")
struct RemoteSessionAdoptionTests {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let registryURL: URL

    init() throws {
        db = try TBDDatabase(inMemory: true)
        subs = StateSubscriptionManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adoption-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        registryURL = dir.appendingPathComponent("agent-providers.json")
        try "[]".write(to: registryURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Fixtures

    /// No script: `apply`/`applyUpsert` never invoke the provider, so a
    /// scripted outcome would only be dead weight.
    private func manager() -> RemoteProviderManager {
        RemoteProviderManager(
            db: db, subscriptions: subs,
            runner: FakeProviderInvoker(script: []), registryURL: registryURL)
    }

    private func makeRepo(remote: String = "https://github.com/acme/api") async throws -> Repo {
        try await db.repos.create(
            path: "/tmp/adoption-\(UUID().uuidString)", displayName: "api",
            defaultBranch: "main", remoteURL: remote)
    }

    private func session(
        _ id: String, title: String? = nil, meta: [String: String]? = ["repo": "acme/api"]
    ) -> RemoteSessionPayload {
        RemoteSessionPayload(
            id: id, title: title, state: .running, agentState: .working, meta: meta)
    }

    private func remoteRows() async throws -> [Worktree] {
        try await db.worktrees.list().filter { !$0.location.isLocal }
    }

    // MARK: - Existence

    /// A session matching no registered repo shows only in the Provider Desk.
    ///
    /// A matched session rides along in the same snapshot so a run that
    /// adopted nothing at all cannot pass this by doing nothing.
    @Test func aSessionMatchingNoRepoGetsNoRow() async throws {
        _ = try await makeRepo()
        let m = manager()

        try await m.apply(
            snapshot: [session("unmatched", meta: ["repo": "acme/unregistered"]),
                       session("matched")],
            provider: "fake")

        #expect(try await remoteRows().map(\.location)
            == [.remote(provider: "fake", sessionID: "matched")])
        // The mirror still sees both — only the worktree row is withheld.
        #expect(try await db.remoteSessions.list().count == 2)
    }

    /// A session with no `meta` at all resolves to nothing, so it gets no row.
    /// Paired with a matched session for the same reason as above.
    @Test func aSessionWithNoMetaGetsNoRow() async throws {
        _ = try await makeRepo()
        let m = manager()

        try await m.apply(
            snapshot: [session("bare", meta: nil), session("matched")], provider: "fake")

        #expect(try await remoteRows().map(\.location)
            == [.remote(provider: "fake", sessionID: "matched")])
    }

    @Test func aMatchedSessionGetsOneTopLevelRowInItsRepo() async throws {
        let repo = try await makeRepo()
        let m = manager()

        try await m.apply(
            snapshot: [session("s-1", title: "fix flaky CI",
                               meta: ["repo": "acme/api", "branch": "fix-ci"])],
            provider: "fake")

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.repoID == repo.id)
        #expect(row.parentWorktreeID == nil)
        #expect(row.status == .active)
        #expect(row.branch == "fix-ci")
        #expect(row.displayName == "fix flaky CI")
        #expect(row.location == .remote(provider: "fake", sessionID: "s-1"))
    }

    /// Adoption is not first-sighting-only: the mirror re-attempts repo
    /// resolution while its pin is null, so registering the repo later is what
    /// makes the session adoptable, on whatever poll comes next.
    @Test func aSessionThatResolvesOnlyOnALaterPollIsAdoptedThen() async throws {
        let m = manager()

        try await m.apply(snapshot: [session("s-1")], provider: "fake")
        #expect(try await db.worktrees.list().isEmpty)

        let repo = try await makeRepo()
        try await m.apply(snapshot: [session("s-1")], provider: "fake")

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.repoID == repo.id)
    }

    // MARK: - Created once, never re-derived

    /// Repeated snapshots never mint a second row, and never rewrite the one
    /// that exists — parent, display name, and branch are the user's to change
    /// after adoption, so a later poll must not reach back over them.
    @Test func adoptionIsIdempotentAndNeverRederivesTheRow() async throws {
        let repo = try await makeRepo()
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "lane", branch: "lane", path: "/tmp/lane-\(UUID().uuidString)",
            tmuxServer: "t")
        let other = try await db.worktrees.create(
            repoID: repo.id, name: "other", branch: "other",
            path: "/tmp/other-\(UUID().uuidString)", tmuxServer: "t")
        let m = manager()

        try await m.apply(
            snapshot: [session("s-1", title: "first",
                               meta: ["repo": "acme/api", "branch": "b1",
                                      "tbd_parent_worktree_id": parent.id.uuidString])],
            provider: "fake")
        let first = try #require(try await remoteRows().first)

        // Everything adoption reads has changed on the next two polls.
        for _ in 0..<2 {
            try await m.apply(
                snapshot: [session("s-1", title: "renamed",
                                   meta: ["repo": "acme/api", "branch": "b2",
                                          "tbd_parent_worktree_id": other.id.uuidString])],
                provider: "fake")
        }

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.id == first.id)
        #expect(row.parentWorktreeID == parent.id)
        #expect(row.displayName == "first")
        #expect(row.branch == "b1")
    }

    /// The events path is a convergence point too — a session first sighted
    /// there must not wait for the next full poll — and it shares adoption's
    /// idempotence.
    @Test func theEventsPathAdoptsAndStaysIdempotent() async throws {
        let repo = try await makeRepo()
        let m = manager()

        await m.applyUpsert(session("s-1", title: "from events"), provider: "fake")
        await m.applyUpsert(session("s-1", title: "from events"), provider: "fake")

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.repoID == repo.id)
        #expect(rows.first?.displayName == "from events")
    }

    /// Two lanes of one fan-out are two rows: nothing about adoption collapses
    /// sessions that share a repo.
    @Test func twoMatchedSessionsGetTwoRows() async throws {
        _ = try await makeRepo()
        let m = manager()

        try await m.apply(snapshot: [session("s-1"), session("s-2")], provider: "fake")

        #expect(try await remoteRows().count == 2)
    }

    // MARK: - The self-healing echo

    /// A session TBD created already exported `TBD_WORKTREE_ID` into its
    /// environment. Adopting under the echoed id is what makes that variable
    /// resolve after the row is lost.
    @Test func theEchoedWorktreeIDBecomesTheRowID() async throws {
        _ = try await makeRepo()
        let m = manager()
        let echoed = UUID()

        try await m.apply(
            snapshot: [session("s-1", meta: ["repo": "acme/api",
                                             "tbd_worktree_id": echoed.uuidString])],
            provider: "fake")

        #expect(try await remoteRows().map(\.id) == [echoed])
    }

    /// The self-healing case end to end: delete the row and let the next
    /// snapshot recreate it under the same identity.
    @Test func aLostRowIsRecreatedUnderTheSameEchoedID() async throws {
        _ = try await makeRepo()
        let m = manager()
        let echoed = UUID()
        let payload = session("s-1", meta: ["repo": "acme/api",
                                            "tbd_worktree_id": echoed.uuidString])

        try await m.apply(snapshot: [payload], provider: "fake")
        try await db.worktrees.delete(id: echoed)
        #expect(try await db.worktrees.list().isEmpty)

        try await m.apply(snapshot: [payload], provider: "fake")

        #expect(try await remoteRows().map(\.id) == [echoed])
    }

    /// An echo naming a row that is not this session is ignored outright. The
    /// existing row is never rebound or mutated — the id could name a local
    /// worktree, and a session must not take a row over by claiming its id.
    @Test func anEchoCollidingWithAnUnrelatedRowMintsAFreshID() async throws {
        let repo = try await makeRepo()
        let squatted = try await db.worktrees.create(
            repoID: repo.id, name: "local-lane", branch: "local",
            path: "/tmp/local-\(UUID().uuidString)", tmuxServer: "t")
        let m = manager()

        try await m.apply(
            snapshot: [session("s-1", meta: ["repo": "acme/api",
                                             "tbd_worktree_id": squatted.id.uuidString])],
            provider: "fake")

        let adopted = try #require(try await remoteRows().first)
        #expect(adopted.id != squatted.id)

        let untouched = try #require(try await db.worktrees.get(id: squatted.id))
        #expect(untouched.location == .local)
        #expect(untouched.name == "local-lane")
        #expect(untouched.localPath == squatted.localPath)
    }

    /// An echo that is not a UUID is not a reason to withhold the row.
    @Test func anUnparseableEchoStillYieldsARow() async throws {
        _ = try await makeRepo()
        let m = manager()

        try await m.apply(
            snapshot: [session("s-1", meta: ["repo": "acme/api", "tbd_worktree_id": "not-a-uuid"])],
            provider: "fake")

        #expect(try await remoteRows().count == 1)
    }

    // MARK: - The parent stamp

    @Test func theParentStampNestsTheRow() async throws {
        let repo = try await makeRepo()
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "lane", branch: "lane",
            path: "/tmp/lane-\(UUID().uuidString)", tmuxServer: "t")
        let m = manager()

        try await m.apply(
            snapshot: [session("s-1", meta: ["repo": "acme/api",
                                             "tbd_parent_worktree_id": parent.id.uuidString])],
            provider: "fake")

        #expect(try await remoteRows().first?.parentWorktreeID == parent.id)
    }

    @Test func anUnknownParentIDLandsTopLevel() async throws {
        _ = try await makeRepo()
        let m = manager()

        try await m.apply(
            snapshot: [session("s-1", meta: ["repo": "acme/api",
                                             "tbd_parent_worktree_id": UUID().uuidString])],
            provider: "fake")

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.parentWorktreeID == nil)
    }

    @Test func anUnparseableParentIDLandsTopLevel() async throws {
        _ = try await makeRepo()
        let m = manager()

        try await m.apply(
            snapshot: [session("s-1", meta: ["repo": "acme/api",
                                             "tbd_parent_worktree_id": "nonsense"])],
            provider: "fake")

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.parentWorktreeID == nil)
    }

    /// The sidebar never renders an archived row's subtree, so storing that
    /// edge would file a live lane where nobody can see it.
    @Test func anArchivedParentLandsTopLevel() async throws {
        let repo = try await makeRepo()
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "lane", branch: "lane",
            path: "/tmp/lane-\(UUID().uuidString)", tmuxServer: "t")
        try await db.worktrees.archive(id: parent.id)
        let m = manager()

        try await m.apply(
            snapshot: [session("s-1", meta: ["repo": "acme/api",
                                             "tbd_parent_worktree_id": parent.id.uuidString])],
            provider: "fake")

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.parentWorktreeID == nil)
    }

    // MARK: - Optional well-known keys degrade

    /// `meta["branch"]` is optional per the contract. Its absence costs the
    /// branch, never the row.
    @Test func aMissingBranchDegradesToAnEmptyBranch() async throws {
        _ = try await makeRepo()
        let m = manager()

        try await m.apply(snapshot: [session("s-1")], provider: "fake")

        let row = try #require(try await remoteRows().first)
        #expect(row.branch == "")
    }

    /// A titleless session still needs something legible in the sidebar, and
    /// the synthetic name is not it.
    @Test func aMissingTitleFallsBackToTheSessionID() async throws {
        _ = try await makeRepo()
        let m = manager()

        try await m.apply(snapshot: [session("s-1", title: "   ")], provider: "fake")

        #expect(try await remoteRows().first?.displayName == "s-1")
    }

    // MARK: - Row identity

    /// The row's name has to be collision-free across sessions, providers, and
    /// repos, since nothing generates one for a session TBD did not create.
    @Test func adoptedRowNamesCannotCollide() async throws {
        _ = try await makeRepo()
        let m = manager()

        try await m.apply(snapshot: [session("team/one")], provider: "fake")
        try await m.apply(snapshot: [session("one")], provider: "fake/team")

        let names = try await remoteRows().map(\.name)
        #expect(names.count == 2)
        #expect(Set(names).count == 2)
    }

    /// The binding lookup adoption tests on every poll must find the row it
    /// created, and must not answer for a different provider's session of the
    /// same name.
    @Test func findRemoteMatchesOnlyTheExactBinding() async throws {
        let repo = try await makeRepo()
        let created = try await db.worktrees.createRemote(
            repoID: repo.id, name: "r", branch: "b", provider: "fake", sessionID: "s-1")

        #expect(try await db.worktrees.findRemote(provider: "fake", sessionID: "s-1")?.id == created.id)
        #expect(try await db.worktrees.findRemote(provider: "other", sessionID: "s-1") == nil)
        #expect(try await db.worktrees.findRemote(provider: "fake", sessionID: "s-2") == nil)
    }
}
