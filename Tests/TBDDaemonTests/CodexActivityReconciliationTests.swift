import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

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
            startTime: Date(),
            actuationLog: makeTestActuationLog()
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
        try await db.terminals.setActivityState(id: terminal.id, activityState: .idle, source: .derived)

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

    // MARK: - The date seam on the two handlers that WRITE codex activity

    /// Pinned through the router's date seam, so each stored stamp is an exact
    /// assertion rather than a freshness window.
    static let observedAt = Date(timeIntervalSince1970: 1_781_234_567)

    /// A second router over the same database, with its `now` pinned.
    ///
    /// `setActivityState` defaults `observedAt` to a bare `Date()` **at the
    /// store**, so a handler that omits the argument mints a timestamp nothing
    /// outside the store can name. That is not a cosmetic difference: the stamp
    /// is *compared* — `SessionStateResolver` orders it against the
    /// awaiting-input stamp at rung 4 to decide which observation is newer — so
    /// per the root `CLAUDE.md` date-seam rule it is data, and it belongs on the
    /// router's seam like every sibling call site in this file.
    private func pinnedRouter() -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            now: { Self.observedAt },
            actuationLog: makeTestActuationLog())
    }

    @Test("terminal.sessionEvent stamps the codex idle observation from the router's date seam")
    func sessionEventStampsFromTheDateSeam() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-seam-repo-\(UUID().uuidString)",
            displayName: "car-seam-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-seam-wt-\(UUID().uuidString)", tmuxServer: "tbd-car-seam")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)

        let request = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id, sessionID: "codex-session",
                transcriptPath: nil, source: "SessionStart"))
        #expect(await pinnedRouter().handle(request).success)

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.activityState == .idle)
        #expect(after.activityStateObservedAt == Self.observedAt)
        #expect(after.observedActivity?.observedAt == Self.observedAt)
    }

    @Test("terminal.recreateWindow stamps the derived codex unknown from the router's date seam")
    func recreateWindowStampsFromTheDateSeam() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-car-recreate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try await db.repos.create(
            path: root.path, displayName: "car-recreate-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: root.path, tmuxServer: "tbd-car-recreate")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@old", tmuxPaneID: "%old",
            label: TerminalLabel.codex, kind: .codex)
        // A prior observation, so "the stamp moved" is a real claim rather than
        // a column that happened to be nil before and non-nil after.
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .hookEvent("TurnStart"),
            observedAt: Date(timeIntervalSince1970: 1_770_000_000))

        let router = pinnedRouter()
        router.codexExecutableResolver = { "/opt/test/bin/codex" }
        router.codexHomeEnsurer = { root.appendingPathComponent("codex-home", isDirectory: true) }

        let request = try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id))
        let response = await router.handle(request)
        #expect(response.success, "expected success; error: \(response.error ?? "nil")")

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.activityState == .unknown)
        #expect(after.activityStateObservedAt == Self.observedAt)
        #expect(after.observedActivity?.observedAt == Self.observedAt)
    }
}
