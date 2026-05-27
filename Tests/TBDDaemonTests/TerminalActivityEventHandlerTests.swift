import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("terminal.activityEvent handler")
struct TerminalActivityEventHandlerTests {
    let db: TBDDatabase
    let router: RPCRouter

    init() throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date()
        )
    }

    private func makeTerminal() async throws -> Terminal {
        let repo = try await db.repos.create(
            path: "/tmp/ta-repo-\(UUID().uuidString)",
            displayName: "ta-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/ta-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-ta"
        )
        return try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex
        )
    }

    @Test("updates activity state in DB")
    func updatesActivityState() async throws {
        let terminal = try await makeTerminal()
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: terminal.id,
                activityState: .working
            )
        )

        let response = await router.handle(request)
        #expect(response.success)

        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.activityState == .working)
    }

    @Test("unknown terminalID is a soft no-op")
    func unknownTerminalSoftSuccess() async throws {
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: UUID(),
                activityState: .idle
            )
        )

        let response = await router.handle(request)
        #expect(response.success)
        #expect(response.error == nil)
    }
}
