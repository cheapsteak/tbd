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

    /// One terminal's set together with the revision that produced it.
    ///
    /// Handed out as a pair by a single actor call on purpose. A broadcaster
    /// that read the set and its revision in two `await`s could be suspended
    /// between them and publish a set stamped with someone else's revision —
    /// exactly the tear the revision exists to detect.
    public struct Snapshot: Sendable, Equatable {
        public let entries: [PendingAskUserQuestion]
        public let revision: UInt64
    }

    private var pending: [Key: PendingAskUserQuestion] = [:]

    /// Per-terminal mutation counter. Monotonic within one daemon run, and
    /// only ever compared against another revision for the SAME terminal —
    /// terminals never share an ordering domain.
    ///
    /// It exists because publishing is two steps (mutate, then read-and-send)
    /// and the actor only makes each step atomic, not the pair. Two tasks
    /// mutating one terminal can therefore reach `broadcast` in either order,
    /// and the app replaces its whole list per delta — so a `set` that lands
    /// after a `clear` resurrects a question the user already answered.
    /// Stamping each published set lets the app drop what it can see is stale.
    private var revisions: [UUID: UInt64] = [:]

    public init() {}

    private func bumpRevision(_ terminalID: UUID) {
        revisions[terminalID, default: 0] += 1
    }

    public func set(terminalID: UUID, _ value: PendingAskUserQuestion) {
        let key = Key(terminalID: terminalID, toolUseID: value.toolUseID)
        pending[key] = value
        bumpRevision(terminalID)
    }

    public func clear(terminalID: UUID, toolUseID: String) {
        pending.removeValue(forKey: Key(terminalID: terminalID, toolUseID: toolUseID))
        bumpRevision(terminalID)
    }

    public func clear(terminalID: UUID) {
        pending = pending.filter { $0.key.terminalID != terminalID }
        bumpRevision(terminalID)
    }

    public func entries(forTerminal terminalID: UUID) -> [PendingAskUserQuestion] {
        pending
            .filter { $0.key.terminalID == terminalID }
            .values
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// The set and its revision, read together. This is what a broadcaster
    /// publishes — see ``Snapshot``.
    public func snapshot(forTerminal terminalID: UUID) -> Snapshot {
        Snapshot(
            entries: entries(forTerminal: terminalID),
            revision: revisions[terminalID] ?? 0)
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
        for terminalID in reaped {
            bumpRevision(terminalID)
        }
        return reaped
    }
}
