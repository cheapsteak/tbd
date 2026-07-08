import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

/// v47 adds the nullable TEXT `hibernateReason` column: WHO parked a session
/// (idle sweep / manual "Hibernate now" / crash-recovery reconcile), so the
/// app's wake-on-focus can skip manual parks. Modeled on
/// `MigrationV39HibernationTests`.
@Suite struct MigrationV47HibernateReasonTests {

    /// repo + worktree + Claude terminal fixture for an in-memory DB.
    private func makeClaudeTerminal(_ db: TBDDatabase) async throws -> Terminal {
        let repo = try await db.repos.create(
            path: "/tmp/v46-repo-\(UUID().uuidString)", displayName: "V46", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v46-wt-\(UUID().uuidString)", tmuxServer: "tbd-v46")
        return try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "s-1", kind: .claude)
    }

    @Test func hibernateReasonColumnExists() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let terminalCols = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(terminal)")
                .compactMap { $0["name"] as String? }
            #expect(terminalCols.contains("hibernateReason"))
        }
    }

    /// Each reason round-trips through setHibernated → fetch unchanged.
    @Test(arguments: [HibernateReason.auto, .manual, .recovery])
    func hibernateReasonRoundTrips(reason: HibernateReason) async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeClaudeTerminal(db)

        try await db.terminals.setHibernated(id: terminal.id, sessionID: "s-1", reason: reason)
        let parked = try await db.terminals.get(id: terminal.id)
        #expect(parked?.hibernatedAt != nil)
        #expect(parked?.hibernateReason == reason)
    }

    /// The defaulted `reason:` parameter (used by call sites that predate the
    /// column, e.g. the recreate-window park) stores NULL — legacy semantics.
    @Test func setHibernatedWithoutReasonStoresNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeClaudeTerminal(db)

        try await db.terminals.setHibernated(id: terminal.id, sessionID: "s-1")
        let parked = try await db.terminals.get(id: terminal.id)
        #expect(parked?.hibernatedAt != nil)
        #expect(parked?.hibernateReason == nil)
    }

    /// Waking (clearHibernated) clears the reason along with hibernatedAt —
    /// the single un-park point nils all three parked columns.
    @Test func clearHibernatedClearsReason() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeClaudeTerminal(db)

        try await db.terminals.setHibernated(id: terminal.id, sessionID: "s-1", reason: .manual)
        try await db.terminals.clearHibernated(id: terminal.id)
        let woken = try await db.terminals.get(id: terminal.id)
        #expect(woken?.hibernatedAt == nil)
        #expect(woken?.hibernateReason == nil)
    }

    /// clearRecreated also un-parks (nils hibernatedAt), so it must clear the
    /// reason too — a stale `.manual` on a recreated shell row would wrongly
    /// shield a future park from focus-wake.
    @Test func clearRecreatedClearsReason() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeClaudeTerminal(db)

        try await db.terminals.setHibernated(id: terminal.id, sessionID: "s-1", reason: .manual)
        try await db.terminals.clearRecreated(id: terminal.id)
        let recreated = try await db.terminals.get(id: terminal.id)
        #expect(recreated?.hibernatedAt == nil)
        #expect(recreated?.hibernateReason == nil)
    }

    /// A re-park overwrites any prior reason (stamped unconditionally): a row
    /// parked manually, woken, then auto-parked must read `.auto`.
    @Test func reparkOverwritesPriorReason() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeClaudeTerminal(db)

        try await db.terminals.setHibernated(id: terminal.id, sessionID: "s-1", reason: .manual)
        try await db.terminals.clearHibernated(id: terminal.id)
        try await db.terminals.setHibernated(id: terminal.id, sessionID: "s-1", reason: .auto)
        let reparked = try await db.terminals.get(id: terminal.id)
        #expect(reparked?.hibernateReason == .auto)
    }

    /// A pre-v47 parked row (inserted without any hibernateReason value, as an
    /// old daemon binary would have written it) still loads, reads as parked,
    /// and carries a nil reason.
    @Test func preV46ParkedRowLoadsWithNilReason() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v46-legacy-repo-\(UUID().uuidString)", displayName: "V46", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v46-legacy-wt-\(UUID().uuidString)", tmuxServer: "tbd-v46")

        let id = UUID()
        try await db.writerForTests.write { dbConn in
            try dbConn.execute(
                sql: """
                    INSERT INTO terminal (id, worktreeID, tmuxWindowID, tmuxPaneID, createdAt, claudeSessionID, hibernatedAt)
                    VALUES (?, ?, '@9', '%9', ?, 's-legacy', ?)
                    """,
                arguments: [id.uuidString, wt.id.uuidString, Date(), Date()]
            )
        }

        let legacy = try await db.terminals.get(id: id)
        #expect(legacy != nil)
        #expect(legacy?.isParked == true)
        #expect(legacy?.hibernateReason == nil)
    }

    /// Legacy JSON without the `hibernateReason` field (emitted by an older
    /// daemon/app over RPC) still decodes `Terminal`, with a nil reason — the
    /// custom `init(from:)` must use decodeIfPresent for the new key.
    @Test func legacyTerminalJSONWithoutReasonDecodes() throws {
        let json = """
            {
                "id": "\(UUID().uuidString)",
                "worktreeID": "\(UUID().uuidString)",
                "tmuxWindowID": "@1",
                "tmuxPaneID": "%1",
                "createdAt": 0,
                "hibernatedAt": 0
            }
            """
        let terminal = try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
        #expect(terminal.hibernateReason == nil)
        #expect(terminal.isParked == true)
    }

    /// The reason survives a JSON encode/decode round-trip (the RPC path the
    /// app reads terminals through), proving CodingKeys + encode + decode all
    /// carry the new field.
    @Test func hibernateReasonSurvivesJSONRoundTrip() throws {
        let original = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            hibernatedAt: Date(), hibernateReason: .manual)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Terminal.self, from: data)
        #expect(decoded.hibernateReason == .manual)
    }
}
