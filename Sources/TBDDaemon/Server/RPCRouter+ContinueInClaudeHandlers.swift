import Foundation
import os
import TBDShared

private let continueInClaudeLogger = Logger(
    subsystem: "com.tbd.daemon", category: "continue-in-claude")

/// Continuation packets an earlier build staged as files for a launching shell
/// to read, named `continue-in-claude-packet-<terminal>-<request>.txt` in
/// `TBDConstants.runtimeDir`.
///
/// Nothing writes one now: Continue in Claude replaced a Codex process in its
/// tmux window, and TBD no longer starts processes on tmux. A build that
/// crashed mid-transaction could leave one behind, so
/// `reconcilePendingContinueInClaude` — at startup and hourly — still sweeps
/// any older than `staleAge`.
enum ContinuationPacketFile {
    static let prefix = "continue-in-claude-packet-"
    static let suffix = ".txt"
    static let staleAge: TimeInterval = 3600

    /// Removes packet files last modified more than `staleAge` before `now`.
    static func pruneStale(
        directory: URL = TBDConstants.runtimeDir,
        now: Date = Date()
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(suffix) {
            let path = directory.appendingPathComponent(entry).path
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate]
                    as? Date,
                  now.timeIntervalSince(modified) > staleAge else { continue }
            try? fm.removeItem(atPath: path)
            continueInClaudeLogger.info(
                "Pruned stale continuation packet \(entry, privacy: .public)")
        }
    }
}

extension RPCRouter {
    /// The refusal `terminal.continueInClaude` returns for a Codex tab on the
    /// pty holder, which has no tmux window to replace.
    static func holderContinueInClaudeRefusal(terminalID: UUID) -> String {
        "Terminal \(terminalID) runs on the pty-holder transport, which has no tmux window to replace. Its Codex session is unchanged."
    }

    /// The refusal `terminal.continueInClaude` returns for a Codex tab still
    /// on the tmux transport. The replacement relaunched a process in the
    /// tab's tmux window, which TBD no longer does. It does not point at
    /// `tbd terminal migrate`, because a migrated tab is a holder tab, which
    /// this refuses too, and the migration skips Codex tabs anyway.
    static func tmuxContinueInClaudeRefusal(terminalID: UUID) -> String {
        "Terminal \(terminalID) runs Codex on the tmux transport, which TBD no longer starts sessions on, so Continue in Claude cannot replace it. Its Codex session is unchanged."
    }

    /// `terminal.continueInClaude` refuses every terminal and changes nothing.
    ///
    /// The replacement it made — stop Codex, start Claude in the same tab,
    /// restore Codex on failure — ran in a tmux window, and TBD no longer
    /// starts processes on tmux; a Codex tab on the pty holder has no window to
    /// replace. The method still answers, so the CLI and an older app get a
    /// refusal that says why, with the same wrong-provider code as before for
    /// a tab that is not Codex.
    func handleTerminalContinueInClaude(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(
            TerminalContinueInClaudeParams.self, from: paramsData)
        guard let source = try await db.terminals.get(id: params.sourceTerminalID) else {
            return RPCResponse(error: "Terminal not found: \(params.sourceTerminalID)")
        }
        guard source.kind == .codex else {
            return RPCResponse(
                error: "Continue in Claude requires a Codex terminal.",
                code: RPCErrorCode.terminalWrongProvider.rawValue)
        }
        guard source.transport == .tmux else {
            return RPCResponse(error: Self.holderContinueInClaudeRefusal(terminalID: source.id))
        }
        return RPCResponse(error: Self.tmuxContinueInClaudeRefusal(terminalID: source.id))
    }

    /// Sweeps what an interrupted Continue in Claude from an earlier build can
    /// leave behind. Called once after the socket begins accepting SessionStart
    /// hooks and on orphan maintenance.
    ///
    /// Packet files older than `ContinuationPacketFile.staleAge` are removed. A
    /// row still marked with a pending replacement is only reported: restoring
    /// Codex in it meant relaunching a process in its tmux window, which TBD
    /// no longer does. Closing the tab clears it.
    func reconcilePendingContinueInClaude() async {
        ContinuationPacketFile.pruneStale()
        guard let candidates = try? await db.terminals.listPendingCodexContinuations()
        else { return }
        for candidate in candidates {
            continueInClaudeLogger.warning(
                "Terminal \(candidate.id, privacy: .public) has a Continue in Claude replacement pending from an earlier build; TBD no longer starts processes on tmux, so it cannot restore Codex there. Close the tab to clear it.")
        }
    }
}
