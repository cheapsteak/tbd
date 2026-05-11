import Foundation
import TBDShared

extension RPCRouter {

    // MARK: - Tab Handlers

    func handleTabSetLabel(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TabSetLabelParams.self, from: paramsData)
        try await db.tabs.setLabel(
            tabID: params.tabID,
            worktreeID: params.worktreeID,
            label: params.label
        )
        return .ok()
    }

    func handleTabSetOrder(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TabSetOrderParams.self, from: paramsData)
        // Reject duplicates — order arrays must be a set in disguise.
        if Set(params.tabIDs).count != params.tabIDs.count {
            return RPCResponse(error: "tab.setOrder: duplicate tab IDs not allowed")
        }
        try await db.worktrees.setTabOrder(
            worktreeID: params.worktreeID,
            tabIDs: params.tabIDs
        )
        return .ok()
    }

    func handleTabList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TabListParams.self, from: paramsData)
        let tabs = try await db.tabs.listForWorktree(worktreeID: params.worktreeID)
        let order = try await db.worktrees.getTabOrder(worktreeID: params.worktreeID)
        return try RPCResponse(result: TabListResponse(tabs: tabs, order: order))
    }
}
