import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared
import TestSupport

/// The refusal the composer and the CLI both need: a text send to a terminal
/// whose agent process is gone must not be pasted into the shell that is
/// sitting in the pane and executed as a command line.
///
/// Two independent facts answer "is the agent running here", and each gets its
/// own case because each fails on its own: the hook stamp (missed on a crash,
/// and never written at all for Codex, which has no `SessionEnd` hook) and the
/// pane's foreground process group (unavailable on a holder row). The
/// foreground fact is kind-aware — it looks for the name the kind implies — so
/// both agent-bearing kinds get discriminating cases and a shell gets none.
///
/// Tier 2: an in-memory database, a dry-run tmux manager and a stub inspector.
@Suite("terminal.send refuses a not-running terminal")
struct TerminalSendNotRunningTests {

    /// A `PaneProcessInspecting` whose answer the test chooses, PER agent name
    /// the rail asks about — so a fixture can say "codex is foreground here,
    /// claude is not", which is exactly the discrimination the kind-aware rail
    /// makes. A name absent from the dictionary answers nil, as the production
    /// inspector does when no matching process owns the pane.
    private struct StubInspector: PaneProcessInspecting {
        let foregroundByAgent: [String: Int32]
        func foregroundAgentPID(panePID: Int32, matching agentName: String) -> Int32? {
            foregroundByAgent[agentName]
        }
    }

    private struct Fixture {
        let router: RPCRouter
        let db: TBDDatabase
        let terminal: Terminal
    }

    /// A throwaway actuation log per fixture. `ActuationLog` takes a PATH, not a
    /// database — the record is an append-only JSONL file. It lands under the
    /// run's fenced scratch dir, which `scripts/test.sh` removes even when the
    /// test process is killed; a per-test `temporaryDirectory` would leak.
    private static func scratchLogPath() -> String {
        let directory = URL(
            fileURLWithPath: fencedScratchRoot(prefix: "tbd-sendnotrunning"), isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("actuations.jsonl").path
    }

    /// `TmuxManager(dryRun:)` reports every pane pid as "0", so the fixture
    /// supplies one through the `dryRunPanePID` hook this task adds — the shape
    /// every other dry-run answer in that file already uses.
    private func makeFixture(
        foregroundByAgent: [String: Int32], kind: TerminalKind? = .claude
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
            paneProcessInspector: StubInspector(foregroundByAgent: foregroundByAgent),
            actuationLog: ActuationLog(path: Self.scratchLogPath()))
        return Fixture(router: router, db: db, terminal: terminal)
    }

    private func send(_ f: Fixture) async throws -> RPCResponse {
        let data = try JSONEncoder().encode(TerminalSendParams(
            terminalID: f.terminal.id, text: "hello", submit: true))
        return try await f.router.handleTerminalSend(data, actor: .app)
    }

