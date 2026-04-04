import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

@Suite struct ConductorManagerTests {
    func makeDB() throws -> TBDDatabase {
        try TBDDatabase(inMemory: true)
    }

    @Test func setupCreatesDirectoryAndDBRow() async throws {
        let db = try makeDB()
        let tmux = TmuxManager(dryRun: true)
        let manager = ConductorManager(db: db, tmux: tmux)

        let conductor = try await manager.setup(
            name: "test",
            repos: ["*"],
            heartbeatIntervalMinutes: 10
        )
        #expect(conductor.name == "test")

        // Verify DB row
        let found = try await db.conductors.get(name: "test")
        #expect(found != nil)

        // Verify synthetic worktree
        #expect(conductor.worktreeID != nil)
        let wt = try await db.worktrees.get(id: conductor.worktreeID!)
        #expect(wt?.status == .conductor)
        #expect(wt?.branch == "conductor")

        // Verify directory exists
        let dirPath = TBDConstants.conductorsDir.appendingPathComponent("test").path
        #expect(FileManager.default.fileExists(atPath: dirPath))

        // Verify CLAUDE.md exists
        let claudePath = TBDConstants.conductorsDir
            .appendingPathComponent("test")
            .appendingPathComponent("CLAUDE.md").path
        #expect(FileManager.default.fileExists(atPath: claudePath))

        // Cleanup
        try? FileManager.default.removeItem(atPath: dirPath)
    }

    @Test func teardownRemovesEverything() async throws {
        let db = try makeDB()
        let tmux = TmuxManager(dryRun: true)
        let manager = ConductorManager(db: db, tmux: tmux)

        let conductor = try await manager.setup(name: "doomed", repos: ["*"], heartbeatIntervalMinutes: 10)
        try await manager.teardown(name: "doomed")

        let found = try await db.conductors.get(name: "doomed")
        #expect(found == nil)

        // Synthetic worktree should be gone
        let wt = try await db.worktrees.get(id: conductor.worktreeID!)
        #expect(wt == nil)

        // Directory should be gone
        let dirPath = TBDConstants.conductorsDir.appendingPathComponent("doomed").path
        #expect(!FileManager.default.fileExists(atPath: dirPath))
    }

    @Test func templateContainsConductorName() async throws {
        let template = ConductorManager.generateTemplate(
            name: "my-conductor",
            repos: ["*"]
        )
        #expect(template.contains("Conductor: my-conductor"))
        #expect(template.contains("tbd terminal output"))
        #expect(template.contains("tbd conductor suggest my-conductor"))
        #expect(template.contains("tbd conductor clear-suggestion my-conductor"))
    }

    @Test func suggestAndClearSuggestion() async throws {
        let db = try makeDB()
        let tmux = TmuxManager(dryRun: true)
        let manager = ConductorManager(db: db, tmux: tmux)

        let conductor = try await manager.setup(name: "test-suggest", repos: ["*"])
        defer { try? FileManager.default.removeItem(at: TBDConstants.conductorsDir.appendingPathComponent("test-suggest")) }

        // Create a worktree to suggest
        let wt = try await db.worktrees.create(
            repoID: TBDConstants.conductorsRepoID,
            name: "fake-wt",
            branch: "main",
            path: "/tmp/fake",
            tmuxServer: "test",
            status: .active
        )

        // No suggestion initially
        #expect(manager.suggestion(for: "test-suggest") == nil)

        // Set suggestion
        try await manager.suggest(name: "test-suggest", worktreeID: wt.id, worktreeName: "fake-wt", label: "waiting")
        let s = manager.suggestion(for: "test-suggest")
        #expect(s?.worktreeID == wt.id)
        #expect(s?.label == "waiting")

        // Overwrite suggestion
        try await manager.suggest(name: "test-suggest", worktreeID: wt.id, worktreeName: "fake-wt", label: "new label")
        #expect(manager.suggestion(for: "test-suggest")?.label == "new label")

        // Clear
        try await manager.clearSuggestion(name: "test-suggest")
        #expect(manager.suggestion(for: "test-suggest") == nil)
    }

    @Test func suggestForNonexistentConductorFails() async throws {
        let db = try makeDB()
        let tmux = TmuxManager(dryRun: true)
        let manager = ConductorManager(db: db, tmux: tmux)

        do {
            try await manager.suggest(name: "nope", worktreeID: UUID(), worktreeName: "x", label: nil)
            Issue.record("Expected not found error")
        } catch {
            #expect(error.localizedDescription.contains("not found"))
        }
    }

    @Test func invalidNameRejected() async throws {
        let db = try makeDB()
        let tmux = TmuxManager(dryRun: true)
        let manager = ConductorManager(db: db, tmux: tmux)

        // Empty name
        do {
            _ = try await manager.setup(name: "")
            Issue.record("Expected invalid name error")
        } catch {
            #expect(error.localizedDescription.contains("Invalid conductor name"))
        }

        // Name starting with hyphen
        do {
            _ = try await manager.setup(name: "-bad")
            Issue.record("Expected invalid name error")
        } catch {
            #expect(error.localizedDescription.contains("Invalid conductor name"))
        }

        // Name with slash (path traversal)
        do {
            _ = try await manager.setup(name: "../escape")
            Issue.record("Expected invalid name error")
        } catch {
            #expect(error.localizedDescription.contains("Invalid conductor name"))
        }

        // Name too long
        do {
            _ = try await manager.setup(name: String(repeating: "a", count: 65))
            Issue.record("Expected invalid name error")
        } catch {
            #expect(error.localizedDescription.contains("Invalid conductor name"))
        }

        // Valid name should work
        let conductor = try await manager.setup(name: "valid-Name_123")
        #expect(conductor.name == "valid-Name_123")
        try? FileManager.default.removeItem(at: TBDConstants.conductorsDir.appendingPathComponent("valid-Name_123"))
    }
}
