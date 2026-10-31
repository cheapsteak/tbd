import Foundation
import TBDShared

/// What `ProgramStatusStore` writes into a terminal's activity columns: the
/// `activityState` value and, for a wait, the block the agent announced.
///
/// The column vocabulary is the one every consumer already reads — working,
/// idle, waiting for user, unknown. The roll-up's richer values (`done`,
/// `error`, `needsAuth`) stay in the store's snapshot for display; in the
/// column they are idle, a session the idle sweep may park.
///
/// `block` is non-nil exactly when `activityState` is `.waitingForUser`; the
/// initializer is private so no other pairing can be built.
///
/// Design: docs/specs/2026-10-30-osc-only-agent-status-design.md ("The store
/// writes the activity columns").
public struct ProgramStatusColumnValue: Sendable, Equatable {
    public let activityState: TerminalActivityState
    public let block: ProgramStatusBlock?

    private init(activityState: TerminalActivityState, block: ProgramStatusBlock?) {
        self.activityState = activityState
        self.block = block
    }

    public static let unknown = ProgramStatusColumnValue(activityState: .unknown, block: nil)
    public static let working = ProgramStatusColumnValue(activityState: .working, block: nil)
    public static let idle = ProgramStatusColumnValue(activityState: .idle, block: nil)

    public static func waitingForUser(_ block: ProgramStatusBlock) -> ProgramStatusColumnValue {
        ProgramStatusColumnValue(activityState: .waitingForUser, block: block)
    }

    /// The stored wait reason: the block alone. Never the report's `msg` or
    /// `title` — those can quote the user's work, and this lands in
    /// `state.db`. nil unless waiting.
    public var awaitingInputReason: AwaitingInputReason? {
        guard let block else { return nil }
        return AwaitingInputReason(message: "", programStatusBlock: block)
    }

    /// The column value a rolled-up session state maps to, or nil when the
    /// state says nothing the column can hold. A wait whose reason carries no
    /// block (none is built that way today) is still a wait, with an unnamed
    /// block.
    public static func mapping(_ value: SessionStateValue) -> ProgramStatusColumnValue? {
        switch value {
        case .working:
            return .working
        case .awaitingInput(let reason):
            return .waitingForUser(
                reason?.programStatusBlock ?? ProgramStatusBlock(kind: nil, taskID: nil))
        case .idle, .done, .error, .needsAuth:
            return .idle
        case .rateLimited, .parked, .gone, .unknown:
            return nil
        }
    }
}

/// What a column write did.
public enum ProgramStatusColumnOutcome: Sendable, Equatable {
    /// Nothing was written: the row is gone, parked, staged for another
    /// process, of another incarnation, or stamped at or after the write with
    /// a different value.
    case refused
    /// The row already held the value.
    case unchanged
    /// The value was written; `previous` is the `activityState` it replaced.
    case written(previous: TerminalActivityState)
}

/// One column write the store asks for.
public struct ProgramStatusColumnWrite: Sendable, Equatable {
    public let terminalID: UUID
    public let value: ProgramStatusColumnValue
    public let scope: ProgramStatusWriteScope
    public let observedAt: Date
    /// The provenance the write stamps on `activityState`: `.programStatus`
    /// for a value the agent reported, `.processLiveness` for the `.unknown`
    /// a child exit writes — so a reader can tell an agent that stopped
    /// reporting because its process is gone from one that never reported.
    public let source: FactSource

    public init(
        terminalID: UUID,
        value: ProgramStatusColumnValue,
        scope: ProgramStatusWriteScope,
        observedAt: Date,
        source: FactSource = .programStatus
    ) {
        self.terminalID = terminalID
        self.value = value
        self.scope = scope
        self.observedAt = observedAt
        self.source = source
    }
}

/// Where `ProgramStatusEffects.live` stamps each accepted report: the PR-poll
/// activity ledger, `WorktreeActivityLedger`, which conforms in `PR`. Taken
/// through this protocol because `PR` sits above `ProgramStatus` in the
/// daemon's layer order.
public protocol AgentEventRecording: Sendable {
    func recordAgentEvent(terminalID: UUID, worktreeID: UUID, at date: Date) async
}

/// Everything `ProgramStatusStore` does outside its own memory: the column
/// write, the attention banner, and the PR-poll ledger stamp. Production
/// builds it in `ProgramStatusEffects.live`; a store built with `.inert`
/// keeps reports in memory and acts on nothing.
public struct ProgramStatusEffects: Sendable {
    public let writeColumns: @Sendable (ProgramStatusColumnWrite) async -> ProgramStatusColumnOutcome
    public let raiseAttention: @Sendable (_ worktreeID: UUID, _ message: String) async -> Void
    public let recordAgentEvent: @Sendable (_ terminalID: UUID, _ worktreeID: UUID, _ at: Date) async -> Void

    public init(
        writeColumns: @escaping @Sendable (ProgramStatusColumnWrite) async -> ProgramStatusColumnOutcome,
        raiseAttention: @escaping @Sendable (_ worktreeID: UUID, _ message: String) async -> Void,
        recordAgentEvent: @escaping @Sendable (_ terminalID: UUID, _ worktreeID: UUID, _ at: Date) async -> Void
    ) {
        self.writeColumns = writeColumns
        self.raiseAttention = raiseAttention
        self.recordAgentEvent = recordAgentEvent
    }

    /// Writes nothing (every column write is refused), raises nothing, stamps
    /// nothing.
    public static let inert = ProgramStatusEffects(
        writeColumns: { _ in .refused },
        raiseAttention: { _, _ in },
        recordAgentEvent: { _, _, _ in })
}

/// The attention banner's text. Fixed per agent and kind, because the
/// notification is a stored row and a report's `msg` must not reach
/// `state.db`.
///
/// Design: docs/specs/2026-10-30-osc-only-agent-status-design.md ("Attention
/// banner").
public enum ProgramStatusAttention {
    public static func message(app: String?, block: ProgramStatusBlock) -> String {
        let agent = app == ProgramStatusProtocol.codexApp ? "Codex" : "Claude"
        // A blocked task entry is labelled by its task, not by its kind.
        guard block.taskID == nil else { return "\(agent) needs your input" }
        switch block.kind {
        case .permission:
            return "\(agent) needs your permission"
        case .question:
            return "\(agent) has a question"
        case nil, .auth, .unrecognized:
            return "\(agent) needs your input"
        }
    }
}
