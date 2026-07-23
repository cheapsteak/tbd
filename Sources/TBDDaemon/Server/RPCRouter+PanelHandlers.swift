import Foundation
import TBDShared

/// RPC handlers for the daemon-owned panel surface (Task 10, spec C §10).
/// `panel.get` is ungated (§10.2); `panel.apply` routes straight to
/// `PanelCoordinator.apply`, which owns gating, idempotency, resource
/// validation, and post-commit broadcast internally — these handlers only
/// decode params and translate the coordinator's typed errors to RPC
/// responses. Do NOT re-implement gating here.
extension RPCRouter {
    func handlePanelGet(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PanelGetParams.self, from: paramsData)
        let result = try await panelCoordinator.get(worktreeID: params.worktreeID, tabID: params.tabID)
        return try RPCResponse(result: result)
    }

    func handlePanelApply(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PanelApplyParams.self, from: paramsData)
        do {
            let result = try await panelCoordinator.apply(params.envelope)
            return try RPCResponse(result: result)
        } catch PanelCoordinatorError.surfaceDisabled {
            // Stable string (spec §10.2) — names the flag so the app/CLI can
            // surface an actionable message without matching this exactly.
            return RPCResponse(error: "panel surface is disabled (daemon_panel_surface_enabled)")
        } catch PanelCoordinatorError.agentControlDisabled {
            return RPCResponse(error: "agent panel control is disabled (agent_panel_control_enabled)")
        }
        // Every other `PanelCoordinatorError` case (tabNotFound, staleTarget,
        // invalidResource, operation) has no stable-string requirement — it
        // propagates to `RPCRouter.handle`'s generic catch, which formats it
        // via string interpolation.
    }

    /// Task 11 wires the real legacy-import migration. This route exists now
    /// so dispatch is complete and testable ahead of that work.
    func handlePanelImportLegacy(_ paramsData: Data) async throws -> RPCResponse {
        _ = try decoder.decode(PanelImportParams.self, from: paramsData)
        return RPCResponse(error: "panel.importLegacy is not implemented yet")
    }
}
