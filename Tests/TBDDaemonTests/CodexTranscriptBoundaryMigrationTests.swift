import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct CodexTranscriptBoundaryMigrationTests {
    @Test func forwardMigrationAddsNullableBoundaryToExistingTerminal() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "20260824214437_auto_create_notes_setting")

        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let repoID = UUID().uuidString
        let worktreeID = UUID().uuidString
        let terminalID = UUID().uuidString
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                    VALUES (?, '/tmp/codex-boundary-repo', 'Boundary', 'main', ?)
                    """,
                arguments: [repoID, epoch]
            )
            try db.execute(
                sql: """
                    INSERT INTO worktree
                        (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                    VALUES (?, ?, 'w', 'w', 'main', '/tmp/codex-boundary-wt',
                            'active', ?, 'tbd-boundary')
                    """,
                arguments: [worktreeID, repoID, epoch]
            )
            try db.execute(
                sql: """
                    INSERT INTO terminal
                        (id, worktreeID, tmuxWindowID, tmuxPaneID, createdAt)
                    VALUES (?, ?, '@1', '%1', ?)
                    """,
                arguments: [terminalID, worktreeID, epoch]
            )
        }

        let columnsBefore = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(terminal)")
                .compactMap { $0["name"] as String? }
        }
        #expect(!columnsBefore.contains("codexTranscriptBoundaryOffset"))

        try migrator.migrate(queue, upTo: "20260825024814_codex_transcript_boundary")

        let result = try queue.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(terminal)")
                .compactMap { $0["name"] as String? }
            let row = try Row.fetchOne(
                db,
                sql: "SELECT codexTranscriptBoundaryOffset FROM terminal WHERE id = ?",
                arguments: [terminalID]
            )
            return (columns, row)
        }
        #expect(result.0.contains("codexTranscriptBoundaryOffset"))
        let row = try #require(result.1)
        #expect((row["codexTranscriptBoundaryOffset"] as Int64?) == nil)
    }

    @Test(arguments: [Int64?.none, Int64?.some(0), Int64?.some(4_294_967_296)])
    func terminalRecordRoundTripsBoundary(_ boundary: Int64?) async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/codex-boundary-record-repo-\(UUID().uuidString)",
            displayName: "Boundary",
            defaultBranch: "main"
        )
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: "boundary",
            branch: "boundary",
            path: "/tmp/codex-boundary-record-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-boundary-record"
        )
        let terminal = Terminal(
            worktreeID: worktree.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            codexTranscriptBoundaryOffset: boundary
        )

        try await db.writerForTests.write { dbConnection in
            try TerminalRecord(from: terminal).insert(dbConnection)
        }

        let rawRow = try db.writerForTests.read { dbConnection in
            return try Row.fetchOne(
                dbConnection,
                sql: "SELECT codexTranscriptBoundaryOffset FROM terminal WHERE id = ?",
                arguments: [terminal.id.uuidString]
            )
        }
        let row = try #require(rawRow)
        #expect((row["codexTranscriptBoundaryOffset"] as Int64?) == boundary)

        let fetched = try #require(try await db.terminals.get(id: terminal.id))
        #expect(fetched.codexTranscriptBoundaryOffset == boundary)
    }
}
