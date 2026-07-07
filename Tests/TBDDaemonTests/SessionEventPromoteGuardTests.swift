import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// SessionStart ownership guard after scratch promotion: the promoted
/// session's own events (cwd now resolves to the new repo's main worktree)
/// must be accepted, while genuinely foreign sessions stay rejected.
/// DB-only — no paths need to exist on disk. One test per branch of the
/// promoted-main acceptance conditional.
extension RPCRouterTests {

    private func sessionEvent(terminalID: UUID, cwd: String) throws -> RPCRequest {
        try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminalID, sessionID: "new-session",
                transcriptPath: "/abs/new-session.jsonl", source: "startup", cwd: cwd))
    }

    /// Scratch row (with a terminal) promoted to a repo whose main worktree
    /// lives at `repoPath`.
    private func makePromotedFixture() async throws
        -> (terminal: Terminal, repoID: UUID, repoPath: String, scratchPath: String) {
        let scratchPath = "/tmp/fake-scratch-\(UUID().uuidString)"
        let scratch = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: scratchPath, tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: scratch.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "old-session", kind: .claude)
        let repoPath = "/tmp/fake-repo-\(UUID().uuidString)"
        let repo = try await db.repos.create(
            path: repoPath, displayName: "r", defaultBranch: "main")
        _ = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoPath, tmuxServer: "tbd-r")
        try await db.worktrees.setPromotedToRepoID(id: scratch.id, repoID: repo.id)
        return (terminal, repo.id, repoPath, scratchPath)
    }

    @Test func sessionEventAcceptsCwdResolvingToPromotedRepoMainWorktree() async throws {
        let fx = try await makePromotedFixture()

        let resp = await router.handle(try sessionEvent(terminalID: fx.terminal.id, cwd: fx.repoPath))

        #expect(resp.success)
        let updated = try await db.terminals.get(id: fx.terminal.id)
        #expect(updated?.claudeSessionID == "new-session")
        #expect(updated?.transcriptPath == "/abs/new-session.jsonl")
    }

    @Test func sessionEventStillAcceptsOwnWorktreeCwd() async throws {
        let fx = try await makePromotedFixture()

        let resp = await router.handle(try sessionEvent(terminalID: fx.terminal.id, cwd: fx.scratchPath))

        #expect(resp.success)
        #expect(try await db.terminals.get(id: fx.terminal.id)?.claudeSessionID == "new-session")
    }

    @Test func sessionEventRejectsCwdOfUnrelatedRepo() async throws {
        let fx = try await makePromotedFixture()
        // A different repo with its own main worktree — repoID doesn't match
        // the terminal's worktree's promotedToRepoID.
        let otherPath = "/tmp/fake-other-repo-\(UUID().uuidString)"
        let other = try await db.repos.create(
            path: otherPath, displayName: "o", defaultBranch: "main")
        _ = try await db.worktrees.createMain(
            repoID: other.id, name: "main", branch: "main", path: otherPath, tmuxServer: "tbd-o")

        let resp = await router.handle(try sessionEvent(terminalID: fx.terminal.id, cwd: otherPath))

        #expect(resp.success)  // soft no-op, but the pointer must not move
        #expect(try await db.terminals.get(id: fx.terminal.id)?.claudeSessionID == "old-session")
    }

    @Test func sessionEventRejectsNonMainWorktreeOfPromotedRepo() async throws {
        let fx = try await makePromotedFixture()
        // An ACTIVE (non-main) worktree of the promoted repo: repoID matches
        // but status != .main — must still be rejected.
        let branchPath = "/tmp/fake-branch-wt-\(UUID().uuidString)"
        _ = try await db.worktrees.create(
            repoID: fx.repoID, name: "feature", branch: "feature",
            path: branchPath, tmuxServer: "tbd-r")

        let resp = await router.handle(try sessionEvent(terminalID: fx.terminal.id, cwd: branchPath))

        #expect(resp.success)
        #expect(try await db.terminals.get(id: fx.terminal.id)?.claudeSessionID == "old-session")
    }

    @Test func sessionEventRejectsForeignCwdWhenWorktreeNotPromoted() async throws {
        // Terminal under a PLAIN scratch row (no promotedToRepoID): the
        // acceptance never engages and foreign cwds stay rejected.
        let scratch = try await db.worktrees.createScratch(
            name: "plain", displayName: "plain",
            path: "/tmp/fake-plain-\(UUID().uuidString)", tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: scratch.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "old-session", kind: .claude)
        let repoPath = "/tmp/fake-repo-\(UUID().uuidString)"
        let repo = try await db.repos.create(
            path: repoPath, displayName: "r", defaultBranch: "main")
        _ = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoPath, tmuxServer: "tbd-r")

        let resp = await router.handle(try sessionEvent(terminalID: terminal.id, cwd: repoPath))

        #expect(resp.success)
        #expect(try await db.terminals.get(id: terminal.id)?.claudeSessionID == "old-session")
    }
}
