import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

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
            startTime: Date()
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

    // MARK: - Verify-and-Retry Tests (Option 3)

    /// Thread-safe counter for tracking capturePaneOutput calls.
    private final class CaptureCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private var _responses: [String] = []

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }

        func nextResponse() -> String {
            lock.lock(); defer { lock.unlock() }
            defer { _count += 1 }
            guard _count < _responses.count else { return "" }
            return _responses[_count]
        }

        func setUp(responses: [String]) {
            lock.lock(); defer { lock.unlock() }
            _responses = responses
            _count = 0
        }
    }

    @Test("terminal.send with submit and text: stuck-then-cleared scenario retries and succeeds")
    func terminalSendSubmitStuckThenCleared() async throws {
        let recorder = SendRecorder()
        let captureCounter = CaptureCounter()
        let stuckComposer = "some transcript\n❯ [Pasted text #1 +25 lines]\n──\n  footer"
        let clearedComposer = "some transcript\n❯ \n──\n  footer"
        captureCounter.setUp(responses: [stuckComposer, clearedComposer])

        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            dryRunCapturePane: { _, _ in captureCounter.nextResponse() }
        )
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            submitVerifyDelays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)]
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

        let request = try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id,
                text: "long message here",
                submit: true
            )
        )
        #expect(await router.handle(request).success)

        // Exactly 2 Enter keystrokes: initial submit + 1 retry (stuck then cleared)
        let enterCalls = recorder.calls.filter { $0.contains("send-keys") && $0.contains("Enter") }
        #expect(enterCalls.count == 2)

        // The first Enter comes after paste-buffer (initial submit, no retry yet)
        let pasteIdx = try #require(recorder.calls.firstIndex { $0.contains("paste-buffer") })
        let firstEnterIdx = try #require(recorder.calls.firstIndex { $0.contains("send-keys") && $0.contains("Enter") })
        #expect(pasteIdx < firstEnterIdx)

        // Two capture calls: first returns stuck, second returns cleared
        #expect(captureCounter.count == 2)
    }

    @Test("terminal.send with submit and text: clean first verify (no retry needed)")
    func terminalSendSubmitCleanFirstVerify() async throws {
        let recorder = SendRecorder()
        let captureCounter = CaptureCounter()
        let clearedComposer = "some transcript\n❯ \n──\n  footer"
        captureCounter.setUp(responses: [clearedComposer])

        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            dryRunCapturePane: { _, _ in captureCounter.nextResponse() }
        )
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            submitVerifyDelays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)]
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

        let request = try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id,
                text: "long message here",
                submit: true
            )
        )
        #expect(await router.handle(request).success)

        // Verify the capture command used -J for joined wrapped lines
        #expect(recorder.calls.contains { $0.contains("capture-pane") && $0.contains("-J") })

        // Only one capture call: composer was clear on first check
        #expect(captureCounter.count == 1)
    }

    @Test("terminal.send with submit and text: never clears (bounded retries)")
    func terminalSendSubmitNeverClears() async throws {
        let recorder = SendRecorder()
        let captureCounter = CaptureCounter()
        let stuckComposer = "some transcript\n❯ [Pasted text #1 +25 lines]\n──\n  footer"
        // Setup stuck responses — more than the retry schedule to ensure they stay stuck
        // even if the test is modified later. With 3-delay schedule, provide at least 3.
        captureCounter.setUp(responses: [stuckComposer, stuckComposer, stuckComposer, stuckComposer, stuckComposer])

        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            dryRunCapturePane: { _, _ in captureCounter.nextResponse() }
        )
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            submitVerifyDelays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)]
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

        let request = try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id,
                text: "long message here",
                submit: true
            )
        )
        // Still returns success even if stuck (Option 3 design: try but don't fail)
        #expect(await router.handle(request).success)

        // Exactly 4 Enter keystrokes: initial submit + 3 retries (all attempts fail)
        let enterCalls = recorder.calls.filter { $0.contains("send-keys") && $0.contains("Enter") }
        #expect(enterCalls.count == 4)

        // All 3 retries attempted
        #expect(captureCounter.count == 3)
    }

    @Test("terminal.send with submit=false and text: no retries, no Enter, just paste")
    func terminalSendNoSubmitNoVerify() async throws {
        let recorder = SendRecorder()
        let captureCounter = CaptureCounter()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            dryRunCapturePane: { _, _ in captureCounter.nextResponse() }
        )
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            submitVerifyDelays: [.milliseconds(1)]
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

        let request = try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id,
                text: "long message here",
                submit: false
            )
        )
        #expect(await router.handle(request).success)
        // Paste happens...
        #expect(recorder.calls.contains { $0.contains("paste-buffer") })
        // ...but no Enter keypress
        #expect(!recorder.calls.contains { $0.contains("send-keys") && $0.contains("Enter") })
        // ...and no captures (verification only on submit=true)
        #expect(captureCounter.count == 0)
    }

    @Test("terminal.send with empty text and submit: only Enter, no paste, no verify")
    func terminalSendEmptyTextSubmitNoVerify() async throws {
        let recorder = SendRecorder()
        let captureCounter = CaptureCounter()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            dryRunCapturePane: { _, _ in captureCounter.nextResponse() }
        )
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            submitVerifyDelays: [.milliseconds(1)]
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

        let request = try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id,
                text: "",
                submit: true
            )
        )
        #expect(await router.handle(request).success)
        // Empty text: no paste
        #expect(!recorder.calls.contains { $0.contains("load-buffer") })
        #expect(!recorder.calls.contains { $0.contains("paste-buffer") })
        // But Enter is sent (the manual flush escape hatch)
        #expect(recorder.calls.contains { $0.contains("send-keys") && $0.contains("Enter") })
        // And no verification (empty text case skips verify-and-retry)
        #expect(captureCounter.count == 0)
    }

    @Test("terminal.send verify-and-retry: false-positive guard (earlier ❯ with [Pasted text], last ❯ clear)")
    func terminalSendVerifyComposerScoping() async throws {
        let captureCounter = CaptureCounter()
        // Earlier line contains ❯ [Pasted text (a transcript echo of a previous submit),
        // but the LAST ❯ line (the composer prompt) is clear.
        let paneText = """
        User message:
        ❯ [Pasted text #1 +10 lines]
        ——
        ❯
        ──
          footer
        """
        captureCounter.setUp(responses: [paneText])

        let recorder = SendRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            dryRunCapturePane: { _, _ in captureCounter.nextResponse() }
        )
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            submitVerifyDelays: [.milliseconds(1)]
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

        let request = try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: terminal.id,
                text: "message",
                submit: true
            )
        )
        #expect(await router.handle(request).success)
        // Only one Enter sent (the initial Enter), no retry
        let enterCalls = recorder.calls.filter { $0.contains("send-keys") && $0.contains("Enter") }
        #expect(enterCalls.count == 1)
        // One capture, and it was clear (no false positive on the earlier echo)
        #expect(captureCounter.count == 1)
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
