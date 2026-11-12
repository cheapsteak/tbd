import Foundation
import os

private let localSessionReconcileLogger = Logger(subsystem: "com.tbd.daemon", category: "local-session-reconcile")

/// Retries deferred SessionStart associations and surviving upgrade rows using
/// only the rollout already named by each terminal. Never discovers by cwd.
struct LocalAgentSessionReconciler: Sendable {
    let db: TBDDatabase

    func reconcile(terminalID: UUID) async {
        do {
            guard let terminal = try await db.terminals.get(id: terminalID), terminal.kind == .codex,
                  terminal.pendingSessionIncarnationID == nil,
                  let sessionID = terminal.claudeSessionID,
                  !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let path = terminal.transcriptPath,
                  case let .topLevel(proof) = CodexRolloutProvenance.classify(path: path) else { return }
            try await db.terminals.catalogProvenCodexSession(expectedTerminal: terminal, proof: proof)
        } catch {
            // Error descriptions may contain private paths or database values.
            localSessionReconcileLogger.warning("Could not reconcile local session catalog; a later pass will retry")
        }
    }

    func reconcileAllCodexTerminals() async {
        do {
            for terminal in try await db.terminals.list() where terminal.kind == .codex {
                await reconcile(terminalID: terminal.id)
            }
        } catch {
            localSessionReconcileLogger.warning("Could not list terminals for local session reconciliation")
        }
    }
}
