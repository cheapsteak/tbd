import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct MigrationV22Tests {

    @Test func v22ColumnExistsAndDefaultsToNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v22-repo", displayName: "V22", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v22-repo/wt", tmuxServer: "tbd-v22"
        )

        // Create a terminal without specifying kind — should round-trip as nil
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "1",
            tmuxPaneID: "1.0",
            label: "test"
        )

        // Verify kind defaults to nil when not specified
        let fetched = try await db.terminals.get(id: terminal.id)
        #expect(fetched?.kind == nil)
    }

    @Test func codexKindRoundTrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v22b-repo", displayName: "V22b", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v22b-repo/wt", tmuxServer: "tbd-v22b"
        )

        // Create a codex terminal with explicit kind
        let codexTerminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "2",
            tmuxPaneID: "2.0",
            label: "Codex",
            kind: .codex
        )

        let fetched = try await db.terminals.get(id: codexTerminal.id)
        #expect(fetched?.kind == .codex)
    }

    @Test func claudeKindRoundTrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v22c-repo", displayName: "V22c", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v22c-repo/wt", tmuxServer: "tbd-v22c"
        )

        // Create a claude terminal with explicit kind
        let claudeTerminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "3",
            tmuxPaneID: "3.0",
            label: "Claude Code",
            claudeSessionID: "session-123",
            kind: .claude
        )

        let fetched = try await db.terminals.get(id: claudeTerminal.id)
        #expect(fetched?.kind == .claude)
    }

    @Test func shellKindRoundTrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v22d-repo", displayName: "V22d", defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/v22d-repo/wt", tmuxServer: "tbd-v22d"
        )

        // Create a shell terminal with explicit kind
        let shellTerminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "4",
            tmuxPaneID: "4.0",
            label: "setup",
            kind: .shell
        )

        let fetched = try await db.terminals.get(id: shellTerminal.id)
        #expect(fetched?.kind == .shell)
    }
}
