import Foundation
import os
import TBDShared
import TBDKernel

private let logger = Logger(subsystem: "com.tbd.daemon", category: "dev-servers")

/// Saves a holder-backed dev server's final output when its command exits
/// (docs/specs/2026-10-11-dev-servers-design.md, "Exited servers keep their
/// last output"; plan decision D2).
///
/// `HolderRegistry` calls it from `reclaimIfSessionEnded`, after the exit
/// status is established and before the reader is released. Every tab that
/// is not a dev server's is ignored: its Closed Terminals entry is written
/// when it is closed, as it always was.
struct DevServerFinalOutputRecorder: Sendable {
    let db: TBDDatabase
    /// Routes the capture to a viewer's screen when one is attached, exactly
    /// as every history-keeping teardown does
    /// (`WorktreeLifecycle.recordHolderClosedTerminal`). Nil in tests.
    let resolver: HolderScreenResolver?

    func sessionEnded(
        terminalID: UUID,
        status: HolderChildStatus,
        daemonCapture: () async -> String?
    ) async {
        // `try?` flattens `Terminal?` (SE-0230): one binding covers both a
        // failed read and a row that is gone.
        guard let terminal = try? await db.terminals.get(id: terminalID),
              let serverName = terminal.serverName
        else { return }
        let capture: String?
        if let resolver {
            capture = await resolver.closedTerminalCapture(
                terminalID: terminalID, daemonCapture: daemonCapture)
        } else {
            capture = await daemonCapture()
        }
        let exitCode: Int32?
        switch status {
        case .exited(let code): exitCode = code
        case .exitedStatusUnknown, .alive: exitCode = nil
        }
        await db.terminalHistory.recordServerExit(
            terminal: terminal, serverName: serverName, capture: capture, exitCode: exitCode)
        logger.info("""
            saved the last output of dev server \(serverName, privacy: .public) \
            (terminal \(terminalID.uuidString, privacy: .public), \
            \(String(describing: status), privacy: .public))
            """)
    }
}
