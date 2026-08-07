import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

@Suite("terminal.continueInCodex RPC")
struct ContinueInCodexRPCTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var commandStorage: [[String]] = []
        private var eventStorage: [String] = []

        func command(_ arguments: [String]) {
            lock.lock()
            commandStorage.append(arguments)
            lock.unlock()
        }

        func event(_ value: String) {
            lock.lock()
            eventStorage.append(value)
            lock.unlock()
        }

        var commands: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return commandStorage
        }

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return eventStorage
        }
    }

    private struct Fixture {
        let root: URL
        let db: TBDDatabase
        let router: RPCRouter
        let recorder: Recorder
        let worktree: Worktree
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tbd-native-continue-\(UUID().uuidString)",
                isDirectory: true)
        let worktreePath = root.appendingPathComponent(
            "worktree", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktreePath, withIntermediateDirectories: true)

        let db = try TBDDatabase(inMemory: true)
        let recorder = Recorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.command($0) })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: tmux,
                hooks: HookResolver()),
            tmux: tmux, actuationLog: makeTestActuationLog())
        router.codexExecutableResolver = {
            recorder.event("resolve")
            return "/opt/test/bin/codex"
        }
        router.codexHomeEnsurer = {
            recorder.event("profile")
            return root.appendingPathComponent("codex-home", isDirectory: true)
        }
        router.codexProfileFlagResolver = { _ in
            recorder.event("profile-flag")
            return "--profile"
        }
        router.codexSessionImport = { executable, home, transcript, cwd, title in
            recorder.event("import:\(executable):\(home.path):\(transcript):\(cwd):\(title ?? "nil")")
            return "thread-native-123"
        }

        let repo = try await db.repos.create(
            path: worktreePath.path,
            displayName: "sample-repo",
            defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: "sample-worktree",
            branch: "feature/native-import",
            path: worktreePath.path,
            tmuxServer: "tbd-native-continue-test")
        return Fixture(
            root: root,
            db: db,
            router: router,
            recorder: recorder,
            worktree: worktree)
    }

    private func createClaudeSource(in fixture: Fixture) async throws
        -> Terminal {
        let transcript = fixture.root.appendingPathComponent("source.jsonl")
        try #"{"type":"user","message":{"content":"continue this"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        let source = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "@source",
            tmuxPaneID: "%source",
            label: TerminalLabel.claudeCode,
            claudeSessionID: "claude-session",
            kind: .claude)
        try await fixture.db.terminals.updateSession(
            id: source.id,
            sessionID: "claude-session",
            transcriptPath: transcript.path)
        return try #require(try await fixture.db.terminals.get(id: source.id))
    }

    @Test("imports first, preserves the source, and opens one resumed Codex terminal")
    func createsResumedCodexTerminal() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try await createClaudeSource(in: fixture)
        let request = try RPCRequest(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(terminalID: source.id))

        let response = await fixture.router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(
            TerminalContinueInCodexResult.self)
        #expect(result.threadID == "thread-native-123")
        let target = try #require(
            try await fixture.db.terminals.get(id: result.terminalID))
        #expect(target.isCodexTerminal)
        #expect(target.worktreeID == source.worktreeID)
        #expect(try await fixture.db.terminals.get(id: source.id) == source)
        #expect(Array(fixture.recorder.events.prefix(3)) == [
            "resolve", "profile", "profile-flag",
        ])
        #expect(fixture.recorder.events.count == 4)
        #expect(fixture.recorder.events[3].hasPrefix("import:"))

        let newWindows = fixture.recorder.commands.filter {
            $0.contains("new-window")
        }
        #expect(newWindows.count == 1)
        let launch = try #require(newWindows.first?.last)
        #expect(launch.contains("resume 'thread-native-123'"))
        #expect(!launch.contains("continue this"))
        #expect(!fixture.recorder.commands.contains { $0.contains("send-keys") })
        #expect(!fixture.recorder.commands.contains { $0.contains("paste-buffer") })
    }

    @Test("non-Claude source fails before every launch and import seam")
    func rejectsNonClaudeBeforeMutation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shell = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "@shell",
            tmuxPaneID: "%shell",
            label: TerminalLabel.shell,
            kind: .shell)
        let before = try await fixture.db.terminals.list(
            worktreeID: fixture.worktree.id)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(terminalID: shell.id)))

        #expect(!response.success)
        #expect(response.error?.contains("requires a Claude terminal") == true)
        #expect(fixture.recorder.events.isEmpty)
        #expect(fixture.recorder.commands.isEmpty)
        #expect(try await fixture.db.terminals.list(
            worktreeID: fixture.worktree.id) == before)
    }

    @Test("missing transcript fails before resolver, profile, import, and tmux")
    func rejectsMissingTranscriptBeforeMutation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id,
            tmuxWindowID: "@source",
            tmuxPaneID: "%source",
            label: TerminalLabel.claudeCode,
            claudeSessionID: "claude-session",
            kind: .claude)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(terminalID: source.id)))

        #expect(!response.success)
        #expect(response.error?.contains("no transcript path") == true)
        #expect(fixture.recorder.events.isEmpty)
        #expect(fixture.recorder.commands.isEmpty)
    }

    @Test("executable failure precedes profile writes, import, and tmux")
    func resolverFailurePrecedesMutation() async throws {
        enum Expected: Error { case failure }
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try await createClaudeSource(in: fixture)
        fixture.router.codexExecutableResolver = {
            fixture.recorder.event("resolve")
            throw Expected.failure
        }

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(terminalID: source.id)))

        #expect(!response.success)
        #expect(fixture.recorder.events == ["resolve"])
        #expect(fixture.recorder.commands.isEmpty)
        #expect(try await fixture.db.terminals.list(
            worktreeID: fixture.worktree.id) == [source])
    }

    @Test("inactive worktree fails before every launch and import seam")
    func rejectsInactiveWorktreeBeforeMutation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try await createClaudeSource(in: fixture)
        try await fixture.db.worktrees.updateStatus(
            id: fixture.worktree.id, status: .failed)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(terminalID: source.id)))

        #expect(!response.success)
        #expect(response.error?.contains("not active") == true)
        #expect(fixture.recorder.events.isEmpty)
        #expect(fixture.recorder.commands.isEmpty)
    }

    @Test("import failure creates no tmux window or terminal row")
    func importFailureIsAtomicForTBDState() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try await createClaudeSource(in: fixture)
        fixture.router.codexSessionImport = { _, _, _, _, _ in
            fixture.recorder.event("import-failed")
            throw CodexSessionImportError.appServer("conversion failed")
        }

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(terminalID: source.id)))

        #expect(!response.success)
        #expect(response.error?.contains("conversion failed") == true)
        #expect(fixture.recorder.commands.isEmpty)
        #expect(try await fixture.db.terminals.list(
            worktreeID: fixture.worktree.id) == [source])
    }
}
