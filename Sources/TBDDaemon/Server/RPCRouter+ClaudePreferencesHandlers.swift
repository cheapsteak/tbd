import Foundation
import TBDShared

extension RPCRouter {
    func handleSetClaudeSpawnPreferences(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ClaudeSpawnPreferences.self, from: data)
        try await db.config.setEnvSettingOverrides(params.settingOverrides ?? [:])
        return .ok()
    }
}
