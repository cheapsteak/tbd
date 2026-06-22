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

    /// Creates a second, independent worktree (different path) so we can
    /// simulate a foreign Claude session whose cwd lives elsewhere.
    private func makeForeignWorktree() async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/se-foreign-repo-\(UUID().uuidString)",
            displayName: "acme-prod",
            defaultBranch: "main"
        )
        return try await db.worktrees.create(
            repoID: repo.id,
            name: "acme-prod-wt",
            branch: "main",
            path: "/tmp/se-foreign-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-se-foreign"
        )
    }

    @Test("updates sessionID + transcriptPath in DB on a fresh SessionStart")
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

    @Test("nil/rejected transcriptPath preserves a previously-stored path")
    func nilPathPreservesExisting() async throws {
        let (terminal, _) = try await makeTerminal()
        // First event sets a valid path.
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "s1",
                transcriptPath: "/abs/s1.jsonl",
                source: "startup"
            )
        ))
        // Second event has a rejected (non-absolute) path. sessionID
        // updates; transcriptPath stays at the previously-stored value
        // rather than getting zeroed back to nil.
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "s2",
                transcriptPath: "relative/path.jsonl",
                source: "clear"
            )
        ))
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "s2")
        #expect(updated?.transcriptPath == "/abs/s1.jsonl")
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

    // MARK: - Worktree-ownership guard (foreign-session hijack defense)

    @Test("guard ACCEPTS event whose cwd resolves to the terminal's worktree")
    func guardAcceptsMatchingWorktreeCwd() async throws {
        let (terminal, wt) = try await makeTerminal(initialSession: "old-id")
        // A cwd nested inside the terminal's own worktree path.
        let cwd = wt.path + "/Sources/Foo"
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "real-session",
                transcriptPath: "/abs/real-session.jsonl",
                source: "startup",
                cwd: cwd
            )
        ))
        #expect(response.success)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "real-session")
        #expect(updated?.transcriptPath == "/abs/real-session.jsonl")
    }

    @Test("guard REJECTS event whose cwd resolves to a DIFFERENT worktree")
    func guardRejectsForeignWorktreeCwd() async throws {
        let (terminal, _) = try await makeTerminal(initialSession: "old-id")
        let foreign = try await makeForeignWorktree()
        // Foreign teammate session inherited TBD_TERMINAL_ID but runs in a
        // different worktree's directory.
        let cwd = foreign.path + "/subdir"
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "foreign-session",
                transcriptPath: "/abs/foreign-session.jsonl",
                source: "startup",
                cwd: cwd
            )
        ))
        // Soft success (fire-and-forget hook) but the pointer is unchanged.
        #expect(response.success)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "old-id")
        #expect(updated?.transcriptPath == nil)
    }

    @Test("guard REJECTS event whose cwd resolves to NO known worktree")
    func guardRejectsUnknownCwd() async throws {
        let (terminal, _) = try await makeTerminal(initialSession: "old-id")
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "stray-session",
                transcriptPath: nil,
                source: "startup",
                cwd: "/tmp/se-unrelated-\(UUID().uuidString)/nope"
            )
        ))
        #expect(response.success)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "old-id")
    }

    @Test("guard is bypassed when cwd is absent (backward compatibility)")
    func guardBypassedWhenCwdAbsent() async throws {
        let (terminal, _) = try await makeTerminal(initialSession: "old-id")
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "no-cwd-session",
                transcriptPath: nil,
                source: "startup",
                cwd: nil
            )
        ))
        #expect(response.success)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "no-cwd-session")
    }

    @Test("self-heal: a terminal stuck on a foreign pointer recovers on the next valid SessionStart")
    func selfHealRecoversFromForeignPointer() async throws {
        // Terminal is already hijacked: its stored session is foreign.
        let (terminal, wt) = try await makeTerminal(initialSession: "foreign-2907c5ee")
        // The terminal's REAL Claude fires its own SessionStart with a cwd
        // inside the terminal's own worktree — this must be accepted and must
        // overwrite the foreign pointer.
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "real-session-after-heal",
                transcriptPath: "/abs/real.jsonl",
                source: "resume",
                cwd: wt.path
            )
        ))
        #expect(response.success)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "real-session-after-heal")
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
