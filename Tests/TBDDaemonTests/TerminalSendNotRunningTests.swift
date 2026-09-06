import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// The refusal the composer and the CLI both need: a text send to a terminal
/// whose Claude process is gone must not be pasted into the shell that is
/// sitting in the pane and executed as a command line.
///
/// Two independent facts answer "is Claude running here", and each gets its own
/// case because each fails on its own: the hook stamp (missed on a crash) and
/// the pane's foreground process group (unavailable on a holder row).
///
/// Tier 2: an in-memory database, a dry-run tmux manager and a stub inspector.
@Suite("terminal.send refuses a not-running terminal")
struct TerminalSendNotRunningTests {

    /// A `PaneProcessInspecting` whose answer the test chooses.
    private struct StubInspector: PaneProcessInspecting {
        let foreground: Int32?
        func foregroundClaudePID(panePID: Int32) -> Int32? { foreground }
    }

    private struct Fixture {
        let router: RPCRouter
        let db: TBDDatabase
        let terminal: Terminal
    }

    /// A throwaway actuation log per fixture. `ActuationLog` takes a PATH, not a
    /// database — the record is an append-only JSONL file.
    private static func scratchLogPath() -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-plan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("actuations.jsonl").path
    }

    /// `TmuxManager(dryRun:)` reports every pane pid as "0", so the fixture
    /// supplies one through the `dryRunPanePID` hook this task adds — the shape
    /// every other dry-run answer in that file already uses.
    private func makeFixture(
        foreground: Int32?, kind: TerminalKind = .claude
    ) async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "sess-1", kind: kind)
        let tmux = TmuxManager(
            dryRun: true,
            dryRunPaneSendTarget: { _, _ in .live(terminalID: nil) },
            dryRunPanePID: { _, _ in "4242" })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            paneProcessInspector: StubInspector(foreground: foreground),
            actuationLog: ActuationLog(path: Self.scratchLogPath()))
        return Fixture(router: router, db: db, terminal: terminal)
    }

    private func send(_ f: Fixture) async throws -> RPCResponse {
        let data = try JSONEncoder().encode(TerminalSendParams(
            terminalID: f.terminal.id, text: "hello", submit: true))
        return try await f.router.handleTerminalSend(data, actor: .app)
    }

    @Test func aHibernatedRowIsRefused() async throws {
        let f = try await makeFixture(foreground: 4242)
        try await f.db.terminals.setHibernated(
            id: f.terminal.id, sessionID: "sess-1", reason: .manual,
            at: Date(timeIntervalSince1970: 1_800_000_000))

        let response = try await send(f)
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("is not running"))
    }

    @Test func anExitStampedRowIsRefused() async throws {
        let f = try await makeFixture(foreground: 4242)
        _ = try await f.db.terminals.stampSessionExited(
            id: f.terminal.id, reportedIncarnationID: nil,
            at: Date(timeIntervalSince1970: 1_800_000_000))

        let response = try await send(f)
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("its Claude session exited"))
    }

    /// The rail that covers a MISSED hook: nothing is stamped, the pane is alive,
    /// and the process table says Claude is not the foreground process.
    @Test func aLiveRowWithNoForegroundClaudeIsRefused() async throws {
        let f = try await makeFixture(foreground: nil)

        let response = try await send(f)
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("foreground process"))
    }

    /// The positive control. Without it the three refusals above could all be
    /// passing because every send is refused.
    @Test func aLiveRowWithClaudeForegroundIsNotRefused() async throws {
        let f = try await makeFixture(foreground: 4242)

        let response = try await send(f)
        #expect(response.success, "error was: \(response.error ?? "none")")
    }

    /// A shell terminal has no Claude to be foreground, so the foreground rail
    /// must never run for one. Without the kind gate this send is refused in
    /// production: the pane pid is `-zsh`, it has no `claude` descendant, and the
    /// inspector answers nil for every shell session there is.
    @Test func aShellTerminalIsNotSubjectToTheForegroundRail() async throws {
        let f = try await makeFixture(foreground: nil, kind: .shell)

        let response = try await send(f)
        #expect(response.success, "error was: \(response.error ?? "none")")
    }

    /// Codex is agent-bearing and supported, and its command line contains no
    /// "claude", so the inspector answers nil for a perfectly healthy Codex
    /// session. The gate is on the terminal's KIND, not on what `ps` says.
    @Test func aCodexTerminalIsNotSubjectToTheForegroundRail() async throws {
        let f = try await makeFixture(foreground: nil, kind: .codex)

        let response = try await send(f)
        #expect(response.success, "error was: \(response.error ?? "none")")
    }

    /// The refusal is a text-send rail, not a terminal-wide one. `--keys` exists
    /// to answer a dialog and to interrupt; refusing it on a parked row would
    /// take away the one payload that has nothing to do with typing a message.
    @Test func aKeysPayloadIsNotRefusedByTheseRails() async throws {
        let f = try await makeFixture(foreground: nil)
        let data = try JSONEncoder().encode(TerminalSendParams(
            terminalID: f.terminal.id, keys: "Escape"))

        let response = try await f.router.handleTerminalSend(data, actor: .app)
        #expect(response.success, "error was: \(response.error ?? "none")")
    }
}
