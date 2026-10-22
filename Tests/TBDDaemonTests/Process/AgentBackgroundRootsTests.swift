import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Which tabs `AgentBackgroundRoots` names, against a fake process table.
/// Holder tabs, so the roots come from the recorded job without a tmux server.
@Suite("AgentBackgroundRoots")
struct AgentBackgroundRootsTests {

    private static let holderPID: pid_t = 900_100

    /// A holder row whose recorded job is a live child of its holder and was
    /// started at the row's creation, the shape `holderJob` trusts.
    private func addHolderTab(
        _ db: TBDDatabase, _ fake: FakeProcessPriority, worktree: Worktree,
        index: Int, kind: TerminalKind?, label: String? = nil, parked: Bool = false
    ) async throws -> pid_t {
        let holder = Self.holderPID + pid_t(index * 2)
        let job = holder + 1
        let micros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        fake.add(holder, parent: 1, start: micros)
        fake.add(job, parent: holder, start: micros)
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@\(index)", tmuxPaneID: "%\(index)",
            label: label, claudeSessionID: parked ? "session-\(index)" : nil, kind: kind,
            transport: .holder, holderPID: holder, childPID: job)
        if parked {
            try await db.terminals.setHibernated(id: terminal.id, sessionID: "session-\(index)")
        }
        return job
    }

    @Test("claude, codex and unrecorded-kind tabs are roots; shells and parked tabs are not")
    func rootsByKind() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
        let fake = FakeProcessPriority()

        let claude = try await addHolderTab(db, fake, worktree: worktree, index: 1, kind: .claude)
        let codex = try await addHolderTab(db, fake, worktree: worktree, index: 2, kind: .codex)
        // A row written before kinds were recorded is Claude's.
        let legacy = try await addHolderTab(db, fake, worktree: worktree, index: 3, kind: nil)
        _ = try await addHolderTab(db, fake, worktree: worktree, index: 4, kind: .shell)
        _ = try await addHolderTab(
            db, fake, worktree: worktree, index: 5, kind: .claude, parked: true)

        let roots = AgentBackgroundRoots(
            database: db, tmux: TmuxManager(dryRun: true), priority: fake)
        let resolved = await roots.resolve()

        #expect(Set(resolved) == [claude, codex, legacy])
        #expect(resolved.count == 3)
    }
}
