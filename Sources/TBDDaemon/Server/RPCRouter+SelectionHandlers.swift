import Foundation
import TBDShared

extension RPCRouter {
    /// Handler for `worktree.selectionChanged`. The app continues to send this
    /// notification but the daemon no longer acts on it — auto-suspend (the
    /// previous consumer) was removed on 2026-05-17. Kept as a no-op so the
    /// existing RPC contract stays stable for the app.
    func handleWorktreeSelectionChanged(_ data: Data) async throws -> RPCResponse {
        _ = try decoder.decode(WorktreeSelectionChangedParams.self, from: data)
        return .ok()
    }
}
