import Foundation
import os
import TBDShared

private let askUserQuestionLog = Logger(subsystem: "com.tbd.daemon", category: "askUserQuestion")

/// Banner-friendly cap for the message we store on the notification. Long
/// enough to convey the gist, short enough not to overflow macOS notification
/// banners or the app's unread tooltip.
private let askUserQuestionMessageMaxLength = 120

/// Fallback banner text when the AskUserQuestion `tool_input` can't be parsed.
/// We never want a failed parse to swallow the unread signal — the agent is
/// still paused waiting for the user.
private let askUserQuestionFallbackMessage = "Claude is waiting for your answer"

extension RPCRouter {
    /// Stores the pending question payload for a terminal so the merger
    /// inside `handleTerminalTranscript` can synthesize a transcript item
    /// before the assistant `tool_use` line is flushed to the JSONL.
    ///
    /// Additionally marks the worktree as needing attention by creating an
    /// `attentionNeeded` notification and broadcasting the matching delta.
    /// Without this the Stop hook (end of turn) is the only path that flips
    /// the worktree to unread, but Stop doesn't fire while a tool call is
    /// pending — so an AskUserQuestion would otherwise leave the worktree
    /// silently waiting.
    func handleTerminalAskUserQuestionPending(_ paramsData: Data) async throws -> RPCResponse {
        let p = try decoder.decode(TerminalAskUserQuestionPendingParams.self, from: paramsData)
        let pending = PendingAskUserQuestion(
            toolUseID: p.toolUseID,
            inputJSON: p.inputJSON,
            timestamp: Date(timeIntervalSince1970: TimeInterval(p.timestampMillis) / 1000)
        )
        await pendingQuestions.set(terminalID: p.terminalID, pending)
        askUserQuestionLog.debug("pending stored terminalID=\(p.terminalID.uuidString, privacy: .public) toolUseID=\(p.toolUseID, privacy: .public)")

        // Resolve the worktree this terminal belongs to. If the terminal row
        // is missing (race with terminal teardown, or a stale CLI relay) we
        // intentionally skip the notification — the pendingQuestions update
        // above is still useful for the transcript merger.
        if let terminal = try? await db.terminals.get(id: p.terminalID) {
            let message = Self.askUserQuestionMessage(fromInputJSON: p.inputJSON)
            do {
                let notification = try await db.notifications.create(
                    worktreeID: terminal.worktreeID,
                    type: .attentionNeeded,
                    message: message
                )
                subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
                    notificationID: notification.id,
                    worktreeID: notification.worktreeID,
                    type: notification.type,
                    message: notification.message
                )))
                askUserQuestionLog.debug("attentionNeeded notification created worktreeID=\(terminal.worktreeID.uuidString, privacy: .public)")
            } catch {
                askUserQuestionLog.debug("failed to create attentionNeeded notification: \(String(describing: error), privacy: .public)")
            }
        } else {
            askUserQuestionLog.debug("terminal missing — skipped notification terminalID=\(p.terminalID.uuidString, privacy: .public)")
        }

        return .ok()
    }

    /// Cleanup path fired by `PostToolUse:AskUserQuestion`. Belt-and-suspenders
    /// markRead: today, answering an AskUserQuestion requires typing into the
    /// terminal, which means focusing the pane, which already triggers
    /// `notifications.markRead` via `ContentView.onChange(selectedWorktreeIDs)`
    /// on the app side. Marking read again here is harmless and lets future
    /// answer-without-focus flows (e.g. an in-app picker) clear the badge
    /// without any extra plumbing.
    ///
    /// The merger still performs lazy pendingQuestions cleanup when it
    /// observes the matching `tool_use_id` in the JSONL — we don't eagerly
    /// clear here, which avoids the flicker that eager cleanup would
    /// introduce (Claude flushes the JSONL line slightly after PostToolUse
    /// returns).
    func handleTerminalAskUserQuestionCleared(_ paramsData: Data) async throws -> RPCResponse {
        let p = try decoder.decode(TerminalAskUserQuestionClearedParams.self, from: paramsData)
        askUserQuestionLog.debug("cleared received terminalID=\(p.terminalID.uuidString, privacy: .public) toolUseID=\(p.toolUseID, privacy: .public)")

        if let terminal = try? await db.terminals.get(id: p.terminalID) {
            do {
                try await db.notifications.markRead(worktreeID: terminal.worktreeID)
            } catch {
                askUserQuestionLog.debug("markRead failed: \(String(describing: error), privacy: .public)")
            }
        }
        return .ok()
    }

    /// Extracts a banner-friendly message from the raw AskUserQuestion
    /// `tool_input` JSON. The shape is
    /// `{"questions":[{"question":"...","header":"...","options":[...]}, ...]}`
    /// with 1–4 questions; we pick the first question's `question` field and
    /// truncate to `askUserQuestionMessageMaxLength`. Anything malformed falls
    /// back to a generic "waiting for your answer" string — we never throw
    /// out of this path because that would swallow the unread signal.
    static func askUserQuestionMessage(fromInputJSON inputJSON: String) -> String {
        guard
            let data = inputJSON.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let questions = root["questions"] as? [[String: Any]],
            let first = questions.first,
            let text = first["question"] as? String,
            !text.isEmpty
        else {
            return askUserQuestionFallbackMessage
        }
        return truncate(text, to: askUserQuestionMessageMaxLength)
    }

    private static func truncate(_ s: String, to maxLength: Int) -> String {
        guard s.count > maxLength else { return s }
        // Reserve one character for the ellipsis so the visible length stays
        // <= maxLength.
        let endIndex = s.index(s.startIndex, offsetBy: maxLength - 1)
        return String(s[s.startIndex..<endIndex]) + "…"
    }
}
