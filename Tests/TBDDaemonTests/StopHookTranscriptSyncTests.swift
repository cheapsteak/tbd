import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Stop-hook (activity → idle) lazy transcript sync: when a terminal's stored
/// transcriptPath lies outside the project dir derived from the worktree's
/// CURRENT path, the jsonl (+ subagents) is mirrored into the derived dir.
/// Isolated entirely via the injectable ClaudeProfileConfigDirManager seam —
/// no TBD_HOME, no ~/.claude. One test per branch of the sync conditional.
@Suite("Stop-hook transcript sync")
struct StopHookTranscriptSyncTests {
    let home: URL
    let db: TBDDatabase
    let router: RPCRouter

    init() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-stopsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        self.home = home
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            configDirManager: ClaudeProfileConfigDirManager(
                baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
                hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true)
            )
        )
    }

    private var ambientProjectsRoot: URL {
        home.appendingPathComponent("claude-host/projects", isDirectory: true)
    }

    private func writeFile(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Worktree + terminal whose stored transcript lives under `slug` (an
    /// arbitrary project-dir name that differs from the derived one when
    /// `outsideDerivedDir` is true).
    private func makeFixture(outsideDerivedDir: Bool) async throws
        -> (terminal: Terminal, worktreePath: String, transcript: URL, derived: URL) {
        let worktreePath = home.appendingPathComponent("wt-\(UUID().uuidString)").path
        let wt = try await db.worktrees.createScratch(
            name: "w", displayName: "w", path: worktreePath, tmuxServer: "tbd-test")
        let derived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: worktreePath, projectsRoot: ambientProjectsRoot)
        let transcript = outsideDerivedDir
            ? ambientProjectsRoot.appendingPathComponent("-old-slug-\(UUID().uuidString)/sess-1.jsonl")
            : derived.appendingPathComponent("sess-1.jsonl")
        try writeFile("live transcript", to: transcript)
        try writeFile(
            "sub", to: transcript.deletingLastPathComponent()
                .appendingPathComponent("sess-1/subagents/agent-a.jsonl"))
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-1", kind: .claude)
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: "sess-1", transcriptPath: transcript.path)
        return (terminal, worktreePath, transcript, derived)
    }

    private func send(_ terminalID: UUID, _ state: TerminalActivityState) async throws -> RPCResponse {
        await router.handle(try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: terminalID, activityState: state)))
    }

    @Test func idleSyncsTranscriptStoredOutsideDerivedDir() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let fx = try await makeFixture(outsideDerivedDir: true)

        let resp = try await send(fx.terminal.id, .idle)

        #expect(resp.success)
        #expect(try String(
            contentsOf: fx.derived.appendingPathComponent("sess-1.jsonl"), encoding: .utf8)
            == "live transcript")
        #expect(try String(
            contentsOf: fx.derived.appendingPathComponent("sess-1/subagents/agent-a.jsonl"),
            encoding: .utf8) == "sub")
        // The live session's stored pointer is never rewritten.
        #expect(try await db.terminals.get(id: fx.terminal.id)?.transcriptPath == fx.transcript.path)
    }

    @Test func idleWithTranscriptAlreadyInDerivedDirIsNoop() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let fx = try await makeFixture(outsideDerivedDir: false)

        let resp = try await send(fx.terminal.id, .idle)

        #expect(resp.success)
        // Only the original artifacts exist in the derived dir — no self-copy.
        let entries = try FileManager.default.contentsOfDirectory(atPath: fx.derived.path).sorted()
        #expect(entries == ["sess-1", "sess-1.jsonl"])
        #expect(try String(contentsOf: fx.transcript, encoding: .utf8) == "live transcript")
    }

    @Test func nonIdleActivityDoesNotSync() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let fx = try await makeFixture(outsideDerivedDir: true)

        let resp = try await send(fx.terminal.id, .working)

        #expect(resp.success)
        #expect(!FileManager.default.fileExists(
            atPath: fx.derived.appendingPathComponent("sess-1.jsonl").path))
    }

    @Test func idleWithoutStoredTranscriptPathIsNoop() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let worktreePath = home.appendingPathComponent("wt-\(UUID().uuidString)").path
        let wt = try await db.worktrees.createScratch(
            name: "w", displayName: "w", path: worktreePath, tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-1", kind: .claude)

        let resp = try await send(terminal.id, .idle)

        #expect(resp.success)
        let derived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: worktreePath, projectsRoot: ambientProjectsRoot)
        #expect(!FileManager.default.fileExists(atPath: derived.path))
    }
}
