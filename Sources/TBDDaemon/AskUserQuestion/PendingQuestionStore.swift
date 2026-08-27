import Foundation
import TBDShared

/// Holds the daemon's view of pending `AskUserQuestion`s, keyed on
/// `(terminalID, toolUseID)`. Memory-only; daemon restart wipes the store.
/// The merger inside `handleTerminalTranscript` reads from this and
/// removes entries once a matching `tool_use_id` appears in the JSONL —
/// see `RPCRouter+TerminalHandlers.swift`.
public actor PendingQuestionStore {
    public struct Key: Hashable, Sendable {
        public let terminalID: UUID
        public let toolUseID: String
    }

    private var pending: [Key: PendingAskUserQuestion] = [:]

    public init() {}

    public func set(terminalID: UUID, _ value: PendingAskUserQuestion) {
        let key = Key(terminalID: terminalID, toolUseID: value.toolUseID)
        pending[key] = value
    }

    public func clear(terminalID: UUID, toolUseID: String) {
        pending.removeValue(forKey: Key(terminalID: terminalID, toolUseID: toolUseID))
    }

    public func clear(terminalID: UUID) {
        pending = pending.filter { $0.key.terminalID != terminalID }
    }

    public func entries(forTerminal terminalID: UUID) -> [PendingAskUserQuestion] {
        pending
            .filter { $0.key.terminalID == terminalID }
            .values
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Reap entries older than `maxAge` relative to `now`, and report which
    /// terminals lost one. An entry strands when a user-installed PreToolUse
    /// hook returns `decision: "block"`, so no matching `tool_use_id` ever
    /// reaches the JSONL to satisfy it.
    ///
    /// Driven by `PendingQuestionExpirySweep` on its own timer, and also once
    /// per `handleTerminalTranscript` while that path is still live. The
    /// returned terminal ids are what a caller broadcasts: a reap is a
    /// mutation like any other, and a set reaped without a retraction leaves
    /// the app rendering an entry the daemon no longer holds.
    @discardableResult
    public func gcExpired(now: Date, maxAge: Duration) -> Set<UUID> {
        let maxAgeSeconds = TimeInterval(maxAge.components.seconds)
            + TimeInterval(maxAge.components.attoseconds) / 1e18
        let cutoff = now.addingTimeInterval(-maxAgeSeconds)
        var reaped: Set<UUID> = []
        for (key, value) in pending where value.timestamp < cutoff {
            pending.removeValue(forKey: key)
            reaped.insert(key.terminalID)
        }
        return reaped
    }
}
