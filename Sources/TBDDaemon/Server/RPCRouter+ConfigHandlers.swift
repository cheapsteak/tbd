import Foundation
import TBDShared

extension RPCRouter {
    func handleConfigGet() async throws -> RPCResponse {
        let config = try await db.config.get()
        return try RPCResponse(result: config)
    }

    func handleConfigSetAutoArchiveDefault(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetAutoArchiveDefaultParams.self, from: paramsData)
        try await db.config.setAutoArchiveOnMergeDefault(params.enabled)
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }

    func handleConfigSetScratchInstructions(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetScratchInstructionsParams.self, from: paramsData)
        try await db.config.setScratchInstructions(params.instructions)
        // No broadcast: nothing in the app consumes a delta for this field —
        // the editor sheet fetches Config fresh on open, and the daemon reads
        // config from the DB at spawn time.
        return .ok()
    }
}