    @Test func aHibernatedRowIsRefused() async throws {
        let f = try await makeFixture(foregroundByAgent: ["claude": 4242])
        try await f.db.terminals.setHibernated(
            id: f.terminal.id, sessionID: "sess-1", reason: .manual,
            at: Date(timeIntervalSince1970: 1_800_000_000))

        let response = try await send(f)
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("is not running"))
    }

    @Test func anExitStampedRowIsRefused() async throws {
        let f = try await makeFixture(foregroundByAgent: ["claude": 4242])
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
        let f = try await makeFixture(foregroundByAgent: [:])

        let response = try await send(f)
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("foreground process"))
    }

    /// The positive control. Without it the three refusals above could all be
    /// passing because every send is refused.
    @Test func aLiveRowWithClaudeForegroundIsNotRefused() async throws {
        let f = try await makeFixture(foregroundByAgent: ["claude": 4242])

        let response = try await send(f)
        #expect(response.success, "error was: \(response.error ?? "none")")
    }

    /// A shell terminal has no Claude to be foreground, so the foreground rail
    /// must never run for one. Without the kind gate this send is refused in
    /// production: the pane pid is `-zsh`, it has no `claude` descendant, and the
    /// inspector answers nil for every shell session there is.
    @Test func aShellTerminalIsNotSubjectToTheForegroundRail() async throws {
        let f = try await makeFixture(foregroundByAgent: [:], kind: .shell)

        let response = try await send(f)
        #expect(response.success, "error was: \(response.error ?? "none")")
    }

    /// A Codex pane whose agent has left is the case NEITHER other rail catches:
    /// Codex ships no `SessionEnd` hook, so the row is never exit-stamped, and a
    /// stamp would be wrong anyway (the wake path refuses a non-Claude row, so
    /// the stamp would park it unwakeably). The foreground rail is the only
    /// thing between this send and a message run as a shell command.
    @Test func aCodexTerminalWithNoForegroundCodexIsRefused() async throws {
        let f = try await makeFixture(foregroundByAgent: [:], kind: .codex)

        let response = try await send(f)
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("foreground process"))
        #expect(error.contains("(codex)"), "the refusal must name the agent it looked for")
    }

    /// The positive control for the Codex leg: the rail asks about "codex", not
    /// about "claude", so a healthy Codex session — whose command line contains
    /// no "claude" at all — proceeds.
    @Test func aCodexTerminalWithCodexForegroundIsNotRefused() async throws {
        let f = try await makeFixture(foregroundByAgent: ["codex": 4242], kind: .codex)

        let response = try await send(f)
        #expect(response.success, "error was: \(response.error ?? "none")")
    }

    /// The kind picks the name, and nothing else does. Mapping it wrong in
    /// either direction is the whole bug this rail had.
    ///
    /// A row with NO recorded kind is a legacy Claude terminal, which is the
    /// reading `Terminal.isClaudeResumable` and the continue-in-Codex path
    /// already give it. Reading it as a shell instead would skip the rail
    /// entirely for the oldest rows on the machine.
    @Test func theForegroundAgentNameFollowsTheKind() {
        #expect(RPCRouter.foregroundAgentName(for: .claude) == "claude")
        #expect(RPCRouter.foregroundAgentName(for: .codex) == "codex")
        #expect(RPCRouter.foregroundAgentName(for: .shell) == nil)
        #expect(RPCRouter.foregroundAgentName(for: nil) == "claude")
    }

    /// The handler-level half of the same fact: a row whose `kind` column is
    /// NULL still gets the foreground rail, and it gets the Claude one.
    @Test func aKindlessTerminalWithNoForegroundClaudeIsRefused() async throws {
        let f = try await makeFixture(foregroundByAgent: [:], kind: nil)

        let response = try await send(f)
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("foreground process"))
        #expect(error.contains("(claude)"), "a kindless row is read as a Claude row")
    }

    /// The two rails split on the empty payload, and the park rail takes it.
    /// A bare Enter into a parked row carries no message, but it has no purpose
    /// either — the pane holds a shell — and the refusal already names wake as
    /// the remedy.
    @Test func anEmptyTextSubmitToAHibernatedRowIsRefused() async throws {
        let f = try await makeFixture(foregroundByAgent: ["claude": 4242])
        try await f.db.terminals.setHibernated(
            id: f.terminal.id, sessionID: "sess-1", reason: .manual,
            at: Date(timeIntervalSince1970: 1_800_000_000))

        let data = try JSONEncoder().encode(TerminalSendParams(
            terminalID: f.terminal.id, text: "", submit: true))
        let response = try await f.router.handleTerminalSend(data, actor: .app)
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("is not running"))
    }

    /// The other side of that split, so the rule is asserted in both
    /// directions: the FOREGROUND rail stays text-with-a-body, because a bare
    /// Enter is how a caller answers a prompt, and an inspector that cannot see
    /// the agent must not take that away from a live row.
    @Test func anEmptyTextSubmitToALiveRowSkipsTheForegroundRail() async throws {
        let f = try await makeFixture(foregroundByAgent: [:])

        let data = try JSONEncoder().encode(TerminalSendParams(
            terminalID: f.terminal.id, text: "", submit: true))
        let response = try await f.router.handleTerminalSend(data, actor: .app)
        #expect(response.success, "error was: \(response.error ?? "none")")
    }

    /// The refusal is a text-send rail, not a terminal-wide one. `--keys` exists
    /// to answer a dialog and to interrupt; refusing it on a parked row would
    /// take away the one payload that has nothing to do with typing a message.
    @Test func aKeysPayloadIsNotRefusedByTheseRails() async throws {
        let f = try await makeFixture(foregroundByAgent: [:])
        let data = try JSONEncoder().encode(TerminalSendParams(
            terminalID: f.terminal.id, keys: "Escape"))

        let response = try await f.router.handleTerminalSend(data, actor: .app)
        #expect(response.success, "error was: \(response.error ?? "none")")
    }
}
