import Foundation
import TBDShared

/// RPC handlers for the daemon-owned panel surface (panel tabs spec,
/// "Coordinator", "Tab sync"). `panel.apply` and `panel.syncTabs` route
/// straight to `PanelCoordinator`, which owns idempotency, resource
/// validation and post-commit broadcast — these handlers only decode params,
/// call it and encode the result.
extension RPCRouter {
    func handlePanelGet(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PanelGetParams.self, from: paramsData)
        let result = try await panelCoordinator.get(worktreeID: params.worktreeID, tabID: params.tabID)
        return try RPCResponse(result: result)
    }

    func handlePanelApply(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PanelApplyParams.self, from: paramsData)
        // A `PanelCoordinatorError` (tabNotFound, staleTarget, invalidResource,
        // operation, operationIDReused) propagates to `RPCRouter.handle`'s
        // generic catch.
        let result = try await panelCoordinator.apply(params.envelope)
        return try RPCResponse(result: result)
    }

    /// Imports, re-parents, updates and deletes the worktree's surfaces to
    /// match the app's workspace tabs; see `PanelCoordinator.syncTabs`.
    func handlePanelSyncTabs(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PanelSyncTabsParams.self, from: paramsData)
        let result = try await panelCoordinator.syncTabs(params)
        return try RPCResponse(result: result)
    }
}
