import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TestSupport

@Suite struct AutoHibernateRPCTests {

    private func makeRouter() throws -> (RPCRouter, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                hooks: HookResolver(),
                leftoverTmuxProbe: .absent
            ),
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

    /// The two verbs that wake one terminal: `terminal.wake`, and the legacy
    /// `terminal.resume` shim older CLI and app builds still call. Both route
    /// through the same coordinator, so each answer below must come from both.
    enum WakeVerb: Sendable, Equatable {
        case wake
        case resume

        func request(_ terminalID: UUID, prompt: String? = nil) throws -> RPCRequest {
            switch self {
            case .wake:
                return try RPCRequest(
                    method: RPCMethod.terminalWake,
                    params: TerminalWakeParams(terminalID: terminalID, prompt: prompt))
            case .resume:
                return try RPCRequest(
                    method: RPCMethod.terminalResume,
                    params: TerminalResumeParams(terminalID: terminalID))
            }
        }
    }

    /// A pid above the kernel's `PID_MAX`: no process can have it, so the
    /// process table says the job a holder row records is gone.
    private static let goneChildPID = Int32.max

    private func makeTerminal(
        _ db: TBDDatabase, tag: String, transport: TerminalTransport,
        childPID: Int32? = nil, parked: Bool = false
    ) async throws -> Terminal {
        let repo = try await db.repos.create(
            path: "/tmp/\(tag)-\(UUID().uuidString)", displayName: tag, defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/\(tag)-w-\(UUID().uuidString)", tmuxServer: "s")
        let holder = transport == .holder
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: holder ? "" : "@0", tmuxPaneID: holder ? "" : "%0",
            label: "claude", claudeSessionID: "sess-1", kind: .claude,
            transport: transport, childPID: childPID)
        if parked {
            try await db.terminals.setHibernated(id: terminal.id, sessionID: "sess-1")
        }
        return try #require(try await db.terminals.get(id: terminal.id))
    }

    /// The reported failure, at the level it was hit: a wake of a row that
    /// claims awake but whose job is gone must NOT come back as a successful
    /// no-op. It carries a machine-readable code so an autonomous caller can
    /// branch without matching message text.
    @Test(arguments: [WakeVerb.wake, .resume])
    func aWakeOfAnUnparkedHolderRowWhoseJobIsGoneIsAnError(_ verb: WakeVerb) async throws {
        let (router, db) = try makeRouter()
        let terminal = try await makeTerminal(
            db, tag: "repoW", transport: .holder, childPID: Self.goneChildPID)

        let resp = await router.handle(try verb.request(terminal.id, prompt: "do the thing"))

        #expect(!resp.success, "a wake that reached no live session must not report success")
        #expect(resp.errorCode == RPCErrorCode.terminalSessionGone.rawValue)
        // The caller's prompt went nowhere, and the message has to say so.
        #expect(resp.error?.contains("NOT delivered") == true,
                "expected the dropped prompt to be reported; got: \(resp.error ?? "nil")")
        // The recovery that works is named, so the session's context is not lost.
        #expect(resp.error?.contains("tbd terminal conversation") == true)
    }

    /// The other branch: a job the process table does not show gone keeps the
    /// benign idempotent no-op — success, and for `terminal.wake`
    /// `woken: false`. The test's own process stands in for the job: it is
    /// alive and not provably the row's, and only a job positively gone
    /// changes the answer.
    @Test(arguments: [WakeVerb.wake, .resume])
    func aWakeOfAnUnparkedHolderRowWhoseJobRunsStaysASuccessfulNoOp(
        _ verb: WakeVerb
    ) async throws {
        let (router, db) = try makeRouter()
        let terminal = try await makeTerminal(
            db, tag: "repoW2", transport: .holder, childPID: getpid())

        let resp = await router.handle(try verb.request(terminal.id))

        #expect(resp.success, "a live job's wake did not stay a no-op: \(resp.error ?? "nil")")
        if verb == .wake {
            let payload = try #require(resp.result?.data(using: .utf8))
            let decoded = try JSONDecoder().decode(TerminalWakeResult.self, from: payload)
            #expect(decoded.woken == false)
        }
    }

    /// A row still on tmux is refused by both verbs with
    /// `RPCErrorCode.terminalOnTmux`, as every other request such a row
    /// refuses is, so a caller can branch without matching the text. A live
    /// row's refusal says its session may still be running in tmux and how to
    /// end it; a parked row's names `tbd terminal migrate`. Nothing is woken
    /// and the row is left as it was.
    @Test(arguments: [WakeVerb.wake, .resume], [false, true])
    func aWakeOfATmuxRowIsRefusedWithTheTmuxCode(_ verb: WakeVerb, parked: Bool) async throws {
        let (router, db) = try makeRouter()
        let terminal = try await makeTerminal(db, tag: "repoT", transport: .tmux, parked: parked)

        let resp = await router.handle(try verb.request(terminal.id, prompt: "do the thing"))

        #expect(!resp.success, "a tmux row's wake reported success")
        #expect(resp.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        let expected = parked
            ? HibernationCoordinator.tmuxWakeUnavailableReason(terminalID: terminal.id)
            : LeftoverTmuxSession.stillRunningRefusal(terminalID: terminal.id, server: "s")
        #expect(resp.error == expected)
        #expect(try await db.terminals.get(id: terminal.id) == terminal,
                "a refused wake changed the row")
    }

    // MARK: - A park of a row still on tmux

    /// `terminal.hibernate`, and the legacy `terminal.suspend` shim.
    enum ParkVerb: Sendable {
        case hibernate
        case suspend

        func request(_ terminalID: UUID) throws -> RPCRequest {
            switch self {
            case .hibernate:
                return try RPCRequest(
                    method: RPCMethod.terminalHibernate,
                    params: TerminalHibernateParams(terminalID: terminalID))
            case .suspend:
                return try RPCRequest(
                    method: RPCMethod.terminalSuspend,
                    params: TerminalSuspendParams(terminalID: terminalID))
            }
        }
    }

    /// A park of a row live on tmux is refused like its wake: TBD can neither
    /// reach nor stop that session, so the answer is the still-running advice
    /// with `RPCErrorCode.terminalOnTmux`, and the row is left as it was.
    @Test(arguments: [ParkVerb.hibernate, .suspend])
    func aParkOfALiveTmuxRowIsRefusedWithTheTmuxCode(_ verb: ParkVerb) async throws {
        let (router, db) = try makeRouter()
        let terminal = try await makeTerminal(db, tag: "repoP", transport: .tmux)

        let resp = await router.handle(try verb.request(terminal.id))

        #expect(!resp.success, "a live tmux row's park reported success")
        #expect(resp.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(resp.error
            == LeftoverTmuxSession.stillRunningRefusal(terminalID: terminal.id, server: "s"))
        #expect(try await db.terminals.get(id: terminal.id) == terminal,
                "a refused park changed the row")
    }

}
