import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("terminal.sessionEvent handler")
struct TerminalSessionEventHandlerTests {
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

    private func makeTerminal(initialSession: String? = nil) async throws -> (Terminal, Worktree) {
        let repo = try await db.repos.create(
            path: "/tmp/se-repo-\(UUID().uuidString)",
            displayName: "se-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/se-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-se"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "claude",
            claudeSessionID: initialSession
        )
        return (terminal, wt)
    }

    @Test("updates sessionID + transcriptPath and broadcasts delta")
    func updatesSessionAndBroadcasts() async throws {
        let (terminal, _) = try await makeTerminal(initialSession: "old-id")
        let request = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "new-id",
                transcriptPath: "/Users/me/.claude/projects/-x/new-id.jsonl",
                source: "clear"
            )
        )
        let response = await router.handle(request)
        #expect(response.success)

        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "new-id")
        #expect(updated?.transcriptPath == "/Users/me/.claude/projects/-x/new-id.jsonl")
    }

    @Test("ignores non-absolute transcriptPath but still updates sessionID")
    func ignoresNonAbsolutePath() async throws {
        let (terminal, _) = try await makeTerminal()
        let request = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "abc",
                transcriptPath: "relative/path.jsonl",
                source: "startup"
            )
        )
        _ = await router.handle(request)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "abc")
        #expect(updated?.transcriptPath == nil)
    }

    @Test("treats empty transcriptPath as not-provided")
    func treatsEmptyPathAsAbsent() async throws {
        let (terminal, _) = try await makeTerminal()
        let request = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "s",
                transcriptPath: "",
                source: nil
            )
        )
        _ = await router.handle(request)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "s")
        #expect(updated?.transcriptPath == nil)
    }

    @Test("unknown terminalID is a soft no-op (success, no error)")
    func unknownTerminalSoftSuccess() async throws {
        let request = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: UUID(),
                sessionID: "x",
                transcriptPath: nil,
                source: nil
            )
        )
        let response = await router.handle(request)
        #expect(response.success)
        #expect(response.error == nil)
    }

    @Test("transcript handler prefers stored transcriptPath over cwd resolution")
    func transcriptHandlerPrefersStoredPath() async throws {
        // Write a synthetic JSONL at a path the legacy cwd-derived resolution
        // would never find (a /tmp directory unrelated to the worktree path).
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-se-prefer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let storedPath = tmpDir.appendingPathComponent("session.jsonl").path
        // A minimal user message line so TranscriptParser produces at least one item.
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]},"uuid":"abc","timestamp":"2025-01-01T00:00:00Z"}"#
        try (line + "\n").data(using: .utf8)!.write(to: URL(fileURLWithPath: storedPath))

        let (terminal, _) = try await makeTerminal()

        // Tell the daemon about the stored path via sessionEvent.
        let evt = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "logical-session-id",
                transcriptPath: storedPath,
                source: "startup"
            )
        )
        _ = await router.handle(evt)

        // Now ask for the transcript — it should resolve via storedPath, not
        // via ClaudeProjectDirectory.resolve(worktreePath:) (which would fail
        // for our /tmp/se-wt-* path since no ~/.claude/projects/ entry exists).
        let req = try RPCRequest(
            method: RPCMethod.terminalTranscript,
            params: TerminalTranscriptParams(terminalID: terminal.id)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(TerminalTranscriptResult.self)
        #expect(result.sessionID == "logical-session-id")
        #expect(!result.messages.isEmpty)
    }
}
