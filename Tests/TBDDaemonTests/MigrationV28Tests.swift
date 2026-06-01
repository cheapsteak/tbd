import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib

@Suite struct MigrationV28Tests {

    @Test func activityStateColumnExists() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let columns = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(terminal)")
            let names = columns.compactMap { $0["name"] as String? }
            #expect(names.contains("activityState"))
        }
    }

    @Test func activityStateDefaultsToUnknown() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v28-repo-\(UUID().uuidString)",
            displayName: "V28",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "w",
            branch: "b",
            path: "/tmp/v28-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-v28"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1"
        )

        #expect(terminal.activityState == .unknown)

        let fetched = try await db.terminals.get(id: terminal.id)
        #expect(fetched?.activityState == .unknown)
    }
}
