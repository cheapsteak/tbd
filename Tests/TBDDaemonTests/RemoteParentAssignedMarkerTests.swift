import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1. `worktree.remote_parent_assigned` records the fact
/// `worktree.parentWorktreeID` cannot carry: that adoption has already given
/// this row a parent. Without it a nil edge reads
/// the same whether nobody could ever name a parent or the user took one away,
/// and the provider's static `tbd_parent_worktree_id` stamp — present on every
/// poll — re-nests the second case within the minute.
///
/// These cover the column and the three writes that set it — minting a remote
/// row under a parent, adoption's late healing, and the user's own `move()`.
/// The behaviour that depends on them lives in `RemoteSessionAdoptionTests`.
@Suite struct RemoteParentAssignedMarkerTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeRepo(_ db: TBDDatabase) async throws -> Repo {
        try await db.repos.create(
            path: "/tmp/rpa-repo-\(UUID().uuidString)", displayName: "RPA", defaultBranch: "main")
    }

    // MARK: - Schema

    @Test func theMarkerColumnExists() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(worktree)")
                .compactMap { $0["name"] as String? }
            #expect(columns.contains("remote_parent_assigned"))
        }
    }

    /// Rows written before the column survive, and the backfill decides what
    /// they say: a remote row that already has a parent got it from adoption
    /// (nothing else mints those rows), so it is marked; a parentless remote row
    /// is left healable; a local row is never adoption's business at all.
    @Test func forwardMigrationMarksOnlyNestedRemoteRows() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: SchemaBaselineDriftTests.frozenBlockLastIdentifier)

        let repoID = "88888888-8888-8888-8888-888888888888"
        let parentID = "99999999-9999-9999-9999-999999999999"
        let nestedRemoteID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let looseRemoteID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let nestedLocalID = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/rpa-pre-repo', 'RPA', 'main', ?)
                """, arguments: [repoID, epoch])
            try db.execute(sql: """
                INSERT INTO worktree (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                VALUES (?, ?, 'p', 'p', 'main', '/tmp/rpa-parent', 'active', ?, 'tbd-rpa')
                """, arguments: [parentID, repoID, epoch])
            try db.execute(sql: """
                INSERT INTO worktree (id, repoID, name, displayName, branch, path, status, createdAt,
                                      tmuxServer, parentWorktreeID, location, providerName, providerSessionID)
                VALUES (?, ?, 'n', 'n', 'b', '/tmp/rpa-nested', 'active', ?, '', ?, 'remote', 'fake', 's-1')
                """, arguments: [nestedRemoteID, repoID, epoch, parentID])
            try db.execute(sql: """
                INSERT INTO worktree (id, repoID, name, displayName, branch, path, status, createdAt,
                                      tmuxServer, location, providerName, providerSessionID)
                VALUES (?, ?, 'l', 'l', 'b', '/tmp/rpa-loose', 'active', ?, '', 'remote', 'fake', 's-2')
                """, arguments: [looseRemoteID, repoID, epoch])
            try db.execute(sql: """
                INSERT INTO worktree (id, repoID, name, displayName, branch, path, status, createdAt,
                                      tmuxServer, parentWorktreeID)
                VALUES (?, ?, 'k', 'k', 'b', '/tmp/rpa-local-child', 'active', ?, 'tbd-rpa', ?)
                """, arguments: [nestedLocalID, repoID, epoch, parentID])
        }

        try migrator.migrate(queue)

        let markers: [Bool?] = try queue.read { db in
            var out: [Bool?] = []
            for id in [nestedRemoteID, looseRemoteID, nestedLocalID] {
                let row = try Row.fetchOne(
                    db, sql: "SELECT remote_parent_assigned AS m FROM worktree WHERE id = ?",
                    arguments: [id])
                out.append(row?["m"] as Bool?)
            }
            return out
        }
        #expect(markers == [true, false, false])
    }

    // MARK: - The three writes that set it

    /// Minting a remote row with a parent IS an assignment, so it is recorded
    /// there and not only on the healing path.
    @Test func creatingARemoteRowWithAParentMarksIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeRepo(db)
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "p",
            path: "/tmp/rpa-p-\(UUID().uuidString)", tmuxServer: "t")

        let nested = try await db.worktrees.createRemote(
            repoID: repo.id, name: "r1", branch: "b", provider: "fake", sessionID: "s-1",
            parentWorktreeID: parent.id)
        let loose = try await db.worktrees.createRemote(
            repoID: repo.id, name: "r2", branch: "b", provider: "fake", sessionID: "s-2")

        #expect(nested.remoteParentAssigned)
        #expect(!loose.remoteParentAssigned)
        #expect(try await db.worktrees.get(id: nested.id)?.remoteParentAssigned == true)
        #expect(try await db.worktrees.get(id: loose.id)?.remoteParentAssigned == false)
    }

    /// A local worktree created under a parent is nobody's adoption, and must
    /// not pick up a marker that would only ever confuse a later reader.
    @Test func creatingALocalRowWithAParentDoesNotMarkIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeRepo(db)
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "p",
            path: "/tmp/rpa-lp-\(UUID().uuidString)", tmuxServer: "t")

        let child = try await db.worktrees.create(
            repoID: repo.id, name: "c", branch: "c",
            path: "/tmp/rpa-lc-\(UUID().uuidString)", tmuxServer: "t",
            parentWorktreeID: parent.id)

        #expect(!child.remoteParentAssigned)
    }

    @Test func assignParentIfUnsetMarksTheRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeRepo(db)
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "p",
            path: "/tmp/rpa-ap-\(UUID().uuidString)", tmuxServer: "t")
        let row = try await db.worktrees.createRemote(
            repoID: repo.id, name: "r", branch: "b", provider: "fake", sessionID: "s-1")

        #expect(try await db.worktrees.assignParentIfUnset(
            worktreeID: row.id, parentID: parent.id) != nil)

        let assigned = try #require(try await db.worktrees.get(id: row.id))
        #expect(assigned.parentWorktreeID == parent.id)
        #expect(assigned.remoteParentAssigned)
    }

    /// The store-level half of the un-nest bug: once the marker is set, a nil
    /// parent is no longer an invitation. Both branches of the guard are here —
    /// the unmarked row is assigned, the marked one is refused.
    @Test func assignParentIfUnsetRefusesAMarkedRowThatIsBackAtNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeRepo(db)
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "p",
            path: "/tmp/rpa-un-\(UUID().uuidString)", tmuxServer: "t")
        let row = try await db.worktrees.createRemote(
            repoID: repo.id, name: "r", branch: "b", provider: "fake", sessionID: "s-1")

        #expect(try await db.worktrees.assignParentIfUnset(
            worktreeID: row.id, parentID: parent.id) != nil)
        try await db.worktrees.move(worktreeID: row.id, newParentID: nil, newSortOrder: 0)

        #expect(try await db.worktrees.assignParentIfUnset(
            worktreeID: row.id, parentID: parent.id) == nil)
        #expect(try await db.worktrees.get(id: row.id)?.parentWorktreeID == nil)
    }

    /// The user's own move is not allowed to clear the marker — that is exactly
    /// the gesture the marker exists to make permanent. Held for both
    /// directions of a move, since either could plausibly have been written to
    /// "reset" the row.
    @Test func aUserMoveNeverClearsTheMarker() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeRepo(db)
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "p",
            path: "/tmp/rpa-mv-\(UUID().uuidString)", tmuxServer: "t")
        let other = try await db.worktrees.create(
            repoID: repo.id, name: "o", branch: "o",
            path: "/tmp/rpa-mo-\(UUID().uuidString)", tmuxServer: "t")
        let row = try await db.worktrees.createRemote(
            repoID: repo.id, name: "r", branch: "b", provider: "fake", sessionID: "s-1",
            parentWorktreeID: parent.id)

        try await db.worktrees.move(worktreeID: row.id, newParentID: nil, newSortOrder: 0)
        #expect(try await db.worktrees.get(id: row.id)?.remoteParentAssigned == true)

        try await db.worktrees.move(worktreeID: row.id, newParentID: other.id, newSortOrder: 0)
        #expect(try await db.worktrees.get(id: row.id)?.remoteParentAssigned == true)
    }

    // MARK: - The user's own move spends the assignment too

    /// The reviewer's four-step repro, and the reason `move()` writes the
    /// marker at all.
    ///
    /// A remote lane adopted top-level with no resolvable stamp is unmarked, so
    /// healing is still available to it. The user then nests it by hand and
    /// un-nests it again. Both gestures go through `move()`, which the adoption
    /// path never sees — so before this, the row arrived back at nil parent
    /// STILL unmarked, `assignParentIfUnset`'s guard passed, and the next poll
    /// that could finally resolve the static stamp re-nested the lane. Exactly
    /// the regression the marker exists to prevent, reached through a first
    /// parent that came from a manual move rather than from adoption.
    @Test func aManualNestThenUnNestLeavesTheLaneWhereTheUserPutIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeRepo(db)
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "p",
            path: "/tmp/rpa-mn-\(UUID().uuidString)", tmuxServer: "t")

        // (1) Adopted top-level, nobody could name a parent.
        let lane = try await db.worktrees.createRemote(
            repoID: repo.id, name: "r", branch: "b", provider: "fake", sessionID: "s-1")
        #expect(!lane.remoteParentAssigned)

        // (2) The user nests it by hand — a drag in the sidebar, or
        //     `tbd worktree reparent`. That is a placement decision, and it is
        //     this row's one assignment.
        try await db.worktrees.move(worktreeID: lane.id, newParentID: parent.id, newSortOrder: 0)
        #expect(try await db.worktrees.get(id: lane.id)?.remoteParentAssigned == true)

        // (3) The user un-nests it again. Parent nil, marker still set.
        try await db.worktrees.move(worktreeID: lane.id, newParentID: nil, newSortOrder: 0)
        let unNested = try #require(try await db.worktrees.get(id: lane.id))
        #expect(unNested.parentWorktreeID == nil)
        #expect(unNested.remoteParentAssigned)

        // (4) The next poll finally resolves the stamp. It must be refused.
        #expect(try await db.worktrees.assignParentIfUnset(
            worktreeID: lane.id, parentID: parent.id) == nil)
        #expect(try await db.worktrees.get(id: lane.id)?.parentWorktreeID == nil)
    }

    /// The other direction of the same rule, on the one row shape that can
    /// still reach it: a remote row that has a parent but no marker. The
    /// backfill closes that state for every row it can see, so this one is
    /// built by hand — a row whose `location` was written after the backfill
    /// ran would look exactly like it. Moving it to root is a placement
    /// decision and spends the assignment, so healing cannot put it back.
    @Test func aManualMoveToRootSpendsTheAssignmentToo() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeRepo(db)
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "p",
            path: "/tmp/rpa-mr-\(UUID().uuidString)", tmuxServer: "t")
        let lane = try await db.worktrees.createRemote(
            repoID: repo.id, name: "r", branch: "b", provider: "fake", sessionID: "s-1",
            parentWorktreeID: parent.id)
        try await db.writerForTests.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE worktree SET remote_parent_assigned = 0 WHERE id = ?",
                arguments: [lane.id.uuidString])
        }
        #expect(try await db.worktrees.get(id: lane.id)?.remoteParentAssigned == false)

        try await db.worktrees.move(worktreeID: lane.id, newParentID: nil, newSortOrder: 0)

        let moved = try #require(try await db.worktrees.get(id: lane.id))
        #expect(moved.parentWorktreeID == nil)
        #expect(moved.remoteParentAssigned)
        #expect(try await db.worktrees.assignParentIfUnset(
            worktreeID: lane.id, parentID: parent.id) == nil)
    }

    /// A move that leaves the parent edge alone is a reordering, not a
    /// statement about nesting, so it must NOT spend the assignment: a
    /// top-level remote lane the user merely dragged up the list is still one
    /// adoption may file under its spawning lane once the stamp resolves.
    /// The discriminating half of the rule above.
    @Test func reorderingWithinTheSameGroupDoesNotSpendTheAssignment() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeRepo(db)
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "p",
            path: "/tmp/rpa-ro-\(UUID().uuidString)", tmuxServer: "t")
        let lane = try await db.worktrees.createRemote(
            repoID: repo.id, name: "r", branch: "b", provider: "fake", sessionID: "s-1")

        try await db.worktrees.move(worktreeID: lane.id, newParentID: nil, newSortOrder: 3)

        #expect(try await db.worktrees.get(id: lane.id)?.remoteParentAssigned == false)
        #expect(try await db.worktrees.assignParentIfUnset(
            worktreeID: lane.id, parentID: parent.id) != nil)
    }

    /// The marker is remote-only bookkeeping. A local worktree the user nests
    /// and un-nests must never acquire it — adoption is not in that row's life,
    /// and a marker there would only mislead a later reader.
    @Test func movingALocalRowNeverMarksIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await makeRepo(db)
        let parent = try await db.worktrees.create(
            repoID: repo.id, name: "p", branch: "p",
            path: "/tmp/rpa-lm-\(UUID().uuidString)", tmuxServer: "t")
        let child = try await db.worktrees.create(
            repoID: repo.id, name: "c", branch: "c",
            path: "/tmp/rpa-lc2-\(UUID().uuidString)", tmuxServer: "t")

        try await db.worktrees.move(worktreeID: child.id, newParentID: parent.id, newSortOrder: 0)
        #expect(try await db.worktrees.get(id: child.id)?.remoteParentAssigned == false)

        try await db.worktrees.move(worktreeID: child.id, newParentID: nil, newSortOrder: 0)
        #expect(try await db.worktrees.get(id: child.id)?.remoteParentAssigned == false)
    }

    // MARK: - The wire

    /// A payload from a daemon that predates the field still decodes, as an
    /// unmarked row — which is what lets an app and a daemon at different
    /// versions keep talking.
    @Test func worktreeJSONWithoutTheMarkerDecodesAsUnassigned() throws {
        let json = """
            {
                "id": "\(UUID().uuidString)",
                "name": "w",
                "displayName": "w",
                "branch": "b",
                "path": "/tmp/w",
                "status": "active",
                "createdAt": 0,
                "tmuxServer": "tbd-x"
            }
            """
        let worktree = try JSONDecoder().decode(Worktree.self, from: Data(json.utf8))
        #expect(!worktree.remoteParentAssigned)
    }

    /// And a marked row stays marked across the wire, so the app's copy agrees
    /// with the daemon's about a lane the user has already placed.
    @Test func theMarkerSurvivesAJSONRoundTrip() throws {
        let marked = Worktree(
            repoID: UUID(), name: "w", displayName: "w", branch: "b", path: "/tmp/w",
            tmuxServer: "", location: .remote(provider: "fake", sessionID: "s-1"),
            remoteParentAssigned: true)
        let decoded = try JSONDecoder().decode(Worktree.self, from: JSONEncoder().encode(marked))
        #expect(decoded.remoteParentAssigned)
        #expect(decoded == marked)
    }
}
