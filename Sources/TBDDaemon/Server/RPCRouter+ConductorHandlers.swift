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
        var conductors = try await db.conductors.list()
        for i in conductors.indices {
            conductors[i].suggestion = conductorManager.suggestion(for: conductors[i].name)
        }
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
        var enriched = conductor
        enriched.suggestion = conductorManager.suggestion(for: conductor.name)
        return try RPCResponse(result: ConductorStatusResult(conductor: enriched, isRunning: isRunning))
    }

    func handleConductorSuggest(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConductorSuggestParams.self, from: paramsData)
        // Look up worktree name for the suggestion
        let worktreeName: String
        if let wt = try await db.worktrees.get(id: params.worktreeID) {
            worktreeName = wt.displayName
        } else {
            return RPCResponse(error: "Worktree not found: \(params.worktreeID)")
        }
        try await conductorManager.suggest(
            name: params.name,
            worktreeID: params.worktreeID,
            worktreeName: worktreeName,
            label: params.label
        )
        return .ok()
    }

    func handleConductorClearSuggestion(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConductorNameParams.self, from: paramsData)
        try await conductorManager.clearSuggestion(name: params.name)
        return .ok()
    }
}
