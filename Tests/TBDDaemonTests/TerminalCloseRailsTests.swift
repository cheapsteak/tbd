import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1 — in-memory DB, dry-run tmux, no real processes.
///
/// `terminal.delete`'s optional activity rails and its idempotent not-found
/// path. Both branches of the rail conditional are covered per the repo rule,
/// plus the liveness qualification that keeps the rail from becoming a trap.
/// The rows are holder rows, whose liveness the rails read from the holder
/// registry; a row left on tmux by an earlier build is not asked at all,
/// because closing it ends no process.
@Suite("terminal.delete activity rails")
struct TerminalCloseRailsTests {

    private struct Fixture {
        let db: TBDDatabase
        let worktree: Worktree
        let terminal: Terminal
    }

    private func makeFixture(
        activityState: TerminalActivityState = .idle,
        claudeSessionID: String? = "sess-abc",
        transport: TerminalTransport = .holder
    ) async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/tcr-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "b",
            path: "/tmp/tcr-wt-\(UUID().uuidString)", tmuxServer: "tbd-tcr")
        // `childPID: 0` is the one value the registry's disposal refuses to
        // signal; any other value a fixture could name is a pid this shared
        // box may really be running.
        let holder = transport == .holder
        var terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: holder ? "" : "@1", tmuxPaneID: holder ? "" : "%1",
            label: "Build", claudeSessionID: claudeSessionID, kind: .claude,
            transport: transport,
            holderPID: holder ? 9101 : nil, childPID: holder ? 0 : nil)
        try await db.terminals.setActivityState(id: terminal.id, activityState: activityState, source: .derived)
        terminal = try #require(try await db.terminals.get(id: terminal.id))
        return Fixture(db: db, worktree: wt, terminal: terminal)
    }

    /// What the holder registry can say about the fixture's holder.
    private enum HolderState {
        /// A registry that has recorded nothing for the row, which the rails
        /// read as running: a live session.
        case unrecorded
        /// No registry at all, which the rails read as an observed stop: a
        /// daemon with no registry has no holder session to protect.
        case noRegistry
        /// A registry that adopted the row and found nothing at its
        /// rendezvous: the holder is gone, and nothing observed the job exit.
        case holderGone(Terminal)
    }

    private func makeRouter(
        db: TBDDatabase, holder: HolderState = .unrecorded,
        tmux: TmuxManager = TmuxManager(dryRun: true)
    ) async -> RPCRouter {
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(), actuationLog: makeTestActuationLog())
        switch holder {
        case .unrecorded:
            router.holderRegistry = Self.registry(listing: [])
        case .noRegistry:
            router.holderRegistry = nil
        case .holderGone(let terminal):
            let registry = Self.registry(listing: [terminal])
            _ = await registry.adoptAll()
            router.holderRegistry = registry
        }
        return router
    }

    /// A holder registry whose rendezvous paths come from an explicit, short
    /// environment, so nothing reaches the real `~/tbd`.
    private static func registry(listing terminals: [Terminal]) -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-tcr-\(UUID().uuidString.prefix(8))"],
            listTerminals: { terminals })
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
        let router = await makeRouter(db: fx.db)

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
        let router = await makeRouter(db: fx.db)

        let resp = try await close(router, fx.terminal.id, rails: false)

        #expect(resp.success)
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil)
    }

    // MARK: - Rail ON

    @Test("rails on: a mid-turn terminal with a live holder is refused", arguments: [
        TerminalActivityState.working, .waitingForUser
    ])
    func railsOnRefusesBusyTerminal(state: TerminalActivityState) async throws {
        let fx = try await makeFixture(activityState: state)
        let router = await makeRouter(db: fx.db)

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
        let router = await makeRouter(db: fx.db)

        let resp = try await close(router, fx.terminal.id, rails: true)

        #expect(resp.success)
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil)
    }

    /// The qualification that keeps the rail from being a trap. `activityState`
    /// is hook-fed and has no timestamp, so a session that died mid-turn stays
    /// `.working` forever. Were the rail unqualified, the wedged terminal a
    /// caller most needs to close would be the one it could never close.
    @Test("rails on: a mid-turn terminal whose session is observed stopped still closes")
    func railsOnClosesBusyTerminalWhoseSessionStopped() async throws {
        let fx = try await makeFixture(activityState: .working)
        let router = await makeRouter(db: fx.db, holder: .noRegistry)

        let resp = try await close(router, fx.terminal.id, rails: true)

        #expect(resp.success, "a stopped session cannot be mid-turn")
        #expect(resp.errorCode == nil)
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil)
    }

    /// The other half of the qualification.
    ///
    /// Only an *observed* stop may lift the rail. A holder that is gone does
    /// not establish that the job it forked is, so a rail that cannot
    /// establish the session ended has to fail closed.
    @Test("rails on: a mid-turn terminal whose holder is gone but whose job was never seen to exit is refused")
    func railsOnRefusesWhenLivenessIsUnknown() async throws {
        let fx = try await makeFixture(activityState: .working)
        let router = await makeRouter(db: fx.db, holder: .holderGone(fx.terminal))

        let resp = try await close(router, fx.terminal.id, rails: true)

        #expect(!resp.success, "an unknown liveness lifted a rail it cannot satisfy")
        #expect(resp.errorCode == RPCErrorCode.terminalBusy.rawValue)
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) != nil,
                "an unknown liveness let the close delete a possibly-live session")
    }

    /// The other branch of the transport conditional. A row an earlier build
    /// left on tmux is closed without running a tmux command, so closing it
    /// ends no in-flight turn and the activity rail has nothing to protect.
    @Test("rails on: a mid-turn tmux row closes without running tmux", arguments: [
        TerminalActivityState.working, .waitingForUser
    ])
    func railsOnClosesBusyTmuxRow(state: TerminalActivityState) async throws {
        let fx = try await makeFixture(activityState: state, transport: .tmux)
        let recorded = RecordedTmuxArgs()
        let router = await makeRouter(
            db: fx.db, tmux: TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) }))

        let resp = try await close(router, fx.terminal.id, rails: true)

        #expect(resp.success, "error: \(resp.error ?? "nil")")
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil)
        #expect(recorded.snapshot().isEmpty,
                "the close asked tmux about a tmux row: \(recorded.snapshot())")
    }

    // MARK: - Composer-draft rail

    private func reportDrafts(_ router: RPCRouter, _ ids: [UUID]) async throws {
        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.appSetComposerDrafts,
            params: AppSetComposerDraftsParams(terminalIDs: ids)))
        #expect(resp.success)
    }

    private func list(_ router: RPCRouter, _ worktreeID: UUID) async throws -> [Terminal] {
        let resp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: worktreeID)))
        return try resp.decodeResult([Terminal].self)
    }

    @Test("rails on: a terminal with an unsent app-composer draft is refused")
    func railsOnRefusesTerminalWithComposerDraft() async throws {
        let fx = try await makeFixture()
        let router = await makeRouter(db: fx.db)
        try await reportDrafts(router, [fx.terminal.id])

        let resp = try await close(router, fx.terminal.id, rails: true)

        #expect(!resp.success)
        #expect(resp.errorCode == RPCErrorCode.terminalHasComposerDraft.rawValue,
                "CLI maps the code to exit 2 without parsing prose")
        #expect(resp.error?.contains("--force") == true, "the message must name the escape hatch")
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) != nil)
    }

    /// The draft lives in the app, not the session, so a stopped session does
    /// not make it any less the person's text.
    @Test("rails on: a draft still refuses when the session has stopped")
    func railsOnRefusesDraftEvenWhenTheSessionStopped() async throws {
        let fx = try await makeFixture()
        let router = await makeRouter(db: fx.db, holder: .noRegistry)
        try await reportDrafts(router, [fx.terminal.id])

        let resp = try await close(router, fx.terminal.id, rails: true)

        #expect(resp.errorCode == RPCErrorCode.terminalHasComposerDraft.rawValue)
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) != nil)
    }

    @Test("rails omitted (--force, and the app's own tab close): a draft does not block")
    func railsOffClosesTerminalWithComposerDraft() async throws {
        let fx = try await makeFixture()
        let router = await makeRouter(db: fx.db)
        try await reportDrafts(router, [fx.terminal.id])

        let resp = try await close(router, fx.terminal.id, rails: nil)

        #expect(resp.success)
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) == nil)
    }

    @Test("rails on: a draft another terminal holds does not block this one")
    func railsOnClosesWhenOnlyAnotherTerminalHasADraft() async throws {
        let fx = try await makeFixture()
        let router = await makeRouter(db: fx.db)
        try await reportDrafts(router, [UUID()])

        let resp = try await close(router, fx.terminal.id, rails: true)

        #expect(resp.success)
    }

    @Test("each report replaces the last: a cleared draft no longer blocks")
    func aLaterReportReplacesTheSet() async throws {
        let fx = try await makeFixture()
        let router = await makeRouter(db: fx.db)
        try await reportDrafts(router, [fx.terminal.id])
        try await reportDrafts(router, [])

        let resp = try await close(router, fx.terminal.id, rails: true)

        #expect(resp.success)
    }

    @Test("terminal.list shows which terminals hold a draft")
    func listShowsComposerDraft() async throws {
        let fx = try await makeFixture()
        let router = await makeRouter(db: fx.db)

        #expect(try await list(router, fx.worktree.id).first?.hasComposerDraft == false)
        try await reportDrafts(router, [fx.terminal.id])
        #expect(try await list(router, fx.worktree.id).first?.hasComposerDraft == true)
    }

    /// A subscription can drop while the app and its drafts live on, so the
    /// last one closing is no proof the drafts are gone. The set stays, and a
    /// rails close keeps refusing until the app reports again.
    @Test("the last subscription closing keeps every draft")
    func lastSubscriptionClosingKeepsDrafts() async throws {
        let fx = try await makeFixture()
        let router = await makeRouter(db: fx.db)
        let subscription = router.registerSubscription(writer: { _ in true })
        try await reportDrafts(router, [fx.terminal.id])

        router.removeSubscription(id: subscription)

        #expect(router.composerDrafts.hasDraft(terminalID: fx.terminal.id))
        let resp = try await close(router, fx.terminal.id, rails: true)
        #expect(resp.errorCode == RPCErrorCode.terminalHasComposerDraft.rawValue,
                "a dropped subscription must not lift the refusal")
        #expect(try await fx.db.terminals.get(id: fx.terminal.id) != nil)
    }

    /// The app reports the whole set when the daemon acknowledges a new
    /// subscription, so that report replaces whatever the daemon kept, and an
    /// empty one is what clears a stale entry.
    @Test("a whole-set report after resubscribing replaces the kept set")
    func reportAfterResubscribeReplacesKeptSet() async throws {
        let fx = try await makeFixture()
        let router = await makeRouter(db: fx.db)
        let other = UUID()
        let dropped = router.registerSubscription(writer: { _ in true })
        try await reportDrafts(router, [fx.terminal.id])
        router.removeSubscription(id: dropped)

        _ = router.registerSubscription(writer: { _ in true })
        try await reportDrafts(router, [other])
        #expect(!router.composerDrafts.hasDraft(terminalID: fx.terminal.id),
                "the fresh report replaces the kept set rather than adding to it")
        #expect(router.composerDrafts.hasDraft(terminalID: other))

        try await reportDrafts(router, [])
        #expect(!router.composerDrafts.hasDraft(terminalID: other))
        let resp = try await close(router, fx.terminal.id, rails: true)
        #expect(resp.success)
    }

    // MARK: - Idempotency and result payload

    @Test("closing an already-closed terminal is a no-op success")
    func alreadyGoneIsSuccess() async throws {
        let fx = try await makeFixture()
        let router = await makeRouter(db: fx.db)

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
        let router = await makeRouter(db: fx.db)

        let resp = try await close(router, UUID(), rails: true)

        #expect(resp.success)
        #expect(try resp.decodeResult(TerminalDeleteResult.self).alreadyGone)
    }

    @Test("the result echoes the Claude session id so a caller keeps a resume pointer")
    func resultCarriesSessionID() async throws {
        let fx = try await makeFixture(claudeSessionID: "sess-xyz")
        let router = await makeRouter(db: fx.db)

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
            worktreeID: wt.id, tmuxWindowID: "", tmuxPaneID: "",
            label: "shell", claudeSessionID: nil, kind: .shell,
            transport: .holder, holderPID: 9101, childPID: 0)
        let router = await makeRouter(db: db)

        let resp = try await close(router, shell.id, rails: true)

        let result = try resp.decodeResult(TerminalDeleteResult.self)
        #expect(result.closed)
        #expect(result.claudeSessionID == nil)
    }
}
