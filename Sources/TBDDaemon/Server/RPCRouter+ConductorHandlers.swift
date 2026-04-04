import Foundation
import TBDShared

extension RPCRouter {
    func handleConductorSetup(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConductorSetupParams.self, from: paramsData)
        let conductor = try await conductorManager.setup(
            name: params.name,
            repos: params.repos ?? ["*"],
            worktrees: params.worktrees,
            terminalLabels: params.terminalLabels,
            heartbeatIntervalMinutes: params.heartbeatIntervalMinutes ?? 10
        )
        return try RPCResponse(result: conductor)
    }

    func handleConductorStart(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConductorNameParams.self, from: paramsData)
        let terminal = try await conductorManager.start(name: params.name)
        return try RPCResponse(result: terminal)
    }

    func handleConductorStop(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConductorNameParams.self, from: paramsData)
        try await conductorManager.stop(name: params.name)
        return .ok()
    }

    func handleConductorTeardown(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConductorNameParams.self, from: paramsData)
        try await conductorManager.teardown(name: params.name)
        return .ok()
    }

    func handleConductorList() async throws -> RPCResponse {
        let conductors = try await db.conductors.list()
        return try RPCResponse(result: ConductorListResult(conductors: conductors))
    }

    func handleConductorStatus(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConductorNameParams.self, from: paramsData)
        guard let conductor = try await db.conductors.get(name: params.name) else {
            return RPCResponse(error: "Conductor not found: \(params.name)")
        }
        var isRunning = false
        if let terminalID = conductor.terminalID,
           let terminal = try await db.terminals.get(id: terminalID) {
            isRunning = await tmux.windowExists(
                server: TBDConstants.conductorsTmuxServer,
                windowID: terminal.tmuxWindowID
            )
        }
        return try RPCResponse(result: ConductorStatusResult(conductor: conductor, isRunning: isRunning))
    }
}
