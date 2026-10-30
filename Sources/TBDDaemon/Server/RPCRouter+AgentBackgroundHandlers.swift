import Foundation
import TBDShared

extension RPCRouter {

    /// `agents.background`: turn agent background priority on for a lease, off,
    /// or report it. Not an actuation row (it changes no session's input, pty or
    /// lifecycle); its effect lives in `agent-background.json`. `off` and
    /// `status` work with the flag off; turning the flag off also runs `off`.
    /// Design: docs/specs/2026-10-21-agent-start-admission-design.md.
    func handleAgentsBackground(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(AgentsBackgroundParams.self, from: paramsData)
        guard let controller = agentBackground else {
            return RPCResponse(error: "Agent background priority is not available in this daemon")
        }
        switch params.action {
        case .status:
            return try RPCResponse(result: await controller.status())
        case .off:
            return try RPCResponse(result: await controller.off())
        case .on:
            let enabled = (try? await db.config.get().agentBackgroundEnabled)
                ?? Config.agentBackgroundDefault
            guard enabled else {
                return RPCResponse(
                    error: "Agent background priority is off. Turn it on with: tbd config set agent-background on")
            }
            guard let seconds = params.durationSeconds else {
                return RPCResponse(error: "agents.background on needs durationSeconds")
            }
            do {
                return try RPCResponse(result: await controller.on(for: .seconds(seconds)))
            } catch let error as AgentBackgroundError {
                return RPCResponse(error: error.description)
            }
        }
    }
}
