import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1. The create-param defaults have two homes — one on the repo, one on
/// the singleton config row — and both are a JSON map keyed by the
/// PROVIDER's field names. That keying is the point: a column per concept
/// (`permission_mode`, say) would put one provider's vocabulary in TBD's
/// schema, and the next provider would need another column.
@Suite struct RemoteCreateDefaultsStorageTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - Schema

    @Test func bothColumnsExist() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            for table in ["config", "repo"] {
                let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(\(table))")
                    .compactMap { $0["name"] as String? }
                #expect(columns.contains("remote_create_defaults"), "\(table) is missing the column")
            }
        }
    }

    /// A row written before the column survives and reads as "no opinion" —
    /// the state a repo left on Auto is in — rather than as an empty answer
    /// that would shadow the level below it.
    @Test func aPreMigrationRowReadsAsNoOpinion() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "20260816122608_worktree_remote_parent_assigned")

        let repoID = "11111111-1111-1111-1111-111111111111"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/rcd-pre-repo', 'RCD', 'main', ?)
                """, arguments: [repoID, epoch])
        }

        try migrator.migrate(queue)

        let stored: String?? = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT remote_create_defaults FROM repo WHERE id = ?",
                             arguments: [repoID])?["remote_create_defaults"]
        }
        #expect(stored ?? nil == nil)
    }

    // MARK: - Round trip

    @Test func aRepoMapRoundTripsThroughTheModel() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/rcd-repo-\(UUID().uuidString)", displayName: "RCD", defaultBranch: "main")
        #expect(repo.remoteCreateDefaults.isEmpty)

        try await db.repos.setRemoteCreateDefaults(
            id: repo.id, defaults: ["permission_mode": "plan", "cmd": "claude"])
        let reloaded = try await db.repos.get(id: repo.id)
        #expect(reloaded?.remoteCreateDefaults == ["permission_mode": "plan", "cmd": "claude"])
    }

    @Test func anEmptyRepoMapClearsBackToNoOpinion() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/rcd-repo-\(UUID().uuidString)", displayName: "RCD", defaultBranch: "main")
        try await db.repos.setRemoteCreateDefaults(id: repo.id, defaults: ["permission_mode": "plan"])
        try await db.repos.setRemoteCreateDefaults(id: repo.id, defaults: [:])

        #expect(try await db.repos.get(id: repo.id)?.remoteCreateDefaults.isEmpty == true)
        let stored: String?? = try await db.writerForTests.read { dbConn in
            try Row.fetchOne(dbConn, sql: "SELECT remote_create_defaults FROM repo WHERE id = ?",
                             arguments: [repo.id.uuidString])?["remote_create_defaults"]
        }
        #expect(stored ?? nil == nil)
    }

    @Test func aGlobalMapRoundTripsThroughTheModel() async throws {
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().remoteCreateDefaults.isEmpty)

        try await db.config.setRemoteCreateDefaults(["permission_mode": "skip_permissions"])
        #expect(try await db.config.get().remoteCreateDefaults == ["permission_mode": "skip_permissions"])

        try await db.config.setRemoteCreateDefaults([:])
        #expect(try await db.config.get().remoteCreateDefaults.isEmpty)
    }

    /// A hand-edited or otherwise corrupt row degrades to "no opinion" rather
    /// than failing the read — the same rule every other JSON map column here
    /// follows, and the one that keeps a bad row from blocking a create.
    @Test func aCorruptMapReadsAsNoOpinion() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/rcd-repo-\(UUID().uuidString)", displayName: "RCD", defaultBranch: "main")
        try await db.writerForTests.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE repo SET remote_create_defaults = ? WHERE id = ?",
                arguments: ["{not json", repo.id.uuidString])
        }
        #expect(try await db.repos.get(id: repo.id)?.remoteCreateDefaults.isEmpty == true)
    }

    // MARK: - Wire decoding

    /// An older sender omits the field entirely; that must decode as "no
    /// opinion", not fail the whole row.
    @Test func modelsDecodeWithoutTheField() throws {
        let repoJSON = """
        {"id":"22222222-2222-2222-2222-222222222222","path":"/tmp/x","displayName":"X",
         "defaultBranch":"main","createdAt":0,"status":"ok","hidden":false,"expanded":true}
        """
        let repo = try JSONDecoder().decode(Repo.self, from: Data(repoJSON.utf8))
        #expect(repo.remoteCreateDefaults.isEmpty)

        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(config.remoteCreateDefaults.isEmpty)
    }
}
