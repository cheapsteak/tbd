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
}
