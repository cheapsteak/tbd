import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

@Suite struct AutoHibernateRPCTests {

    private func makeRouter() throws -> (RPCRouter, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
        return (router, db)
    }

    @Test func setWorktreeAutoHibernatePersists() async throws {
        let (router, db) = try makeRouter()
        let repo = try await db.repos.create(
            path: "/tmp/repoH-\(UUID().uuidString)",
            displayName: "repoH",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "w",
            branch: "b",
            path: "/tmp/repoH-w-\(UUID().uuidString)",
            tmuxServer: "s"
        )

        let req = try RPCRequest(
            method: RPCMethod.worktreeSetAutoHibernate,
            params: WorktreeSetAutoHibernateParams(worktreeID: wt.id, enabled: true)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let after = try await db.worktrees.get(id: wt.id)
        #expect(after?.autoHibernateOnMerge == true)
    }

    @Test func configGetAndSetDefault() async throws {
        let (router, db) = try makeRouter()
        let setReq = try RPCRequest(
            method: RPCMethod.configSetAutoHibernateOnMergeDefault,
            params: ConfigSetAutoHibernateDefaultParams(enabled: true)
        )
        #expect(await router.handle(setReq).success)

        let getReq = RPCRequest(method: RPCMethod.configGet)
        let getResp = await router.handle(getReq)
        let cfg = try getResp.decodeResult(Config.self)
        #expect(cfg.autoHibernateOnMergeDefault == true)
        _ = db
    }

    // MARK: - terminal.wake honesty on a row that claims awake

    /// Router whose tmux reports the pane as gone — the exact live-fleet state
    /// where the DB says awake and no pane exists.
    private func makeRouter(paneTarget: @escaping @Sendable (String, String) throws -> PaneSendTarget)
        throws -> (RPCRouter, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true, dryRunPaneSendTarget: paneTarget)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
        return (router, db)
    }

    private func makeUnparkedTerminal(_ db: TBDDatabase, tag: String) async throws -> Terminal {
        let repo = try await db.repos.create(
            path: "/tmp/\(tag)-\(UUID().uuidString)", displayName: tag, defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/\(tag)-w-\(UUID().uuidString)", tmuxServer: "s")
        return try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: "sess-1", kind: .claude)
    }

    /// The reported failure, at the level it was actually hit: `terminal.wake`
    /// on a row that claims awake but has no pane must NOT come back as a
    /// successful no-op. It carries a machine-readable code so an autonomous
    /// caller can branch without matching message text.
    @Test func wakeOnUnparkedRowWithNoPaneIsAnErrorNotASilentNoOp() async throws {
        let (router, db) = try makeRouter(paneTarget: { _, _ in .absent })
        let terminal = try await makeUnparkedTerminal(db, tag: "repoW")

        let req = try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id, prompt: "do the thing"))
        let resp = await router.handle(req)

        #expect(!resp.success, "a wake that reached no live session must not report success")
        #expect(resp.errorCode == RPCErrorCode.terminalSessionGone.rawValue)
        // The caller's prompt went nowhere, and the message has to say so.
        #expect(resp.error?.contains("NOT delivered") == true,
                "expected the dropped prompt to be reported; got: \(resp.error ?? "nil")")
        // The recovery that works is named, so the session's context is not lost.
        #expect(resp.error?.contains("tbd terminal conversation") == true)
    }

    /// Pane-id reuse (#384) at the RPC level: a live pane answering with a
    /// different terminal's id is a refusal, not evidence of health.
    @Test func wakeOnUnparkedRowWhosePaneAnswersAsAnotherTerminalIsAnError() async throws {
        let stranger = UUID().uuidString
        let (router, db) = try makeRouter(paneTarget: { _, _ in .live(terminalID: stranger) })
        let terminal = try await makeUnparkedTerminal(db, tag: "repoW3")

        let req = try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id))
        let resp = await router.handle(req)

        #expect(!resp.success)
        #expect(resp.errorCode == RPCErrorCode.terminalSessionGone.rawValue)
        #expect(resp.error?.contains(stranger) == true,
                "the message should name the terminal that actually answered")
    }

    /// The other branch: a live pane keeps the benign idempotent no-op —
    /// success with `woken: false`, exactly as before.
    @Test func wakeOnUnparkedRowWithLivePaneStaysASuccessfulNoOp() async throws {
        let (router, db) = try makeRouter(paneTarget: { _, _ in .live(terminalID: nil) })
        let terminal = try await makeUnparkedTerminal(db, tag: "repoW2")

        let req = try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id))
        let resp = await router.handle(req)

        #expect(resp.success)
        let payload = try #require(resp.result?.data(using: .utf8))
        let decoded = try JSONDecoder().decode(TerminalWakeResult.self, from: payload)
        #expect(decoded.woken == false)
    }

    /// The legacy `terminal.resume` shim (still reachable from older CLI and
    /// app builds) must give the same honest answer as `terminal.wake` — it
    /// routes through the same coordinator, so a silent no-op here would be the
    /// original bug surviving at the other entry point.
    @Test func legacyResumeOnUnparkedRowWithNoPaneIsAnErrorNotASilentNoOp() async throws {
        let (router, db) = try makeRouter(paneTarget: { _, _ in .absent })
        let terminal = try await makeUnparkedTerminal(db, tag: "repoW5")

        let req = try RPCRequest(
            method: RPCMethod.terminalResume,
            params: TerminalResumeParams(terminalID: terminal.id))
        let resp = await router.handle(req)

        #expect(!resp.success, "terminal.resume must not report success into a dead session")
        #expect(resp.errorCode == RPCErrorCode.terminalSessionGone.rawValue)
        #expect(resp.error?.contains("tbd terminal conversation") == true)
    }

    /// The benign arm of the same shim: a live pane keeps `terminal.resume`'s
    /// historical success.
    @Test func legacyResumeOnUnparkedRowWithLivePaneStaysSuccessful() async throws {
        let (router, db) = try makeRouter(paneTarget: { _, _ in .live(terminalID: nil) })
        let terminal = try await makeUnparkedTerminal(db, tag: "repoW6")

        let req = try RPCRequest(
            method: RPCMethod.terminalResume,
            params: TerminalResumeParams(terminalID: terminal.id))
        #expect(await router.handle(req).success)
    }

    /// Fail-closed at the RPC level too: a probe that threw keeps the benign
    /// successful no-op rather than reporting a dead terminal.
    @Test func wakeOnUnparkedRowWithUnreadablePaneStaysASuccessfulNoOp() async throws {
        let (router, db) = try makeRouter(paneTarget: { _, _ in
            throw TmuxError.timedOut(command: "tmux list-panes", timeout: .seconds(15))
        })
        let terminal = try await makeUnparkedTerminal(db, tag: "repoW4")

        let req = try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id))
        let resp = await router.handle(req)

        #expect(resp.success, "an unreadable probe must not be reported as a dead terminal")
    }

}
