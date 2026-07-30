import Foundation
import TBDShared

extension RPCRouter {
    func handleSetNightwatchMode(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NightwatchSetModeParams.self, from: data)
        try await db.config.setNightwatchMode(params.mode)
        // Apply the mode to the runner (start/stop the loop).
        if let runner = daywatchRunner {
            await runner.apply(mode: params.mode)
        }
        // Reuse the existing config-change channel so the app reloads Config.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return .ok()
    }
}
