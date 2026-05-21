import Foundation
import TBDShared

extension RPCRouter {
    // Intentionally does NOT broadcast a state delta: overrides are read from
    // the DB at the next Claude spawn, and the spec treats the app's own
    // setting as the display source of truth, so no live multi-client refresh.
    func handleSetClaudeSpawnPreferences(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ClaudeSpawnPreferences.self, from: data)
        try await db.config.setEnvSettingOverrides(params.settingOverrides ?? [:])
        return .ok()
    }
}
