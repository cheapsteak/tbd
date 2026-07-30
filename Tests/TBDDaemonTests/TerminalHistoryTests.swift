import Foundation
import GRDB
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Closed-terminal history: scrollback captured at close time, file-backed
/// content + `terminal_history` metadata rows, pruned to the newest 50 per
/// worktree, removed on worktree hard-delete.
@Suite struct TerminalHistoryTests {

    private static func makeTempDir() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tbd-term-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct Fixture {
        let db: TBDDatabase
        let historyDir: String
        let worktree: Worktree
        let terminal: Terminal

        func cleanup() {
            try? FileManager.default.removeItem(atPath: historyDir)
        }
    }

    private func makeFixture(
        label: String? = "Build",
        kind: TerminalKind? = .claude,
        claudeSessionID: String? = "sess-abc"
    ) async throws -> Fixture {
        let historyDir = try Self.makeTempDir()
        let db = try TBDDatabase(inMemory: true, terminalHistoryDir: historyDir)
        let repo = try await db.repos.create(
            path: "/tmp/th-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "b",
            path: "/tmp/th-wt-\(UUID().uuidString)", tmuxServer: "tbd-th")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: label, claudeSessionID: claudeSessionID, kind: kind)
        return Fixture(db: db, historyDir: historyDir, worktree: wt, terminal: terminal)
    }

    private func makeRouter(db: TBDDatabase, tmux: TmuxManager) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date())
    }

    // MARK: - Capture on terminal.delete

    @Test func deleteHandlerCapturesScrollbackToFileAndRow() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        let captured = "line one\nline two\nline three"
        let tmux = TmuxManager(dryRun: true, dryRunCapturePane: { _, _ in captured })
        let router = makeRouter(db: fx.db, tmux: tmux)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: fx.terminal.id)))
        #expect(resp.success)

        // Close semantics unchanged: terminal row is gone.
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil)

        // Metadata row present with correct fields.
        let entries = try await fx.db.terminalHistory.list(worktreeID: fx.worktree.id)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.id == fx.terminal.id)
        #expect(entry.worktreeID == fx.worktree.id)
        #expect(entry.label == "Build")
        #expect(entry.kind == .claude)
        #expect(entry.claudeSessionID == "sess-abc")
        #expect(entry.lineCount == 3)

        // Content file written verbatim.
        let path = fx.db.terminalHistory.contentPath(
            worktreeID: fx.worktree.id, terminalID: fx.terminal.id)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == captured)

        // RPC list returns it too.
        let listResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalHistoryList,
            params: TerminalHistoryListParams(worktreeID: fx.worktree.id)))
        #expect(listResp.success)
        let listed = try listResp.decodeResult([TerminalHistoryEntry].self)
        #expect(listed.map(\.id) == [fx.terminal.id])
    }

    @Test func emptyCaptureStoresNoFileAndNoRow() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        let tmux = TmuxManager(dryRun: true, dryRunCapturePane: { _, _ in "  \n\t\n" })
        let router = makeRouter(db: fx.db, tmux: tmux)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: fx.terminal.id)))
        #expect(resp.success)
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil)

        #expect(try await fx.db.terminalHistory.list(worktreeID: fx.worktree.id).isEmpty)
        let path = fx.db.terminalHistory.contentPath(
            worktreeID: fx.worktree.id, terminalID: fx.terminal.id)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func captureFailureIsSwallowedAndStoresNothing() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        struct CaptureError: Error {}

        // Never throws out of captureOnClose; no row, no file.
        await fx.db.terminalHistory.captureOnClose(terminal: fx.terminal) {
            throw CaptureError()
        }
        #expect(try await fx.db.terminalHistory.list(worktreeID: fx.worktree.id).isEmpty)
        let path = fx.db.terminalHistory.contentPath(
            worktreeID: fx.worktree.id, terminalID: fx.terminal.id)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Capture on hook-terminal auto-close

    @Test func closeHookTerminalCapturesBeforeTeardown() async throws {
        let fx = try await makeFixture(label: TerminalLabel.preSession, kind: .shell, claudeSessionID: nil)
        defer { fx.cleanup() }
        let tmux = TmuxManager(dryRun: true, dryRunCapturePane: { _, _ in "setup hook output\n" })
        let lifecycle = WorktreeLifecycle(
            db: fx.db, git: GitManager(), tmux: tmux, hooks: HookResolver())

        await lifecycle.closeHookTerminal(
            worktree: fx.worktree,
            terminalID: fx.terminal.id,
            windowID: fx.terminal.tmuxWindowID)

        // Teardown still ran.
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil)

        // Capture landed.
        let entries = try await fx.db.terminalHistory.list(worktreeID: fx.worktree.id)
        #expect(entries.count == 1)
        #expect(entries.first?.id == fx.terminal.id)
        #expect(entries.first?.kind == .shell)
        let path = fx.db.terminalHistory.contentPath(
            worktreeID: fx.worktree.id, terminalID: fx.terminal.id)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "setup hook output\n")
    }

    // MARK: - Capture on archive

    @Test func archiveCapturesLiveTerminalScrollbackAndKeepsArchivedRow() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        let captured = "agent output before archive\nsecond line\n"
        let tmux = TmuxManager(dryRun: true, dryRunCapturePane: { _, _ in captured })
        let lifecycle = WorktreeLifecycle(
            db: fx.db, git: GitManager(), tmux: tmux, hooks: HookResolver())

        _ = try await lifecycle.beginArchiveWorktree(worktreeID: fx.worktree.id)

        // Terminal row torn down, but the worktree row survives as archived.
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil)
        #expect(try await fx.db.worktrees.get(id: fx.worktree.id)?.status == .archived)

        // Scrollback captured into Closed Terminals history (row + file).
        let entries = try await fx.db.terminalHistory.list(worktreeID: fx.worktree.id)
        #expect(entries.count == 1)
        #expect(entries.first?.id == fx.terminal.id)
        let path = fx.db.terminalHistory.contentPath(
            worktreeID: fx.worktree.id, terminalID: fx.terminal.id)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == captured)
    }

    // MARK: - Capture on reconcile auto-archive

    /// A worktree whose git checkout has vanished is auto-archived by reconcile;
    /// its live terminal's scrollback must land in Closed Terminals history.
    @Test func reconcileAutoArchiveCapturesTerminalScrollback() async throws {
        let historyDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: historyDir) }
        let db = try TBDDatabase(inMemory: true, terminalHistoryDir: historyDir)

        // Real git repo with no extra worktrees, so a DB worktree row pointing
        // at a non-git path is auto-archived by reconcile.
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let captured = "reconcile scrollback\n"
        let tmux = TmuxManager(dryRun: true, dryRunCapturePane: { _, _ in captured })
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "gone", branch: "gone-branch",
            path: tempDir.appendingPathComponent("vanished").path, tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%0",
            label: "Claude Code", claudeSessionID: UUID().uuidString, kind: .claude)

        try await lifecycle.reconcile(repoID: repo.id)

        // Worktree archived, terminal torn down, scrollback captured.
        #expect(try await db.worktrees.get(id: wt.id)?.status == .archived)
        #expect(try await db.terminals.get(id: terminal.id) == nil)
        let entries = try await db.terminalHistory.list(worktreeID: wt.id)
        #expect(entries.count == 1)
        #expect(entries.first?.id == terminal.id)
        let path = db.terminalHistory.contentPath(worktreeID: wt.id, terminalID: terminal.id)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == captured)
    }

    // MARK: - Retention

    @Test func pruneKeepsNewestFiftyPerWorktree() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        var ids: [UUID] = []
        for i in 0..<51 {
            let terminal = Terminal(
                worktreeID: fx.worktree.id, tmuxWindowID: "@\(i)", tmuxPaneID: "%\(i)")
            ids.append(terminal.id)
            await fx.db.terminalHistory.store(
                terminal: terminal, text: "output \(i)",
                closedAt: base.addingTimeInterval(TimeInterval(i)))
        }

        let entries = try await fx.db.terminalHistory.list(worktreeID: fx.worktree.id)
        #expect(entries.count == 50)
        // Oldest (index 0) is pruned — row and file.
        #expect(!entries.contains { $0.id == ids[0] })
        let oldestPath = fx.db.terminalHistory.contentPath(
            worktreeID: fx.worktree.id, terminalID: ids[0])
        #expect(!FileManager.default.fileExists(atPath: oldestPath))
        // Newest survives — row and file.
        #expect(entries.first?.id == ids[50])
        let newestPath = fx.db.terminalHistory.contentPath(
            worktreeID: fx.worktree.id, terminalID: ids[50])
        #expect(FileManager.default.fileExists(atPath: newestPath))
    }

    // MARK: - Worktree hard-delete cleanup

    @Test func deleteForWorktreeRemovesRowsAndDirectory() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        await fx.db.terminalHistory.store(
            terminal: fx.terminal, text: "some output", closedAt: Date())
        let dir = fx.db.terminalHistory.worktreeDir(worktreeID: fx.worktree.id)
        #expect(FileManager.default.fileExists(atPath: dir))

        try await fx.db.terminalHistory.deleteForWorktree(worktreeID: fx.worktree.id)

        #expect(try await fx.db.terminalHistory.list(worktreeID: fx.worktree.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test func forgetWorktreeCleansHistoryRowsAndDirectory() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        await fx.db.terminalHistory.store(
            terminal: fx.terminal, text: "some output", closedAt: Date())
        let dir = fx.db.terminalHistory.worktreeDir(worktreeID: fx.worktree.id)
        #expect(FileManager.default.fileExists(atPath: dir))

        let lifecycle = WorktreeLifecycle(
            db: fx.db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver())
        try await lifecycle.forgetWorktree(worktreeID: fx.worktree.id)

        #expect(try await fx.db.worktrees.get(id: fx.worktree.id) == nil)
        #expect(try await fx.db.terminalHistory.list(worktreeID: fx.worktree.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    // MARK: - Revive

    /// Create the worktree's on-disk directory (revive requires a live dir)
    /// and register cleanup.
    private func makeLiveDir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// The `new-window` shell command recorded by a dryRun tmux (the last
    /// element of the recorded args is the full command string).
    private func newWindowCommand(_ recorded: [[String]]) -> String? {
        recorded.first(where: { $0.contains("new-window") })?.last
    }

    @Test func shellReviveOpensFreshShellWithCapture() async throws {
        let fx = try await makeFixture(label: "sh", kind: .shell, claudeSessionID: nil)
        defer { fx.cleanup() }
        try makeLiveDir(fx.worktree.path)
        defer { try? FileManager.default.removeItem(atPath: fx.worktree.path) }

        // A closed shell terminal with captured scrollback (file + row).
        let shellTerm = Terminal(
            worktreeID: fx.worktree.id, tmuxWindowID: "@9", tmuxPaneID: "%9",
            label: nil, kind: .shell)
        await fx.db.terminalHistory.store(
            terminal: shellTerm, text: "prior shell output\n", closedAt: Date())
        let capturePath = fx.db.terminalHistory.contentPath(
            worktreeID: fx.worktree.id, terminalID: shellTerm.id)
        #expect(FileManager.default.fileExists(atPath: capturePath))

        let recorder = PreSessionRecordedCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunCapturePane: { _, _ in "" })
        let router = makeRouter(db: fx.db, tmux: tmux)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalHistoryRevive,
            params: TerminalHistoryReviveParams(worktreeID: fx.worktree.id, id: shellTerm.id)))
        #expect(resp.success)
        let revived = try resp.decodeResult(Terminal.self)

        // New terminal row, kind shell, in this worktree.
        #expect(revived.kind == .shell)
        #expect(revived.worktreeID == fx.worktree.id)
        #expect(try await fx.db.terminals.get(id: revived.id) != nil)

        // Tab order appended + active set to the new terminal.
        #expect(try await fx.db.worktrees.getTabOrder(worktreeID: fx.worktree.id) == [revived.id])
        #expect(try await fx.db.worktrees.getActiveTabID(worktreeID: fx.worktree.id) == revived.id)

        // Spawn command: banner + cat of the capture file + exec shell.
        let command = try #require(newWindowCommand(recorder.snapshot()))
        #expect(command.contains("restored from close on"))
        #expect(command.contains("/bin/cat"))
        #expect(command.contains(capturePath))
        #expect(command.contains("exec "))

        // History row survives revive.
        let entries = try await fx.db.terminalHistory.list(worktreeID: fx.worktree.id)
        #expect(entries.contains { $0.id == shellTerm.id })
    }

    @Test func claudeReviveResumesSession() async throws {
        let fx = try await makeFixture(label: TerminalLabel.claudeCode, kind: .claude, claudeSessionID: "sess-xyz")
        defer { fx.cleanup() }
        try makeLiveDir(fx.worktree.path)
        defer { try? FileManager.default.removeItem(atPath: fx.worktree.path) }

        await fx.db.terminalHistory.store(
            terminal: fx.terminal, text: "claude scrollback\n", closedAt: Date())

        let recorder = PreSessionRecordedCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunCapturePane: { _, _ in "" })
        let router = makeRouter(db: fx.db, tmux: tmux)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalHistoryRevive,
            params: TerminalHistoryReviveParams(worktreeID: fx.worktree.id, id: fx.terminal.id)))
        #expect(resp.success)
        let revived = try resp.decodeResult(Terminal.self)

        #expect(revived.kind == .claude)
        #expect(revived.claudeSessionID == "sess-xyz")

        // Spawn command resumes the session (no scrollback cat).
        let command = try #require(newWindowCommand(recorder.snapshot()))
        #expect(command.contains("claude --resume sess-xyz"))
        #expect(!command.contains("/bin/cat"))
    }

    @Test func reviveWithMissingCaptureFileSkipsCat() async throws {
        let fx = try await makeFixture(label: "sh", kind: .shell, claudeSessionID: nil)
        defer { fx.cleanup() }
        try makeLiveDir(fx.worktree.path)
        defer { try? FileManager.default.removeItem(atPath: fx.worktree.path) }

        // History row present, but the capture file is deleted underneath it.
        let shellTerm = Terminal(
            worktreeID: fx.worktree.id, tmuxWindowID: "@9", tmuxPaneID: "%9",
            label: nil, kind: .shell)
        await fx.db.terminalHistory.store(
            terminal: shellTerm, text: "gone soon\n", closedAt: Date())
        let capturePath = fx.db.terminalHistory.contentPath(
            worktreeID: fx.worktree.id, terminalID: shellTerm.id)
        try FileManager.default.removeItem(atPath: capturePath)

        let recorder = PreSessionRecordedCommands()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.append($0) },
            dryRunCapturePane: { _, _ in "" })
        let router = makeRouter(db: fx.db, tmux: tmux)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalHistoryRevive,
            params: TerminalHistoryReviveParams(worktreeID: fx.worktree.id, id: shellTerm.id)))
        #expect(resp.success)

        // Banner + shell, but no cat (file missing).
        let command = try #require(newWindowCommand(recorder.snapshot()))
        #expect(command.contains("restored from close on"))
        #expect(!command.contains("/bin/cat"))
        #expect(command.contains("exec "))
    }

    @Test func reviveUnknownWorktreeErrorsWithoutTerminal() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        let tmux = TmuxManager(dryRun: true)
        let router = makeRouter(db: fx.db, tmux: tmux)

        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalHistoryRevive,
            params: TerminalHistoryReviveParams(worktreeID: UUID(), id: fx.terminal.id)))
        #expect(!resp.success)
    }

    @Test func reviveUnknownEntryErrorsWithoutTerminal() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        try makeLiveDir(fx.worktree.path)
        defer { try? FileManager.default.removeItem(atPath: fx.worktree.path) }
        let tmux = TmuxManager(dryRun: true)
        let router = makeRouter(db: fx.db, tmux: tmux)

        let before = try await fx.db.terminals.list(worktreeID: fx.worktree.id).count
        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalHistoryRevive,
            params: TerminalHistoryReviveParams(worktreeID: fx.worktree.id, id: UUID())))
        #expect(!resp.success)
        // No terminal created.
        #expect(try await fx.db.terminals.list(worktreeID: fx.worktree.id).count == before)
    }

    @Test func reviveShellCommandQuotesSingleQuotePath() {
        // Path with a single quote must be POSIX-escaped ('\'') for the cat.
        let path = "/tmp/wei'rd/cap.txt"
        let cmd = RPCRouter.reviveShellCommand(
            capturePath: path,
            closedAt: Date(timeIntervalSince1970: 0),
            shell: "/bin/zsh")
        #expect(cmd.contains("/bin/cat '/tmp/wei'\\''rd/cap.txt'"))
        #expect(cmd.contains("restored from close on"))
        #expect(cmd.hasSuffix("exec /bin/zsh"))
    }

    @Test func reviveShellCommandOmitsCatWhenNoCapture() {
        let cmd = RPCRouter.reviveShellCommand(
            capturePath: nil,
            closedAt: Date(timeIntervalSince1970: 0),
            shell: "/bin/zsh")
        #expect(!cmd.contains("cat"))
        #expect(cmd.contains("printf"))
        #expect(cmd.hasSuffix("exec /bin/zsh"))
    }

    // MARK: - Migration

    @Test func migrationCreatesTerminalHistoryTable() async throws {
        let db = try TBDDatabase(inMemory: true)
        let columns: [String] = try await db.writerForTests.read { sqlDB in
            guard try sqlDB.tableExists("terminal_history") else { return [] }
            return try Row.fetchAll(sqlDB, sql: "PRAGMA table_info(terminal_history)")
                .compactMap { $0["name"] as String? }
        }
        #expect(Set(columns) == Set([
            "id", "worktreeID", "label", "kind", "closedAt", "claudeSessionID", "lineCount"
        ]))
    }
}
