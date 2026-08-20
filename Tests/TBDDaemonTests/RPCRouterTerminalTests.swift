import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

// Terminal-scoped RPC methods: terminal.create (shell + claude), terminal.list,
// terminal.send, terminal.output.
extension RPCRouterTests {

    // MARK: - Terminal Tests

    @Test("terminal.create and terminal.list work together")
    func terminalCreateAndList() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        // terminal.create refuses to spawn into a missing directory, so the
        // worktree path must actually exist on disk.
        let wtPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: wtPath, withIntermediateDirectories: true)
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: wtPath,
            tmuxServer: "tbd-test"
        )

        // Create a terminal
        let createReq = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, cmd: "vim")
        )
        let createResp = await router.handle(createReq)
        #expect(createResp.success)

        let terminal = try createResp.decodeResult(Terminal.self)
        #expect(terminal.worktreeID == wt.id)

        // List terminals
        let listReq = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id)
        )
        let listResp = await router.handle(listReq)
        #expect(listResp.success)

        let terminals = try listResp.decodeResult([Terminal].self)
        #expect(terminals.count == 1)
    }

    /// Thread-safe collector for tmux argv lists invoked during dryRun.
    private final class SendRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func record(_ args: [String]) {
            lock.lock(); defer { lock.unlock() }
            _calls.append(args)
        }
    }

    /// A router whose tmux records every dryRun argv, plus a seeded terminal to
    /// send to. Used by the bracketed-paste ordering tests below.
    private func makeRecorderFixture() async throws -> (RPCRouter, SendRecorder, Terminal) {
        let recorder = SendRecorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorder.record($0) })
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@mock-0",
            tmuxPaneID: "%mock-0"
        )
        return (router, recorder, terminal)
    }

    @Test("terminal.send with submit brackets the paste then presses Enter, in order")
    func terminalSendBracketedPasteThenEnter() async throws {
        let (router, recorder, terminal) = try await makeRecorderFixture()

        let request = try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id,
                text: "line one\nline two\nline three",
                submit: true
            )
        )
        #expect(await router.handle(request).success)

        let calls = recorder.calls
        let loadIdx = try #require(calls.firstIndex { $0.contains("load-buffer") })
        let pasteIdx = try #require(calls.firstIndex { $0.contains("paste-buffer") })
        let enterIdx = try #require(
            calls.firstIndex { $0.contains("send-keys") && $0.contains("Enter") })

        // Ordering: load the buffer, paste it, THEN press Enter.
        #expect(loadIdx < pasteIdx)
        #expect(pasteIdx < enterIdx)

        // The paste must use -p (bracketed-paste authority to tmux) and target
        // the pane; the Enter must NOT be part of the paste.
        let pasteArgs = calls[pasteIdx]
        #expect(pasteArgs.contains("-p"))
        #expect(pasteArgs.contains("-t"))
        #expect(pasteArgs.contains("%mock-0"))
    }

    @Test("terminal.send without submit does not press Enter")
    func terminalSendNoSubmitNoEnter() async throws {
        let (router, recorder, terminal) = try await makeRecorderFixture()

        let request = try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id,
                text: "line one\nline two",
                submit: false
            )
        )
        #expect(await router.handle(request).success)

        let calls = recorder.calls
        // Body still pasted...
        #expect(calls.contains { $0.contains("paste-buffer") })
        // ...but no Enter keystroke.
        #expect(!calls.contains { $0.contains("send-keys") && $0.contains("Enter") })
    }

    @Test("terminal.send with empty text and submit presses Enter but skips the paste")
    func terminalSendEmptyTextSubmitEnterOnly() async throws {
        let (router, recorder, terminal) = try await makeRecorderFixture()

        let request = try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminal.id, text: "", submit: true)
        )
        #expect(await router.handle(request).success)

        let calls = recorder.calls
        // Empty body → never load or paste an empty buffer...
        #expect(!calls.contains { $0.contains("load-buffer") })
        #expect(!calls.contains { $0.contains("paste-buffer") })
        // ...but a bare --submit still presses Enter.
        #expect(calls.contains { $0.contains("send-keys") && $0.contains("Enter") })
    }

    @Test("terminal.send dispatches to tmux")
    func terminalSend() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@mock-0",
            tmuxPaneID: "%mock-0"
        )

        let request = try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminal.id, text: "echo hello")
        )
        let response = await router.handle(request)

        // dryRun tmux should succeed
        #expect(response.success)
    }

    // MARK: - Claude Terminal Creation

    @Test("terminal.create with type claude sets label and sessionID")
    func terminalCreateClaude() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        // terminal.create refuses to spawn into a missing directory, so the
        // worktree path must actually exist on disk.
        let wtPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: wtPath, withIntermediateDirectories: true)
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: wtPath,
            tmuxServer: "tbd-test"
        )

        let createReq = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        )
        let createResp = await router.handle(createReq)
        #expect(createResp.success)

        let terminal = try createResp.decodeResult(Terminal.self)
        #expect(terminal.label == "Claude Code")
        #expect(terminal.claudeSessionID != nil)
    }

    // MARK: - Caller-supplied labels

    /// A `terminal.create` command doubles as the tab's title, so it is the one
    /// place caller text reaches a row's label. `TerminalLabel` names identities
    /// the daemon assigns and both sides of the socket read as such, so a
    /// command that spells one must not become one.
    private func makeLabelGuardWorktree() async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        // terminal.create refuses to spawn into a missing directory, so the
        // worktree path must actually exist on disk.
        let wtPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: wtPath, withIntermediateDirectories: true)
        return try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: wtPath,
            tmuxServer: "tbd-test"
        )
    }

    private func createTerminal(worktreeID: UUID, cmd: String) async throws -> Terminal {
        let request = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktreeID, cmd: cmd)
        )
        let response = await router.handle(request)
        #expect(response.success)
        return try response.decodeResult(Terminal.self)
    }

    @Test("terminal.create with a command naming the preSession hook does not read as a spawn still coming")
    func terminalCreateCmdCannotClaimPreSession() async throws {
        let wt = try await makeLabelGuardWorktree()
        let terminal = try await createTerminal(worktreeID: wt.id, cmd: TerminalLabel.preSession)
        #expect(terminal.label != TerminalLabel.preSession)
        #expect(terminal.label == nil)

        // Read the rows back the way every consumer does: this worktree's only
        // terminal is a shell somebody spawned, not a hook tab with an agent
        // still behind it, and a message parked on it would never be delivered.
        let listResponse = await router.handle(try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id)
        ))
        let rows = try listResponse.decodeResult([Terminal].self)
        #expect(rows.count == 1)
        #expect(PrimaryTerminal.spawnIsStillComing(terminals: rows) == false)
    }

    @Test("terminal.create with a command naming a login or agent identity does not claim it")
    func terminalCreateCmdCannotClaimOtherIdentities() async throws {
        let wt = try await makeLabelGuardWorktree()

        let login = try await createTerminal(worktreeID: wt.id, cmd: TerminalLabel.login)
        #expect(login.label == nil)

        let codex = try await createTerminal(worktreeID: wt.id, cmd: TerminalLabel.codex)
        #expect(codex.label == nil)
        #expect(codex.isCodexTerminal == false)

        let setup = try await createTerminal(worktreeID: wt.id, cmd: TerminalLabel.setup)
        #expect(setup.label == nil)
    }

    @Test("terminal.create keeps an ordinary command as the tab's label")
    func terminalCreateOrdinaryCmdKeepsItsLabel() async throws {
        let wt = try await makeLabelGuardWorktree()
        let terminal = try await createTerminal(worktreeID: wt.id, cmd: "vim")
        #expect(terminal.label == "vim")
        // Exact match, so a command that merely resembles an identity keeps it.
        let lowercased = try await createTerminal(worktreeID: wt.id, cmd: "codex")
        #expect(lowercased.label == "codex")
    }

    // MARK: - Terminal Output

    @Test("terminal.output returns error when terminal not found")
    func terminalOutputReturnsError_whenTerminalNotFound() async throws {
        let params = TerminalOutputParams(terminalID: UUID())
        let request = try RPCRequest(method: RPCMethod.terminalOutput, params: params)
        let response = await router.handle(request)
        #expect(!response.success)
        #expect(response.error?.contains("Terminal not found") == true)
    }
}
