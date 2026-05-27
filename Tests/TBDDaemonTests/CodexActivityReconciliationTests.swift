import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("codex activity reconciliation")
struct CodexActivityReconciliationTests {
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

    @Test("terminal.list does not infer codex activity from transcript path")
    func terminalListDoesNotReconcileActivity() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-repo-\(UUID().uuidString)",
            displayName: "car-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/car-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car"
        )

        let transcriptDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-codex-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: transcriptDir) }

        let transcriptPath = transcriptDir.appendingPathComponent("session.jsonl")
        let jsonl = """
        {"timestamp":"2026-05-26T13:20:25.252Z","type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}
        """
        try jsonl.write(to: transcriptPath, atomically: true, encoding: .utf8)

        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex
        )
        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: "codex-session",
            transcriptPath: transcriptPath.path
        )

        let request = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id)
        )
        let response = await router.handle(request)
        #expect(response.success)

        let terminals = try response.decodeResult([Terminal].self)
        #expect(terminals.count == 1)
        #expect(terminals[0].activityState == .unknown)

        let persisted = try await db.terminals.get(id: terminal.id)
        #expect(persisted?.activityState == .unknown)
    }

    @Test("terminal.list does not overwrite explicit idle with transcript working")
    func terminalListPreservesExplicitIdle() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-idle-repo-\(UUID().uuidString)",
            displayName: "car-idle-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/car-idle-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-idle"
        )

        let transcriptDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-codex-activity-idle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: transcriptDir) }

        let transcriptPath = transcriptDir.appendingPathComponent("session.jsonl")
        let jsonl = """
        {"timestamp":"2026-05-26T13:20:25.252Z","type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}
        """
        try jsonl.write(to: transcriptPath, atomically: true, encoding: .utf8)

        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex
        )
        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: "codex-session",
            transcriptPath: transcriptPath.path
        )
        try await db.terminals.setActivityState(id: terminal.id, activityState: .idle)

        let request = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id)
        )
        let response = await router.handle(request)
        #expect(response.success)

        let terminals = try response.decodeResult([Terminal].self)
        #expect(terminals.count == 1)
        #expect(terminals[0].activityState == .idle)

        let persisted = try await db.terminals.get(id: terminal.id)
        #expect(persisted?.activityState == .idle)
    }
}
