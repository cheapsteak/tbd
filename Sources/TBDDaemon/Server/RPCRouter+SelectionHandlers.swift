import Foundation
import TBDShared

extension RPCRouter {
    func handleWorktreeSelectionChanged(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeSelectionChangedParams.self, from: data)
        // TODO: Task 5 will integrate SuspendResumeCoordinator here
        _ = params
        return .ok()
    }
}
