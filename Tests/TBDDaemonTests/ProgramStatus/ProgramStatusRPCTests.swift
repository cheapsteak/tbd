import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// `terminal.programStatusReport` and `terminal.programStatusList`, end to end
// through the router, plus the flag setter reaching the store's gate.
extension RPCRouterTests {

    private func makeProgramStatusTerminal(
        kind: TerminalKind = .claude, transport: TerminalTransport = .holder
    ) async throws -> Terminal {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )
        return try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: kind, transport: transport, holderPID: 9101, childPID: 9102)
    }

    private func sendProgramStatusReport(
        terminalID: UUID, incarnationID: UUID?, payload: String,
        observedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) async throws -> RPCResponse {
        let params = TerminalProgramStatusReportParams(
            terminalID: terminalID, incarnationID: incarnationID,
            payload: payload, observedAt: observedAt)
        let request = try RPCRequest(method: RPCMethod.terminalProgramStatusReport, params: params)
        return await router.handle(request)
    }

    private func listProgramStatus() async throws -> [ProgramStatusSnapshot] {
        let response = await router.handle(RPCRequest(method: RPCMethod.terminalProgramStatusList))
        #expect(response.success)
        return try response.decodeResult(TerminalProgramStatusListResult.self).snapshots
    }

    @Test("programStatusReport is accepted and listed when the flag is on")
    func programStatusReportAcceptedAndListed() async throws {
        let terminal = try await makeProgramStatusTerminal()
        await router.programStatus.setEnabled(true)

        let response = try await sendProgramStatusReport(
            terminalID: terminal.id, incarnationID: nil,
            payload: "state=blocked:kind=permission:app=claude-code")
        #expect(response.success)

        let snapshots = try await listProgramStatus()
        #expect(snapshots.count == 1)
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.terminalID == terminal.id)
        #expect(snapshot.main?.state == .blocked)
        #expect(snapshot.main?.kind == .permission)
    }

    @Test("programStatusReport is rejected and the list is empty with the flag off")
    func programStatusReportRejectedWhenFlagOff() async throws {
        let terminal = try await makeProgramStatusTerminal()
        // The router's own store starts on the shipped default, which is off.
        #expect(!router.programStatus.gate.isEnabled)

        let response = try await sendProgramStatusReport(
            terminalID: terminal.id, incarnationID: nil,
            payload: "state=working:app=claude-code")
        // Always ok: the app must not retry a rejection.
        #expect(response.success)
        #expect(await router.programStatus.snapshot(for: terminal.id) == nil)
        #expect(try await listProgramStatus().isEmpty)
    }

    @Test("programStatusReport for another incarnation is rejected")
    func programStatusReportWrongIncarnationRejected() async throws {
        let terminal = try await makeProgramStatusTerminal()
        await router.programStatus.setEnabled(true)

        let response = try await sendProgramStatusReport(
            terminalID: terminal.id, incarnationID: UUID(),
            payload: "state=working:app=claude-code")
        #expect(response.success)
        #expect(try await listProgramStatus().isEmpty)
    }

    @Test("programStatusReport for a tmux terminal is rejected")
    func programStatusReportTmuxRejected() async throws {
        let terminal = try await makeProgramStatusTerminal(transport: .tmux)
        await router.programStatus.setEnabled(true)

        _ = try await sendProgramStatusReport(
            terminalID: terminal.id, incarnationID: nil,
            payload: "state=working:app=claude-code")
        #expect(try await listProgramStatus().isEmpty)
    }

    @Test("config.setProgramStatusEnabled drives the store's gate and retracts on off")
    func programStatusFlagSetterDrivesStore() async throws {
        let terminal = try await makeProgramStatusTerminal()

        let on = try RPCRequest(
            method: RPCMethod.configSetProgramStatusEnabled,
            params: ConfigSetProgramStatusEnabledParams(enabled: true))
        #expect(await router.handle(on).success)
        #expect(router.programStatus.gate.isEnabled)

        _ = try await sendProgramStatusReport(
            terminalID: terminal.id, incarnationID: nil,
            payload: "state=working:app=claude-code")
        #expect(try await listProgramStatus().count == 1)

        let off = try RPCRequest(
            method: RPCMethod.configSetProgramStatusEnabled,
            params: ConfigSetProgramStatusEnabledParams(enabled: false))
        #expect(await router.handle(off).success)
        #expect(!router.programStatus.gate.isEnabled)
        #expect(await router.programStatus.snapshot(for: terminal.id) == nil)
        #expect(try await listProgramStatus().isEmpty)
    }

    @Test("session.states resolves an OSC-authoritative terminal from the store")
    func sessionStatesUsesProgramStatus() async throws {
        let terminal = try await makeProgramStatusTerminal()
        await router.programStatus.setEnabled(true)
        _ = try await sendProgramStatusReport(
            terminalID: terminal.id, incarnationID: nil,
            payload: "state=done:app=claude-code")

        let request = try RPCRequest(
            method: RPCMethod.sessionStates,
            params: SessionStatesParams(worktreeID: terminal.worktreeID))
        let response = await router.handle(request)
        #expect(response.success)
        let result = try response.decodeResult(SessionStatesResult.self)
        let report = try #require(result.reports.first { $0.terminalID == terminal.id })
        #expect(report.state.value == .done)
        #expect(report.state.source == .programStatus)
    }
}
