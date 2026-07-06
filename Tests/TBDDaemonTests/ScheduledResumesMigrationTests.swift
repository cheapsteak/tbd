import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct ScheduledResumesMigrationTests {

    @Test func scheduledResumesTableExists() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            #expect(try dbConn.tableExists("scheduled_resumes"))
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(scheduled_resumes)")
            let names = Set(columns.compactMap { $0["name"] as String? })
            #expect(names.isSuperset(of: [
                "id", "terminalID", "worktreeID", "claudeSessionID", "resetsAt",
                "fireAt", "limitType", "rawMessage", "createdAt", "status", "attemptCount"
            ]))
        }
    }

    @Test func terminalPendingResumeAtColumnExistsAndDefaultsNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(terminal)")
            let names = columns.compactMap { $0["name"] as String? }
            #expect(names.contains("pendingResumeAt"))
        }
        let repo = try await db.repos.create(
            path: "/tmp/v38-repo-\(UUID().uuidString)", displayName: "V38", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v38-wt-\(UUID().uuidString)", tmuxServer: "tbd-v38")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        #expect(terminal.pendingResumeAt == nil)
        let fetched = try await db.terminals.get(id: terminal.id)
        #expect(fetched?.pendingResumeAt == nil)
    }

    @Test func configAutoResumeDefaultsFalse() async throws {
        let db = try TBDDatabase(inMemory: true)
        let config = try await db.config.get()
        #expect(config.autoResumeOnLimitReset == false)
    }

    @Test func oldTerminalJSONStillDecodes() throws {
        // decode-compat rule: pre-v38 payloads have no pendingResumeAt.
        let json = """
        {"id":"\(UUID().uuidString)","worktreeID":"\(UUID().uuidString)",
         "tmuxWindowID":"@1","tmuxPaneID":"%1","createdAt":773400000,
         "activityState":"idle"}
        """
        let terminal = try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
        #expect(terminal.pendingResumeAt == nil)
    }
}
