import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV17Tests {

    @Test func v17AddsNullableTranscriptPathColumn() async throws {
        let db = try TBDDatabase(inMemory: true)
        // Create a repo + worktree + terminal to verify the new column exists
        // and round-trips through the GRDB record.
        let repo = try await db.repos.create(
            path: "/tmp/v17-repo", displayName: "V17", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v17-repo/wt", tmuxServer: "tbd-v17"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude"
        )
        // New column should default to nil for pre-existing inserts.
        let fetched = try await db.terminals.get(id: terminal.id)
        #expect(fetched?.transcriptPath == nil)
    }

    @Test func updateSessionPersistsTranscriptPath() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v17b-repo", displayName: "V17b", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v17b-repo/wt", tmuxServer: "tbd-v17b"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude",
            claudeSessionID: "old-session"
        )
        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: "new-session",
            transcriptPath: "/Users/me/.claude/projects/-x/new.jsonl"
        )
        let fetched = try await db.terminals.get(id: terminal.id)
        #expect(fetched?.claudeSessionID == "new-session")
        #expect(fetched?.transcriptPath == "/Users/me/.claude/projects/-x/new.jsonl")
    }

    @Test func updateSessionWithNilTranscriptPathClearsIt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v17c-repo", displayName: "V17c", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v17c-repo/wt", tmuxServer: "tbd-v17c"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1", tmuxPaneID: "%1"
        )
        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: "s1",
            transcriptPath: "/tmp/path1.jsonl"
        )
        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: "s2",
            transcriptPath: nil
        )
        let fetched = try await db.terminals.get(id: terminal.id)
        #expect(fetched?.claudeSessionID == "s2")
        #expect(fetched?.transcriptPath == nil)
    }
}
