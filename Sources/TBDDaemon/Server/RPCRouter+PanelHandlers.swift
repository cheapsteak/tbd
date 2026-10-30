import Foundation
import TBDShared

/// Stable error string for a refused `panel.apply` or `panel.syncTabs`. It
/// names the flag so the app and CLI can surface an actionable message; they
/// match the flag name, not this exact text.
private let panelTabsDisabledError = "the side panel with tabs is disabled (panel_tabs_enabled is off)"

/// RPC handlers for the daemon-owned panel surface (panel tabs spec,
/// "Coordinator and gating", "Tab sync"). `panel.get` is ungated.
/// `panel.apply` and `panel.syncTabs` route straight to `PanelCoordinator`,
/// which owns gating, idempotency, resource validation and post-commit
/// broadcast — these handlers only decode params and translate the
/// coordinator's gate error to its stable string. Do NOT re-implement gating
/// here.
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
            return RPCResponse(error: panelTabsDisabledError)
        }
        // Every other `PanelCoordinatorError` case (tabNotFound, staleTarget,
        // invalidResource, operation) has no stable-string requirement — it
        // propagates to `RPCRouter.handle`'s generic catch.
    }

    /// Imports, re-parents, updates and deletes the worktree's surfaces to
    /// match the app's workspace tabs; see `PanelCoordinator.syncTabs`.
    func handlePanelSyncTabs(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PanelSyncTabsParams.self, from: paramsData)
        do {
            let result = try await panelCoordinator.syncTabs(params)
            return try RPCResponse(result: result)
        } catch PanelCoordinatorError.surfaceDisabled {
            return RPCResponse(error: panelTabsDisabledError)
        }
    }
}
