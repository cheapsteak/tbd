import Foundation
import TBDShared

/// RPC handlers for orphan-GC (Task 9): `gc.list` / `gc.restore` /
/// `gc.sweepNow`. `gc.list` only needs the DB (reap records are readable
/// even when GC itself is disabled or unwired); `gc.restore` and
/// `gc.sweepNow` need the `OrphanGC` actor and return an error response
/// (never crash) when it's `nil` — mock mode / a daemon that hasn't finished
/// booting it yet.
extension RPCRouter {
    func handleGCList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(GCListParams.self, from: paramsData)
        let records = try await db.reapRecords.list(repoPath: params.repoPath)
        return try RPCResponse(result: records)
    }

    func handleGCRestore(_ paramsData: Data) async throws -> RPCResponse {
        guard let orphanGC else {
            return RPCResponse(error: "gc unavailable")
        }
        let params = try decoder.decode(GCRestoreParams.self, from: paramsData)
        try await orphanGC.restore(recordID: params.recordID)
        return .ok()
    }

    func handleGCSweepNow(_ paramsData: Data) async throws -> RPCResponse {
        guard let orphanGC else {
            return RPCResponse(error: "gc unavailable")
        }
        let params = try decoder.decode(GCSweepNowParams.self, from: paramsData)
        let result = await orphanGC.sweep(dryRun: params.dryRun)
        return try RPCResponse(result: result)
    }
}
