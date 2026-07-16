import Foundation
import TBDShared

extension RPCRouter {
    // These handlers intentionally do NOT broadcast a state delta: the merged
    // overrides are read from the DB at the next Claude/Codex spawn, and the
    // app treats its own published state as the display source of truth (mirrors
    // handleSetClaudeSpawnPreferences).
    func handleConfigSetEnvOverrides(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(SetGlobalEnvOverridesParams.self, from: data)
        try await db.config.setEnvOverrides(params.overrides)
        return .ok()
    }

    func handleRepoSetEnvOverrides(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(SetRepoEnvOverridesParams.self, from: data)
        try await db.repos.setEnvOverrides(id: params.repoID, overrides: params.overrides)
        return .ok()
    }

    func handleModelProfileSetEnvOverrides(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(SetProfileEnvOverridesParams.self, from: data)
        try await db.modelProfiles.setEnvOverrides(id: params.profileID, overrides: params.overrides)
        return .ok()
    }
}
