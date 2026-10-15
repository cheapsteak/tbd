import Foundation
import TBDShared

/// Program Status Protocol (OSC 7501) RPCs.
/// Design: docs/specs/2026-10-10-program-status-protocol-design.md.
extension RPCRouter {
    /// A report the app read off a holder pty while attached. Always ok: the
    /// store debug-logs a rejection, and the app must not retry one.
    func handleTerminalProgramStatusReport(_ paramsData: Data) async throws -> RPCResponse {
        let p = try decoder.decode(TerminalProgramStatusReportParams.self, from: paramsData)
        let inbound = ProgramStatusStore.Inbound(
            terminalID: p.terminalID,
            incarnation: .claimed(p.incarnationID),
            payload: Array(p.payload.utf8),
            observedAt: p.observedAt)
        _ = await programStatus.ingest(inbound)
        return .ok()
    }

    /// Every terminal's current snapshot; empty while the flag is off.
    func handleTerminalProgramStatusList() async throws -> RPCResponse {
        let snapshots: [ProgramStatusSnapshot]
        if programStatus.gate.isEnabled {
            snapshots = await programStatus.allSnapshots()
        } else {
            snapshots = []
        }
        return try RPCResponse(result: TerminalProgramStatusListResult(snapshots: snapshots))
    }
}
