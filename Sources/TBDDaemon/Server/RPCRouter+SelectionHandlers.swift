import Foundation
import TBDShared

extension RPCRouter {
    func handleWorktreeSelectionChanged(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeSelectionChangedParams.self, from: data)
        let newSelection = Set(params.selectedWorktreeIDs)
        await suspendResumeCoordinator.selectionChanged(to: newSelection)
        return .ok()
    }
}
