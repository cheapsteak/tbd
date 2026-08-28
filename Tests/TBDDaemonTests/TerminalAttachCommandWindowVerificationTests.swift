import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1 — dry-run tmux, in-memory database.
///
/// The composed script's payload is `link-window -s @N`: the thing it names is
/// a **window**, not the pane the identity probe verifies. Today the two
/// columns are only ever written together, so the pane check transitively
/// covers the window and no live desync path exists — but "the window must be
/// verified before it is named" is a claim about the code, and a claim nothing
/// exercises is one a future single-column write silently falsifies. Every
/// fixture elsewhere builds a self-consistent `(windowID, paneID)` pair, so
/// these are the only tests that can tell verification from trust.
@Suite("terminal.attachCommand window verification")
struct TerminalAttachCommandWindowVerificationTests {

    private struct Fixture {
        let router: RPCRouter
        let worktree: Worktree
        let terminal: Terminal
    }

    /// - Parameters:
    ///   - rowWindowID: the window the terminal row claims — what the handler
    ///     would emit on trust.
    ///   - probedWindowID: what tmux says the pane actually lives in. `nil`
    ///     models tmux answering with no window at all.
    private func makeFixture(
        rowWindowID: String, probedWindowID: String?, paneID: String = "%7"
    ) async throws -> Fixture {
        let tmux = TmuxManager(
            dryRun: true,
            dryRunPaneSendTarget: { _, _ in .live(terminalID: nil) },
            dryRunPaneWindowID: { _, _ in probedWindowID })
        let db = try TBDDatabase(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-attach-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            tmuxSocketPathResolver: TmuxSocketPathResolver(
                environment: ["TMUX_TMPDIR": "/tmp/tbd-attach-window-fixture"], uid: 4242),
            actuationLog: ActuationLog(
                path: directory.appendingPathComponent("actuations.jsonl").path))
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: rowWindowID, tmuxPaneID: paneID)
        return Fixture(router: router, worktree: worktree, terminal: terminal)
    }

    private func attachCommand(_ fixture: Fixture) async throws -> RPCResponse {
        await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalAttachCommand,
            params: TerminalAttachCommandParams(
                worktreeID: fixture.worktree.id,
                terminalID: fixture.terminal.id)))
    }

    @Test("a pane living in a different window than the row records is refused")
    func driftedWindowIsRefused() async throws {
        let fixture = try await makeFixture(rowWindowID: "@3", probedWindowID: "@91")
        let response = try await attachCommand(fixture)

        #expect(!response.success)
        let error = try #require(response.error)
        // The refusal names both halves, so the state is diagnosable from the
        // message alone rather than only from the daemon log.
        #expect(error.contains("@91"))
        #expect(error.contains("@3"))
        #expect(response.errorCode == RPCErrorCode.terminalSessionGone.rawValue)
    }

    @Test("an agreeing window composes, and the script names the verified window")
    func agreeingWindowComposes() async throws {
        let fixture = try await makeFixture(rowWindowID: "@3", probedWindowID: "@3")
        let response = try await attachCommand(fixture)

        #expect(response.success, "unexpected error: \(response.error ?? "-")")
        let result = try response.decodeResult(TerminalAttachCommandResult.self)
        #expect(result.windowID == "@3")
        #expect(result.script.contains("@3"))
    }

    /// Guards the refusal above against passing on a hardcoded `@91`: the
    /// comparison must follow the row, not a fixture constant.
    @Test("a terminal recorded on a different window still composes when tmux agrees")
    func agreementFollowsTheRow() async throws {
        let fixture = try await makeFixture(rowWindowID: "@91", probedWindowID: "@91")
        let response = try await attachCommand(fixture)

        #expect(response.success, "unexpected error: \(response.error ?? "-")")
        let result = try response.decodeResult(TerminalAttachCommandResult.self)
        #expect(result.windowID == "@91")
    }

    /// Absence is not disagreement — the same rule the identity check follows.
    /// A pane tmux answers about with no window id at all (an older tmux, an
    /// empty field) composes as before rather than being refused on nothing.
    @Test("a pane that names no window composes rather than being refused")
    func unknownWindowComposes() async throws {
        let fixture = try await makeFixture(rowWindowID: "@3", probedWindowID: nil)
        let response = try await attachCommand(fixture)

        #expect(response.success, "unexpected error: \(response.error ?? "-")")
        let result = try response.decodeResult(TerminalAttachCommandResult.self)
        #expect(result.windowID == "@3")
    }

    // MARK: - The probe actually reads the window

    /// The handler can only compare what the query asks for. Without this, the
    /// comparison above could be reading a field the production format string
    /// never requested.
    @Test("the pane probe query asks tmux for the window id")
    func probeQueryReadsWindowID() {
        let query = TmuxManager.paneSendTargetQuery(server: "tbd-acme", paneID: "%7")
        #expect(query.contains { $0.contains("#{window_id}") })
    }

    @Test("the probe parser reads the window id from the line for the named pane")
    func probeParserReadsWindowID() {
        // Two panes in one window is the case `#{pane_id}`-first selection
        // exists for: `list-panes -t %N` lists every pane in %N's window.
        let output = """
            %6\t@3\t0\t\t/bin/zsh
            %7\t@3\t0\t\t/bin/zsh
            """
        let probe = TmuxManager.parsePaneSendProbe(output, paneID: "%7")
        #expect(probe.windowID == "@3")
        #expect(probe.target == .live(terminalID: nil))

        // Nothing answered for this coordinate: no window to report either.
        let missing = TmuxManager.parsePaneSendProbe(output, paneID: "%99")
        #expect(missing.windowID == nil)
        #expect(missing.target == .missing)
    }
}
