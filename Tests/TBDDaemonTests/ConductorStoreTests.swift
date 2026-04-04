import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

@Suite struct ConductorStoreTests {
    func makeDB() throws -> TBDDatabase {
        try TBDDatabase(inMemory: true)
    }

    @Test func createAndList() async throws {
        let db = try makeDB()
        let conductor = try await db.conductors.create(
            name: "test",
            repos: ["*"],
            heartbeatIntervalMinutes: 10
        )
        #expect(conductor.name == "test")
        #expect(conductor.repos == ["*"])

        let all = try await db.conductors.list()
        #expect(all.count == 1)
        #expect(all[0].name == "test")
    }

    @Test func getByName() async throws {
        let db = try makeDB()
        _ = try await db.conductors.create(name: "alpha", repos: ["*"], heartbeatIntervalMinutes: 10)
        let found = try await db.conductors.get(name: "alpha")
        #expect(found != nil)
        #expect(found?.name == "alpha")

        let notFound = try await db.conductors.get(name: "nope")
        #expect(notFound == nil)
    }

    @Test func delete() async throws {
        let db = try makeDB()
        let conductor = try await db.conductors.create(name: "doomed", repos: ["*"], heartbeatIntervalMinutes: 10)
        try await db.conductors.delete(id: conductor.id)
        let all = try await db.conductors.list()
        #expect(all.isEmpty)
    }

    @Test func duplicateNameFails() async throws {
        let db = try makeDB()
        _ = try await db.conductors.create(name: "unique", repos: ["*"], heartbeatIntervalMinutes: 10)
        do {
            _ = try await db.conductors.create(name: "unique", repos: ["*"], heartbeatIntervalMinutes: 10)
            Issue.record("Expected duplicate name to fail")
        } catch {
            // Expected — UNIQUE constraint on name
        }
    }

    @Test func syntheticRepoExists() async throws {
        let db = try makeDB()
        let repo = try await db.repos.get(id: TBDConstants.conductorsRepoID)
        #expect(repo != nil)
        #expect(repo?.displayName == "Conductors")
    }

    @Test func updateTerminalID() async throws {
        let db = try makeDB()

        // Create a repo and worktree so we can create a real terminal record
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@mock-0",
            tmuxPaneID: "%mock-0"
        )

        let conductor = try await db.conductors.create(name: "test", repos: ["*"], heartbeatIntervalMinutes: 10)
        try await db.conductors.updateTerminalID(conductorID: conductor.id, terminalID: terminal.id)
        let updated = try await db.conductors.get(name: "test")
        #expect(updated?.terminalID == terminal.id)
    }
}
