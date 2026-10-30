import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TestSupport

/// Turn-end lazy transcript sync, riding the `tbd notify` call the Stop
/// (`response_complete`) and StopFailure (`error`) hooks make: when a Claude
/// terminal's stored transcriptPath lies outside the project dir derived from
/// the worktree's CURRENT path, the jsonl (+ subagents) is mirrored into the
/// derived dir. Isolated entirely via the injectable
/// ClaudeProfileConfigDirManager seam — no TBD_HOME, no ~/.claude. One test per
/// branch of the sync conditional; a branch that syncs nothing is paired with
/// one that does, so it cannot pass on a router that never syncs.
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
            ),
            actuationLog: makeTestActuationLog()
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

    struct Fixture {
        let terminal: Terminal
        let worktreeID: UUID
        let transcript: URL
        let derived: URL

        var derivedTranscript: URL { derived.appendingPathComponent("sess-1.jsonl") }
    }

    /// Worktree + terminal whose stored transcript lives under an arbitrary
    /// project-dir name that differs from the derived one when
    /// `outsideDerivedDir` is true.
    private func makeFixture(
        outsideDerivedDir: Bool, kind: TerminalKind = .claude
    ) async throws -> Fixture {
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
            label: kind == .codex ? TerminalLabel.codex : "claude",
            claudeSessionID: kind == .codex ? nil : "sess-1", kind: kind)
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: "sess-1", transcriptPath: transcript.path)
        return Fixture(terminal: terminal, worktreeID: wt.id, transcript: transcript, derived: derived)
    }

    private func notify(
        _ type: NotificationType, worktreeID: UUID, terminalID: UUID?
    ) async throws -> RPCResponse {
        await router.handle(try RPCRequest(
            method: RPCMethod.notify,
            params: NotifyParams(
                worktreeID: worktreeID, type: type, message: "done", terminalID: terminalID)))
    }

    private func notify(_ type: NotificationType, _ fx: Fixture) async throws -> RPCResponse {
        try await notify(type, worktreeID: fx.worktreeID, terminalID: fx.terminal.id)
    }

    private func isSynced(_ fx: Fixture) -> Bool {
        FileManager.default.fileExists(atPath: fx.derivedTranscript.path)
    }

    @Test func responseCompleteSyncsTranscriptStoredOutsideDerivedDir() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let fx = try await makeFixture(outsideDerivedDir: true)

        let resp = try await notify(.responseComplete, fx)

        #expect(resp.success)
        #expect(try String(contentsOf: fx.derivedTranscript, encoding: .utf8) == "live transcript")
        #expect(try String(
            contentsOf: fx.derived.appendingPathComponent("sess-1/subagents/agent-a.jsonl"),
            encoding: .utf8) == "sub")
        // The live session's stored pointer is never rewritten.
        #expect(try await db.terminals.get(id: fx.terminal.id)?.transcriptPath == fx.transcript.path)
    }

    @Test func onlyTheTurnEndTypesSync() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let fx = try await makeFixture(outsideDerivedDir: true)

        #expect(try await notify(.taskComplete, fx).success)
        #expect(try await notify(.attentionNeeded, fx).success)
        #expect(!isSynced(fx))

        #expect(try await notify(.error, fx).success)
        #expect(isSynced(fx))
    }

    @Test func transcriptAlreadyInDerivedDirIsLeftAlone() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let inside = try await makeFixture(outsideDerivedDir: false)
        let outside = try await makeFixture(outsideDerivedDir: true)

        #expect(try await notify(.responseComplete, inside).success)
        #expect(try await notify(.responseComplete, outside).success)

        // Only the original artifacts exist in the derived dir — no self-copy.
        let entries = try FileManager.default.contentsOfDirectory(atPath: inside.derived.path).sorted()
        #expect(entries == ["sess-1", "sess-1.jsonl"])
        #expect(try String(contentsOf: inside.transcript, encoding: .utf8) == "live transcript")
        #expect(isSynced(outside))
    }

    @Test func aNotifyNamingNoTerminalDoesNotSync() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let fx = try await makeFixture(outsideDerivedDir: true)

        #expect(try await notify(.responseComplete, worktreeID: fx.worktreeID, terminalID: nil).success)
        #expect(!isSynced(fx))

        #expect(try await notify(.responseComplete, fx).success)
        #expect(isSynced(fx))
    }

    @Test func aCodexTerminalDoesNotSync() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = try await makeFixture(outsideDerivedDir: true, kind: .codex)
        let claude = try await makeFixture(outsideDerivedDir: true)

        #expect(try await notify(.responseComplete, codex).success)
        #expect(try await notify(.responseComplete, claude).success)

        #expect(!isSynced(codex))
        #expect(isSynced(claude))
    }

    @Test func noStoredTranscriptPathIsNoop() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let worktreePath = home.appendingPathComponent("wt-\(UUID().uuidString)").path
        let wt = try await db.worktrees.createScratch(
            name: "w", displayName: "w", path: worktreePath, tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-1", kind: .claude)
        let derived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: worktreePath, projectsRoot: ambientProjectsRoot)

        #expect(try await notify(.responseComplete, worktreeID: wt.id, terminalID: terminal.id).success)
        #expect(!FileManager.default.fileExists(atPath: derived.path))

        // Once the session reports a transcript outside the derived dir, the
        // same call syncs it.
        let transcript = ambientProjectsRoot
            .appendingPathComponent("-old-slug-\(UUID().uuidString)/sess-1.jsonl")
        try writeFile("live transcript", to: transcript)
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: "sess-1", transcriptPath: transcript.path)
        #expect(try await notify(.responseComplete, worktreeID: wt.id, terminalID: terminal.id).success)
        #expect(FileManager.default.fileExists(
            atPath: derived.appendingPathComponent("sess-1.jsonl").path))
    }
}
