import Foundation
import os
import TBDShared

private let askUserQuestionLog = Logger(subsystem: "com.tbd.daemon", category: "askUserQuestion")

extension RPCRouter {
    /// Stores the pending question payload for a terminal so the merger
    /// inside `handleTerminalTranscript` can synthesize a transcript item
    /// before the assistant `tool_use` line is flushed to the JSONL.
    func handleTerminalAskUserQuestionPending(_ paramsData: Data) async throws -> RPCResponse {
        let p = try decoder.decode(TerminalAskUserQuestionPendingParams.self, from: paramsData)
        let pending = PendingAskUserQuestion(
            toolUseID: p.toolUseID,
            inputJSON: p.inputJSON,
            timestamp: Date(timeIntervalSince1970: TimeInterval(p.timestampMillis) / 1000)
        )
        await pendingQuestions.set(terminalID: p.terminalID, pending)
        askUserQuestionLog.debug("pending stored terminalID=\(p.terminalID.uuidString, privacy: .public) toolUseID=\(p.toolUseID, privacy: .public)")
        return .ok()
    }

    /// Defensive cleanup path — no-op today. The merger performs lazy
    /// cleanup when it observes the matching `tool_use_id` in the JSONL,
    /// which avoids the flicker that eager PostToolUse cleanup would
    /// introduce (Claude flushes the JSONL line slightly after PostToolUse
    /// returns). Keeping the wire format reserved so a future change to
    /// eager cleanup needn't ship a protocol break.
    func handleTerminalAskUserQuestionCleared(_ paramsData: Data) async throws -> RPCResponse {
        let p = try decoder.decode(TerminalAskUserQuestionClearedParams.self, from: paramsData)
        askUserQuestionLog.debug("cleared received (no-op) terminalID=\(p.terminalID.uuidString, privacy: .public) toolUseID=\(p.toolUseID, privacy: .public)")
        return .ok()
    }
}
