import Foundation
import GRDB
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
