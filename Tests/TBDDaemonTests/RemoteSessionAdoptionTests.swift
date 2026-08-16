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

    /// The row for one session of the `fake` provider.
    private func remoteRow(_ sessionID: String, in rows: [Worktree]) -> Worktree? {
        rows.first { $0.location == .remote(provider: "fake", sessionID: sessionID) }
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

    // MARK: - The pin outlives the repo it names

    /// Nothing clears `remote_session.resolvedRepoID` when a repo is
    /// unregistered — the column carries no foreign key, unlike
    /// `worktree.repoID`, which cascades. So a session pinned before the repo
    /// went away keeps naming a row that no longer exists, and every later poll
    /// re-attempts adoption against it, because the cascade took the lane's own
    /// worktree row with it. This is the steady state, not a one-shot.
    ///
    /// What this pins is that steady state: no row is resurrected against the
    /// dangling pin, `apply` does not throw, and the mirror's own pin is left
    /// exactly as it was. It deliberately does **not** claim to discriminate on
    /// `adoptOne`'s `db.repos.get` guard — remove that guard and the outcome is
    /// identical, because `worktree.repoID`'s foreign key rejects the insert
    /// and `adoptOne`'s catch swallows it. The guard's value is that the
    /// rejection never happens (no per-poll error, no aborted write), which is
    /// a cost, not an observable. Both arms are worth holding still.
    @Test func aPinNamingAnUnregisteredRepoAdoptsNothing() async throws {
        let repo = try await makeRepo()
        let m = manager()

        try await m.apply(snapshot: [session("s-1")], provider: "fake")
        #expect(try await remoteRows().count == 1)

        // The pin survives; the worktree row cascades away with the repo.
        try await db.repos.remove(id: repo.id)
        #expect(try await db.remoteSessions.row(provider: "fake", sessionID: "s-1")?
            .resolvedRepoIDUUID == repo.id)
        #expect(try await db.worktrees.list().isEmpty)

        // Two more polls: the dangling pin must not resurrect a row, and must
        // not throw out of `apply` either.
        try await m.apply(snapshot: [session("s-1")], provider: "fake")
        try await m.apply(snapshot: [session("s-1")], provider: "fake")

        #expect(try await db.worktrees.list().isEmpty)
        // The mirror is the provider's, not adoption's: a failed adoption must
        // not clear or rewrite the pin on its way out.
        #expect(try await db.remoteSessions.row(provider: "fake", sessionID: "s-1")?
            .resolvedRepoIDUUID == repo.id)
    }

    // MARK: - Subscribers hear about a minted row

    /// Adoption mints a row nobody asked for, so the only way a subscribed
    /// client learns of it is the broadcast. It is the same `.worktreeCreated`
    /// delta a user-driven create sends, carrying the row's own id and repo.
    ///
    /// The unmatched session in the same snapshot is what keeps this honest: a
    /// broadcast per *sighted* session rather than per *created* row would
    /// announce a row that does not exist.
    @Test func adoptionBroadcastsWorktreeCreatedForTheRowItMinted() async throws {
        let repo = try await makeRepo()
        let m = manager()
        let received = DeltaRecorder()
        subs.addSubscriber { data in
            received.record(data)
            return true
        }

        try await m.apply(
            snapshot: [session("s-1"), session("unmatched", meta: ["repo": "acme/nope"])],
            provider: "fake")

        let adopted = try #require(try await remoteRows().first)
        let created = received.worktreeCreatedDeltas()
        #expect(created.count == 1)
        #expect(created.first?.worktreeID == adopted.id)
        #expect(created.first?.repoID == repo.id)

        // Idempotent adoption means no second announcement for the same row.
        try await m.apply(snapshot: [session("s-1")], provider: "fake")
        #expect(received.worktreeCreatedDeltas().count == 1)
    }

    // MARK: - A parentless row can take its first parent later

    /// The stamp is not always readable when the row is minted — the session
    /// may be stamped after TBD first sees it, or the spawning lane may not be
    /// a row TBD has yet. Adoption runs on every convergence, so the sighting
    /// that finally carries a resolvable parent is the one that files the lane.
    @Test func aParentlessRowTakesTheParentALaterSightingNames() async throws {
        let repo = try await makeRepo()
        let m = manager()

        try await m.apply(snapshot: [session("s-1")], provider: "fake")
        #expect(try await remoteRows().first?.parentWorktreeID == nil)

        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "lane", branch: "lane",
            path: "/tmp/lane-\(UUID().uuidString)", tmuxServer: "t")
        try await m.apply(
            snapshot: [session("s-1", meta: ["repo": "acme/api",
                                             "tbd_parent_worktree_id": parent.id.uuidString])],
            provider: "fake")

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.parentWorktreeID == parent.id)
    }

    /// Nil→value, once. The first parent a row takes is the last one adoption
    /// gives it: where a lane sits is the user's from then on.
    @Test func aLateParentIsTakenOnceAndNeverChangedAgain() async throws {
        let repo = try await makeRepo()
        let first = try await db.worktrees.create(
            repoID: repo.id, name: "first", branch: "first",
            path: "/tmp/first-\(UUID().uuidString)", tmuxServer: "t")
        let second = try await db.worktrees.create(
            repoID: repo.id, name: "second", branch: "second",
            path: "/tmp/second-\(UUID().uuidString)", tmuxServer: "t")
        let m = manager()

        try await m.apply(snapshot: [session("s-1")], provider: "fake")
        try await m.apply(
            snapshot: [session("s-1", meta: ["repo": "acme/api",
                                             "tbd_parent_worktree_id": first.id.uuidString])],
            provider: "fake")
        #expect(try await remoteRows().first?.parentWorktreeID == first.id)

        try await m.apply(
            snapshot: [session("s-1", meta: ["repo": "acme/api",
                                             "tbd_parent_worktree_id": second.id.uuidString])],
            provider: "fake")

        #expect(try await remoteRows().first?.parentWorktreeID == first.id)
    }

    /// Taking a first parent is the ONLY thing a later sighting may do to a row
    /// that exists. Identity, name and branch stay exactly as adopted.
    @Test func takingALateParentStillNeverRenamesOrRewritesTheRow() async throws {
        let repo = try await makeRepo()
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "lane", branch: "lane",
            path: "/tmp/lane-\(UUID().uuidString)", tmuxServer: "t")
        let m = manager()

        try await m.apply(
            snapshot: [session("s-1", title: "first", meta: ["repo": "acme/api", "branch": "b1"])],
            provider: "fake")
        let adopted = try #require(try await remoteRows().first)

        try await m.apply(
            snapshot: [session("s-1", title: "renamed",
                               meta: ["repo": "acme/api", "branch": "b2",
                                      "tbd_parent_worktree_id": parent.id.uuidString])],
            provider: "fake")

        let row = try #require(try await remoteRows().first)
        #expect(row.id == adopted.id)
        #expect(row.parentWorktreeID == parent.id)
        #expect(row.displayName == "first")
        #expect(row.branch == "b1")
    }

    /// A late edge is held to the same rules as one the user drags into place,
    /// plus the two a fresh row could never need: a row may not become its own
    /// parent, and may not be filed under one of its own descendants.
    ///
    /// Each refusal rides in a snapshot with a session that nests legitimately,
    /// so a run where late nesting is broken outright cannot pass by refusing
    /// everything.
    @Test func aLateParentThatIsTheRowItselfOrItsDescendantIsRefused() async throws {
        let repo = try await makeRepo()
        let good = try await db.worktrees.create(
            repoID: repo.id, name: "good", branch: "good",
            path: "/tmp/good-\(UUID().uuidString)", tmuxServer: "t")
        let selfID = UUID()
        let m = manager()

        try await m.apply(
            snapshot: [session("s-self", meta: ["repo": "acme/api",
                                                "tbd_worktree_id": selfID.uuidString]),
                       session("s-child"),
                       session("s-ok")],
            provider: "fake")
        let child = try #require(remoteRow("s-child", in: try await remoteRows()))
        // A descendant of the row that will be asked to nest under it.
        let descendant = try await db.worktrees.create(
            repoID: repo.id, name: "descendant", branch: "descendant",
            path: "/tmp/desc-\(UUID().uuidString)", tmuxServer: "t",
            parentWorktreeID: child.id)

        try await m.apply(
            snapshot: [session("s-self", meta: ["repo": "acme/api",
                                                "tbd_parent_worktree_id": selfID.uuidString]),
                       session("s-child", meta: ["repo": "acme/api",
                                                 "tbd_parent_worktree_id": descendant.id.uuidString]),
                       session("s-ok", meta: ["repo": "acme/api",
                                              "tbd_parent_worktree_id": good.id.uuidString])],
            provider: "fake")

        let rows = try await remoteRows()
        #expect(rows.first { $0.id == selfID }?.parentWorktreeID == nil)
        #expect(rows.first { $0.id == child.id }?.parentWorktreeID == nil)
        // The control: legitimate late nesting still happens in the same pass.
        #expect(remoteRow("s-ok", in: rows)?.parentWorktreeID == good.id)
    }

    /// Archived and main parents are refused late for the same reason they are
    /// refused at adoption: neither row's subtree is ever rendered, so the edge
    /// would file a live lane where nobody can find it.
    @Test func aLateParentThatIsArchivedOrMainIsRefused() async throws {
        let repo = try await makeRepo()
        let archived = try await db.worktrees.create(
            repoID: repo.id, name: "archived", branch: "archived",
            path: "/tmp/arch-\(UUID().uuidString)", tmuxServer: "t")
        try await db.worktrees.archive(id: archived.id)
        let mainRow = try await db.worktrees.create(
            repoID: repo.id, name: "main", branch: "main",
            path: "/tmp/main-\(UUID().uuidString)", tmuxServer: "t", status: .main)
        let good = try await db.worktrees.create(
            repoID: repo.id, name: "good", branch: "good",
            path: "/tmp/good-\(UUID().uuidString)", tmuxServer: "t")
        let m = manager()

        try await m.apply(
            snapshot: [session("s-arch"), session("s-main"), session("s-ok")], provider: "fake")

        try await m.apply(
            snapshot: [session("s-arch", meta: ["repo": "acme/api",
                                                "tbd_parent_worktree_id": archived.id.uuidString]),
                       session("s-main", meta: ["repo": "acme/api",
                                                "tbd_parent_worktree_id": mainRow.id.uuidString]),
                       session("s-ok", meta: ["repo": "acme/api",
                                              "tbd_parent_worktree_id": good.id.uuidString])],
            provider: "fake")

        let rows = try await remoteRows()
        #expect(remoteRow("s-arch", in: rows)?.parentWorktreeID == nil)
        #expect(remoteRow("s-main", in: rows)?.parentWorktreeID == nil)
        #expect(remoteRow("s-ok", in: rows)?.parentWorktreeID == good.id)
    }

    /// The events path is a convergence point too, so it heals the same way.
    @Test func theEventsPathAlsoTakesALateParent() async throws {
        let repo = try await makeRepo()
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "lane", branch: "lane",
            path: "/tmp/lane-\(UUID().uuidString)", tmuxServer: "t")
        let m = manager()

        await m.applyUpsert(session("s-1"), provider: "fake")
        await m.applyUpsert(
            session("s-1", meta: ["repo": "acme/api",
                                  "tbd_parent_worktree_id": parent.id.uuidString]),
            provider: "fake")

        let rows = try await remoteRows()
        #expect(rows.count == 1)
        #expect(rows.first?.parentWorktreeID == parent.id)
    }

    /// A row that takes a first parent is not a new lane. Subscribers hear the
    /// move a viewer would see, not a second create for a row they already
    /// have.
    @Test func takingALateParentBroadcastsWorktreeMovedNotCreated() async throws {
        let repo = try await makeRepo()
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "lane", branch: "lane",
            path: "/tmp/lane-\(UUID().uuidString)", tmuxServer: "t")
        let m = manager()
        let received = DeltaRecorder()
        subs.addSubscriber { data in
            received.record(data)
            return true
        }

        try await m.apply(snapshot: [session("s-1")], provider: "fake")
        let adopted = try #require(try await remoteRows().first)
        #expect(received.worktreeCreatedDeltas().count == 1)

        try await m.apply(
            snapshot: [session("s-1", meta: ["repo": "acme/api",
                                             "tbd_parent_worktree_id": parent.id.uuidString])],
            provider: "fake")

        #expect(received.worktreeCreatedDeltas().count == 1)
        let moved = received.worktreeMovedDeltas()
        #expect(moved.count == 1)
        #expect(moved.first?.worktreeID == adopted.id)
        #expect(moved.first?.newParentID == parent.id)
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

/// Collects the encoded deltas a `StateSubscriptionManager` broadcast, so a
/// test can assert on what subscribers were actually told.
///
/// A lock-guarded class rather than an actor because `SubscriberCallback` is a
/// synchronous `@Sendable (Data) -> Bool` and cannot await.
private final class DeltaRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [Data] = []

    func record(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        payloads.append(data)
    }

    func worktreeCreatedDeltas() -> [WorktreeDelta] {
        lock.lock()
        let snapshot = payloads
        lock.unlock()
        return snapshot.compactMap { data in
            guard let delta = try? JSONDecoder().decode(StateDelta.self, from: data) else {
                return nil
            }
            guard case .worktreeCreated(let payload) = delta else { return nil }
            return payload
        }
    }

    func worktreeMovedDeltas() -> [WorktreeMovedDelta] {
        lock.lock()
        let snapshot = payloads
        lock.unlock()
        return snapshot.compactMap { data in
            guard let delta = try? JSONDecoder().decode(StateDelta.self, from: data) else {
                return nil
            }
            guard case .worktreeMoved(let payload) = delta else { return nil }
            return payload
        }
    }
}
