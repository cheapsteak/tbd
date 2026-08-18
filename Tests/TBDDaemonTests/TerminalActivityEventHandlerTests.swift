import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

@Suite("terminal.activityEvent handler")
struct TerminalActivityEventHandlerTests {
    let db: TBDDatabase
    let router: RPCRouter

    init() throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        self.router = RPCRouter(
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
    }

    private func makeTerminal() async throws -> Terminal {
        let repo = try await db.repos.create(
            path: "/tmp/ta-repo-\(UUID().uuidString)",
            displayName: "ta-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/ta-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-ta"
        )
        return try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex
        )
    }

    @Test("updates activity state in DB")
    func updatesActivityState() async throws {
        let terminal = try await makeTerminal()
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: terminal.id,
                activityState: .working
            )
        )

        let response = await router.handle(request)
        #expect(response.success)

        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.activityState == .working)
    }

    @Test("unknown terminalID is a soft no-op")
    func unknownTerminalSoftSuccess() async throws {
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: UUID(),
                activityState: .idle
            )
        )

        let response = await router.handle(request)
        #expect(response.success)
        #expect(response.error == nil)
    }

    @Test("user interrupt persists distinct provenance from working state")
    func userInterruptPersistsProvenanceFromWorking() async throws {
        let terminal = try await makeTerminal()
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .working,
            source: .hookEvent(RPCMethod.terminalActivityEvent)
        )
        let request = RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: #"{"terminalID":"\#(terminal.id.uuidString)","activityState":"idle","origin":"user_interrupt"}"#
        )

        let response = await router.handle(request)

        #expect(response.success)
        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .idle)
        #expect(updated.activityStateSource?.kind == "user-action")
        #expect(updated.activityStateSource?.detail == "terminal-interrupt")
    }

    @Test("user interrupt replaces provenance when raw state is already idle")
    func userInterruptPersistsProvenanceFromIdle() async throws {
        let terminal = try await makeTerminal()
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .idle,
            source: .hookEvent(RPCMethod.terminalActivityEvent)
        )
        let request = RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: #"{"terminalID":"\#(terminal.id.uuidString)","activityState":"idle","origin":"user_interrupt"}"#
        )

        let response = await router.handle(request)

        #expect(response.success)
        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .idle)
        #expect(updated.activityStateSource?.kind == "user-action")
        #expect(updated.activityStateSource?.detail == "terminal-interrupt")
    }

    @Test("same-state hook does not erase an explicit interrupt")
    func sameStateHookPreservesInterrupt() async throws {
        let terminal = try await makeTerminal()
        let interruptSource = try JSONDecoder().decode(
            FactSource.self,
            from: Data(#"{"kind":"user-action","detail":"terminal-interrupt"}"#.utf8)
        )
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .idle,
            source: interruptSource
        )
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: terminal.id,
                activityState: .idle
            )
        )

        let response = await router.handle(request)

        #expect(response.success)
        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityStateSource?.kind == "user-action")
        #expect(updated.activityStateSource?.detail == "terminal-interrupt")
    }

    @Test("later working hook supersedes an explicit interrupt")
    func laterWorkingHookSupersedesInterrupt() async throws {
        let terminal = try await makeTerminal()
        let interrupt = RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: #"{"terminalID":"\#(terminal.id.uuidString)","activityState":"idle","origin":"user_interrupt"}"#
        )
        #expect((await router.handle(interrupt)).success)

        let working = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: terminal.id,
                activityState: .working
            )
        )
        #expect((await router.handle(working)).success)

        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .working)
        #expect(updated.activityStateSource == .hookEvent(RPCMethod.terminalActivityEvent))
    }

    @Test("user interrupt is not counted as an agent hook event")
    func userInterruptDoesNotIncrementHookCounter() async throws {
        let terminal = try await makeTerminal()
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-activity-\(UUID().uuidString).jsonl")
        try Data().write(to: transcript)
        defer { try? FileManager.default.removeItem(at: transcript) }
        let request = RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: #"{"terminalID":"\#(terminal.id.uuidString)","activityState":"idle","origin":"user_interrupt"}"#
        )

        #expect((await router.handle(request)).success)

        let counters = try #require(await router.sessionCounters.sample(
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            transcriptPath: transcript.path,
            commitsUnchangedSince: nil
        ))
        #expect(counters.hookEventsInWindow == 0)
    }
}
