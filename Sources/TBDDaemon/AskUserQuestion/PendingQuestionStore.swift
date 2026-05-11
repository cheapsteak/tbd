import Foundation
import TBDShared

/// One in-flight `AskUserQuestion` capture relayed by the
/// `PreToolUse:AskUserQuestion` hook bridge. `inputJSON` is the verbatim
/// `tool_input` object from the hook payload, re-serialized with sorted
/// keys — the SwiftUI card decodes it the same way it decodes JSONL-backed
/// tool-use input.
public struct PendingAskUserQuestion: Sendable, Equatable {
    public let toolUseID: String
    public let inputJSON: String
    public let timestamp: Date
    public init(toolUseID: String, inputJSON: String, timestamp: Date) {
        self.toolUseID = toolUseID
        self.inputJSON = inputJSON
        self.timestamp = timestamp
    }
}

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

    /// Reap entries older than `maxAge` relative to `now`. Called once
    /// per `handleTerminalTranscript` to keep stranded entries (e.g.
    /// user-installed PreToolUse hook returned `decision: "block"`) from
    /// living forever.
    public func gcExpired(now: Date, maxAge: Duration) {
        let maxAgeSeconds = TimeInterval(maxAge.components.seconds)
            + TimeInterval(maxAge.components.attoseconds) / 1e18
        let cutoff = now.addingTimeInterval(-maxAgeSeconds)
        pending = pending.filter { $0.value.timestamp >= cutoff }
    }
}

/// Pure merge function: combines JSONL-derived items with pending
/// AskUserQuestion entries and reports which pending entries are
/// satisfied by JSONL matches. Pulled out of the RPC handler so it can
/// be tested without an RPCRouter.
public enum AskUserQuestionMerger {
    public struct Result: Equatable {
        public let items: [TranscriptItem]
        /// Pending tool_use_ids that already have a matching JSONL item
        /// and should be removed from the store. Caller does the removal.
        public let satisfiedToolUseIDs: [String]
    }

    public static func merge(
        jsonlItems: [TranscriptItem],
        pending: [PendingAskUserQuestion]
    ) -> Result {
        var jsonlIDs = Set<String>()
        for item in jsonlItems {
            if case let .toolCall(id, _, _, _, _, _, _, _) = item {
                jsonlIDs.insert(id)
            }
        }

        var merged = jsonlItems
        var satisfied: [String] = []
        for p in pending {
            if jsonlIDs.contains(p.toolUseID) {
                satisfied.append(p.toolUseID)
                continue
            }
            merged.append(.toolCall(
                id: p.toolUseID,
                name: "AskUserQuestion",
                inputJSON: p.inputJSON,
                inputTruncatedTo: nil,
                result: nil,
                subagent: nil,
                timestamp: p.timestamp,
                usage: nil
            ))
        }
        return Result(items: merged, satisfiedToolUseIDs: satisfied)
    }
}
