import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct LocalAgentSessionStoreTests {
    private func makeWorktree(_ db: TBDDatabase) async throws -> Worktree {
        try await db.worktrees.createScratch(name: "acme", displayName: "Acme",
            path: "/synthetic/\(UUID())", tmuxServer: "tbd-test")
    }

    @Test func upsertRefreshesAssociationAndPreservesOriginalIdentityAndFirstObservation() async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktree = try await makeWorktree(db)
        let firstTerminal = try await db.terminals.create(worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        let nextTerminal = try await db.terminals.create(worktreeID: worktree.id, tmuxWindowID: "@2", tmuxPaneID: "%2")
        let identity = AgentSessionIdentity(agentKind: .codex, sessionID: "same")
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let nextDate = firstDate.addingTimeInterval(30)
        let initial = LocalAgentSession(worktreeID: worktree.id, terminalID: firstTerminal.id,
            identity: identity, transcriptPath: "/synthetic/first.jsonl", codexLaunchOptions: nil,
            firstObservedAt: firstDate, lastObservedAt: firstDate)
        try await db.localAgentSessions.upsert(initial)
        let options = CodexLaunchOptions(model: "acme-model", codexHome: "/synthetic/codex")
        try await db.localAgentSessions.upsert(LocalAgentSession(worktreeID: worktree.id,
            terminalID: nextTerminal.id, identity: identity, transcriptPath: "/synthetic/next.jsonl",
            codexLaunchOptions: options, firstObservedAt: nextDate, lastObservedAt: nextDate))
        let read = try #require(try await db.localAgentSessions.get(worktreeID: worktree.id, identity: identity))
        #expect(read.id == initial.id)
        #expect(read.firstObservedAt == firstDate)
        #expect(read.lastObservedAt == nextDate)
        #expect(read.terminalID == nextTerminal.id)
        #expect(read.transcriptPath == "/synthetic/next.jsonl")
        #expect(read.codexLaunchOptions == options)
        #expect(try await db.localAgentSessions.list(worktreeID: worktree.id).count == 1)
        try await db.localAgentSessions.upsert(LocalAgentSession(worktreeID: worktree.id,
            terminalID: nil, identity: identity, transcriptPath: nil, codexLaunchOptions: nil,
            firstObservedAt: nextDate, lastObservedAt: nextDate))
        let cleared = try #require(try await db.localAgentSessions.get(worktreeID: worktree.id, identity: identity))
        #expect(cleared.terminalID == nil)
        #expect(cleared.transcriptPath == nil)
        #expect(cleared.codexLaunchOptions == nil)
    }

    @Test func worktreeAndProviderScopeSessionsAndDeletionRetainsOnlyOwnedHistory() async throws {
        let db = try TBDDatabase(inMemory: true)
        let first = try await makeWorktree(db)
        let second = try await makeWorktree(db)
        let terminal = try await db.terminals.create(worktreeID: first.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for (worktree, kind) in [(first, LocalAgentKind.claude), (first, .codex), (second, .codex)] {
            try await db.localAgentSessions.upsert(LocalAgentSession(worktreeID: worktree.id,
                terminalID: worktree.id == first.id ? terminal.id : nil,
                identity: AgentSessionIdentity(agentKind: kind, sessionID: "same"),
                transcriptPath: nil, codexLaunchOptions: nil, firstObservedAt: now, lastObservedAt: now))
        }
        #expect(try await db.localAgentSessions.list(worktreeID: first.id).count == 2)
        #expect(try await db.localAgentSessions.list(worktreeID: second.id).count == 1)
        try await db.terminals.delete(id: terminal.id)
        let retained = try await db.localAgentSessions.list(worktreeID: first.id)
        #expect(retained.count == 2)
        #expect(retained.allSatisfy { $0.terminalID == nil })
        try await db.worktrees.delete(id: first.id)
        #expect(try await db.localAgentSessions.list(worktreeID: first.id).isEmpty)
        #expect(try await db.localAgentSessions.list(worktreeID: second.id).count == 1)
    }

    @Test func malformedRowsDoNotHideValidHistory() async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktree = try await makeWorktree(db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let valid = LocalAgentSession(worktreeID: worktree.id, terminalID: nil,
            identity: AgentSessionIdentity(agentKind: .codex, sessionID: "valid"), transcriptPath: nil,
            codexLaunchOptions: nil, firstObservedAt: now, lastObservedAt: now)
        try await db.localAgentSessions.upsert(valid)
        try await db.writerForTests.write { conn in
            for (id, kind, session, options, date) in [
                ("invalid-uuid", "claude", "bad-id", "null", "2023-11-14 22:13:20.000"),
                (UUID().uuidString, "future-agent", "bad-kind", "null", "2023-11-14 22:13:20.000"),
                (UUID().uuidString, "codex", "bad-options", "not-json", "2023-11-14 22:13:20.000"),
                (UUID().uuidString, "claude", "bad-date", "null", "invalid-date")
            ] {
                try conn.execute(sql: """
                    INSERT INTO local_agent_session
                        (id, worktree_id, agent_kind, session_id, codex_launch_options, first_observed_at, last_observed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [id, worktree.id.uuidString, kind, session, options == "null" ? nil : options, date, date])
            }
        }
        #expect(try await db.localAgentSessions.list(worktreeID: worktree.id) == [valid])
        #expect(try await db.localAgentSessions.get(worktreeID: worktree.id,
            identity: AgentSessionIdentity(agentKind: .codex, sessionID: "bad-options")) == nil)
    }

    @Test func listsLegacyTextAndNumericObservationDatesChronologically() async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktree = try await makeWorktree(db)
        try await db.writerForTests.write { database in
            try database.execute(sql: """
                INSERT INTO local_agent_session
                    (id, worktree_id, agent_kind, session_id, first_observed_at, last_observed_at)
                VALUES (?, ?, 'claude', 'legacy', '2023-11-14 22:13:20.000', '2023-11-14 22:13:20.000'),
                       (?, ?, 'codex', 'numeric', 1800000000.000123, 1800000000.000123)
                """, arguments: [UUID().uuidString, worktree.id.uuidString, UUID().uuidString, worktree.id.uuidString])
        }
        let rows = try await db.localAgentSessions.list(worktreeID: worktree.id)
        #expect(rows.map(\.identity.sessionID) == ["legacy", "numeric"])
        #expect(rows.first?.firstObservedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(rows.last?.lastObservedAt == Date(timeIntervalSince1970: 1_800_000_000.000123))
    }

    @Test func archiveSnapshotSurvivesWorktreeRecordAndDatabase() async throws {
        let db = try TBDDatabase(inMemory: true)
        var worktree = try await makeWorktree(db)
        worktree.archivedAgentTabs = [ArchivedAgentTab(
            identity: AgentSessionIdentity(agentKind: .codex, sessionID: "thread"),
            label: "Acme", ordinal: 0, isPrimary: true, profileID: nil,
            claudeSpawnExtras: nil, codexLaunchOptions: CodexLaunchOptions(model: "acme-model"))]
        let record = WorktreeRecord(from: worktree)
        try await db.writerForTests.write { try record.update($0) }
        #expect(try await db.worktrees.get(id: worktree.id)?.archivedAgentTabs == worktree.archivedAgentTabs)
    }
}
