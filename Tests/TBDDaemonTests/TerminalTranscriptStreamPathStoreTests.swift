import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The Swift half of `terminal.transcript_stream_path`
/// (`docs/specs/2026-09-05-transcript-streaming-model-proxy-design.md`,
/// "The daemon" → "Spawn"): the column reaches `Terminal.transcriptStreamPath`
/// in both directions, a session that was never routed through the proxy reads
/// nil, and the value survives the wire.
///
/// The column is nullable with no SQL default for the same reason the flags
/// are: a session either got a stream file at spawn or never will, and the row
/// must be able to say "never" rather than "empty string".
@Suite("TerminalStore transcript stream path")
struct TerminalTranscriptStreamPathStoreTests {

    /// The last migration identifier that predates the column. Migrating only
    /// this far reproduces the schema a real pre-proxy daemon ran on.
    private static let lastIdentifierBeforeTheColumn = "20260907215726_config_model_proxy_port"

    private func makeTerminal(_ db: TBDDatabase) async throws -> Terminal {
        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-test")
        return try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", kind: .claude)
    }

    // MARK: - Storage

    /// Every terminal starts unrouted. Nothing spawns a route by accident.
    @Test func aFreshRowHasNoStreamPath() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        #expect(terminal.transcriptStreamPath == nil)
        let row = try #require(try await db.terminals.get(id: terminal.id))
        #expect(row.transcriptStreamPath == nil)
    }

    @Test func theSetterWritesAPathThatReadsBack() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        let path = "/tmp/tbd-streams/\(terminal.id.uuidString).jsonl"

        try await db.terminals.setTranscriptStreamPath(terminalID: terminal.id, path: path)

        let row = try #require(try await db.terminals.get(id: terminal.id))
        #expect(row.transcriptStreamPath == path)
        let stored = try await db.writerForTests.read { conn in
            try String.fetchOne(
                conn, sql: "SELECT transcript_stream_path FROM terminal WHERE id = ?",
                arguments: [terminal.id.uuidString])
        }
        #expect(stored == path, "the model field must land in the snake_case column")
    }

    @Test func theSetterClearsTheRouteWithNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        try await db.terminals.setTranscriptStreamPath(
            terminalID: terminal.id, path: "/tmp/tbd-streams/a.jsonl")

        try await db.terminals.setTranscriptStreamPath(terminalID: terminal.id, path: nil)

        let row = try #require(try await db.terminals.get(id: terminal.id))
        #expect(row.transcriptStreamPath == nil)
    }

    /// The narrow-write property the setter's `UPDATE` exists for: spawn writes
    /// this column while the process it just started is already firing hooks,
    /// so the write must not carry the rest of the row back with it.
    @Test func theSetterLeavesEveryOtherColumnAlone() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: "sess-1", transcriptPath: "/tmp/t.jsonl")
        let before = try #require(try await db.terminals.get(id: terminal.id))

        try await db.terminals.setTranscriptStreamPath(
            terminalID: terminal.id, path: "/tmp/tbd-streams/b.jsonl")

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.claudeSessionID == before.claudeSessionID)
        #expect(after.transcriptPath == before.transcriptPath)
        #expect(after.sessionIncarnationID == before.sessionIncarnationID)
        #expect(after.activityState == before.activityState)
        #expect(after.transcriptStreamPath == "/tmp/tbd-streams/b.jsonl")
    }

    /// A terminal that has vanished is a no-op rather than a throw — the route
    /// belonged to a row nothing can read any more. Matches `setProfileID`.
    @Test func theSetterIgnoresAMissingRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.terminals.setTranscriptStreamPath(terminalID: UUID(), path: "/tmp/x.jsonl")
    }

    /// **The load-bearing test.** A terminal row written by a daemon that
    /// predates the column must read nil after the migration, not an empty
    /// string — a `DEFAULT ''` clause on the migration would redden this.
    @Test func aRowWrittenBeforeTheMigrationStillReadsNil() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeTheColumn)

        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let repoID = UUID().uuidString
        let worktreeID = UUID().uuidString
        let terminalID = UUID().uuidString
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                    VALUES (?, '/tmp/stream-path-repo', 'Stream', 'main', ?)
                    """, arguments: [repoID, epoch])
            try db.execute(
                sql: """
                    INSERT INTO worktree
                        (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                    VALUES (?, ?, 'w', 'w', 'main', '/tmp/stream-path-wt',
                            'active', ?, 'tbd-stream-path')
                    """, arguments: [worktreeID, repoID, epoch])
            try db.execute(
                sql: """
                    INSERT INTO terminal
                        (id, worktreeID, tmuxWindowID, tmuxPaneID, createdAt)
                    VALUES (?, ?, '@1', '%1', ?)
                    """, arguments: [terminalID, worktreeID, epoch])
        }
        let columnsBefore = try queue.read { db in
            try db.columns(in: "terminal").map(\.name)
        }
        #expect(
            !columnsBefore.contains("transcript_stream_path"),
            "the fixture must be written against a schema that predates the column")

        try migrator.migrate(queue)

        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM terminal WHERE id = ?", arguments: [terminalID]))
            let raw: DatabaseValue = row["transcript_stream_path"]
            #expect(
                raw.isNull,
                "transcript_stream_path on a pre-migration terminal row must read NULL, not \(raw)")

            let record = try #require(try TerminalRecord.fetchOne(db, key: terminalID))
            #expect(record.transcript_stream_path == nil)
            #expect(try #require(record.toModel()).transcriptStreamPath == nil)
        }
    }

    // MARK: - The wire

    @Test func terminalJSONWithoutTheKeyDecodesToNil() throws {
        let json = """
            {"id":"\(UUID().uuidString)","worktreeID":"\(UUID().uuidString)",
             "tmuxWindowID":"@1","tmuxPaneID":"%1","createdAt":0}
            """
        let decoded = try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
        #expect(decoded.transcriptStreamPath == nil)
    }

    @Test func terminalJSONRoundTripsThePath() throws {
        let path = "/tmp/tbd-streams/round-trip.jsonl"
        let terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            transcriptStreamPath: path)
        let encoded = try JSONEncoder().encode(terminal)
        let decoded = try JSONDecoder().decode(Terminal.self, from: encoded)
        #expect(decoded.transcriptStreamPath == path)

        let unrouted = Terminal(worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1")
        let unroutedData = try JSONEncoder().encode(unrouted)
        let unroutedJSON = try #require(
            JSONSerialization.jsonObject(with: unroutedData) as? [String: Any])
        #expect(
            !unroutedJSON.keys.contains("transcriptStreamPath"),
            "an unrouted terminal must omit the key rather than send a null")
        let decodedUnrouted = try JSONDecoder().decode(Terminal.self, from: unroutedData)
        #expect(decodedUnrouted.transcriptStreamPath == nil)
    }

    // MARK: - The replacement snapshot

    /// The snapshot exists so a command prepared for one launch cannot commit
    /// against another. The route is part of that launch, so a row whose route
    /// moved must no longer match.
    @Test func theReplacementSnapshotNoticesAChangedRoute() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        try await db.terminals.setTranscriptStreamPath(
            terminalID: terminal.id, path: "/tmp/tbd-streams/first.jsonl")
        let observed = try #require(try await db.terminals.get(id: terminal.id))
        let snapshot = TerminalReplacementSnapshot(terminal: observed)
        #expect(snapshot.transcriptStreamPath == "/tmp/tbd-streams/first.jsonl")
        #expect(snapshot.matches(observed))

        try await db.terminals.setTranscriptStreamPath(
            terminalID: terminal.id, path: "/tmp/tbd-streams/second.jsonl")

        let moved = try #require(try await db.terminals.get(id: terminal.id))
        #expect(!snapshot.matches(moved), "a route that moved is a launch the caller never saw")
    }
}
