import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1 — in-memory DB, dry-run tmux, no real processes.
///
/// `terminal.delete`'s optional activity rails and its idempotent not-found
/// path. Both branches of the rail conditional are covered per the repo rule,
/// plus the liveness qualification that keeps the rail from becoming a trap.
@Suite("terminal.delete activity rails")
struct TerminalCloseRailsTests {

    private struct Fixture {
        let db: TBDDatabase
        let worktree: Worktree
        let terminal: Terminal
    }

    private func makeFixture(
        activityState: TerminalActivityState = .idle,
        claudeSessionID: String? = "sess-abc"
    ) async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/tcr-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "b",
            path: "/tmp/tcr-wt-\(UUID().uuidString)", tmuxServer: "tbd-tcr")
        var terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Build", claudeSessionID: claudeSessionID, kind: .claude)
        try await db.terminals.setActivityState(id: terminal.id, activityState: activityState)
        terminal = try #require(try await db.terminals.get(id: terminal.id))
        return Fixture(db: db, worktree: wt, terminal: terminal)
    }

    /// `windowIsDead: true` forces the row's window to read as gone, which is
    /// what a crashed-mid-turn session looks like.
    private func makeRouter(db: TBDDatabase, windowIsDead: Bool = false) -> RPCRouter {
        var deadHook: (@Sendable (String) -> Bool)?
        if windowIsDead { deadHook = { _ in true } }
        let tmux = TmuxManager(dryRun: true, dryRunWindowIsDead: deadHook)
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date())
    }

    private func close(
        _ router: RPCRouter, _ id: UUID, rails: Bool?
    ) async throws -> RPCResponse {
        await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: id, respectActivityRails: rails)))
    }

    // MARK: - Rail OFF (the app's tab-close path, unchanged)

    @Test("rails omitted: a mid-turn terminal still closes", arguments: [
        TerminalActivityState.working, .waitingForUser
    ])
    func railsOffClosesBusyTerminal(state: TerminalActivityState) async throws {
        let fx = try await makeFixture(activityState: state)
        let router = makeRouter(db: fx.db)

        let resp = try await close(router, fx.terminal.id, rails: nil)

        #expect(resp.success, "app tab-close must keep its unconditional semantics")
        let result = try resp.decodeResult(TerminalDeleteResult.self)
        #expect(result.closed)
        #expect(!result.alreadyGone)
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil)
    }

    @Test("rails explicitly false behaves the same as omitted")
    func railsFalseClosesBusyTerminal() async throws {
        let fx = try await makeFixture(activityState: .working)
        let router = makeRouter(db: fx.db)

        let resp = try await close(router, fx.terminal.id, rails: false)

        #expect(resp.success)
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil)
    }

    // MARK: - Rail ON

    @Test("rails on: a mid-turn terminal with a live window is refused", arguments: [
        TerminalActivityState.working, .waitingForUser
    ])
    func railsOnRefusesBusyTerminal(state: TerminalActivityState) async throws {
        let fx = try await makeFixture(activityState: state)
        let router = makeRouter(db: fx.db)

        let resp = try await close(router, fx.terminal.id, rails: true)

        #expect(!resp.success)
        #expect(resp.errorCode == RPCErrorCode.terminalBusy.rawValue,
                "CLI maps the code to exit 2 without parsing prose")
        #expect(resp.error?.contains("--force") == true, "the message must name the escape hatch")
        // The refusal is total: nothing was torn down.
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) != nil)
    }

    @Test("rails on: an idle terminal closes", arguments: [
        TerminalActivityState.idle, .unknown
    ])
    func railsOnClosesIdleTerminal(state: TerminalActivityState) async throws {
        let fx = try await makeFixture(activityState: state)
        let router = makeRouter(db: fx.db)

        let resp = try await close(router, fx.terminal.id, rails: true)

        #expect(resp.success)
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil)
    }

    /// The qualification that keeps the rail from being a trap. `activityState`
    /// is hook-fed and has no timestamp, so a session that died mid-turn stays
    /// `.working` forever. Were the rail unqualified, the wedged terminal a
    /// caller most needs to close would be the one it could never close.
    @Test("rails on: a mid-turn terminal whose window is DEAD still closes")
    func railsOnClosesBusyTerminalWithDeadWindow() async throws {
        let fx = try await makeFixture(activityState: .working)
        let router = makeRouter(db: fx.db, windowIsDead: true)

        let resp = try await close(router, fx.terminal.id, rails: true)

        #expect(resp.success, "a dead-window row cannot be mid-turn")
        #expect(resp.errorCode == nil)
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil)
    }

    // MARK: - Idempotency and result payload

    @Test("closing an already-closed terminal is a no-op success")
    func alreadyGoneIsSuccess() async throws {
        let fx = try await makeFixture()
        let router = makeRouter(db: fx.db)

        let first = try await close(router, fx.terminal.id, rails: true)
        #expect(try first.decodeResult(TerminalDeleteResult.self).closed)

        let second = try await close(router, fx.terminal.id, rails: true)
        #expect(second.success, "matches terminal.wake's documented idempotency")
        let result = try second.decodeResult(TerminalDeleteResult.self)
        #expect(!result.closed)
        #expect(result.alreadyGone)
    }

    @Test("closing an unknown terminal is a no-op success, not an error")
    func unknownTerminalIsSuccess() async throws {
        let fx = try await makeFixture()
        let router = makeRouter(db: fx.db)

        let resp = try await close(router, UUID(), rails: true)

        #expect(resp.success)
        #expect(try resp.decodeResult(TerminalDeleteResult.self).alreadyGone)
    }

    @Test("the result echoes the Claude session id so a caller keeps a resume pointer")
    func resultCarriesSessionID() async throws {
        let fx = try await makeFixture(claudeSessionID: "sess-xyz")
        let router = makeRouter(db: fx.db)

        let resp = try await close(router, fx.terminal.id, rails: true)

        #expect(try resp.decodeResult(TerminalDeleteResult.self).claudeSessionID == "sess-xyz")
    }

    @Test("a non-Claude terminal reports no session id")
    func shellTerminalHasNoSessionID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/tcr-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "b",
            path: "/tmp/tcr-wt-\(UUID().uuidString)", tmuxServer: "tbd-tcr")
        let shell = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "shell", claudeSessionID: nil, kind: .shell)
        let router = makeRouter(db: db)

        let resp = try await close(router, shell.id, rails: true)

        let result = try resp.decodeResult(TerminalDeleteResult.self)
        #expect(result.closed)
        #expect(result.claudeSessionID == nil)
    }
}
