import Foundation
import TBDShared

public struct SessionActivityFact: Sendable, Equatable {
    public let terminalID: UUID
    public let isWorking: Bool
    public let isHibernated: Bool
    public init(terminalID: UUID, isWorking: Bool, isHibernated: Bool) {
        self.terminalID = terminalID
        self.isWorking = isWorking
        self.isHibernated = isHibernated
    }
}

/// "Is anyone working here?" from hook-fed session rows and in-memory stamps.
/// Never from terminal text.
public enum WorktreeActivity {
    public static func facts(from terminals: [Terminal]) -> [SessionActivityFact] {
        terminals.map {
            SessionActivityFact(terminalID: $0.id, isWorking: $0.activityState == .working,
                                isHibernated: $0.hibernatedAt != nil)
        }
    }

    public static func isActive(sessions: [SessionActivityFact], lastHookAt: [UUID: Date],
                                lastSelectedAt: Date?, now: Date,
                                window: TimeInterval = PRPollTiers.activityWindow) -> Bool {
        if let selected = lastSelectedAt, now.timeIntervalSince(selected) < window { return true }
        for session in sessions where !session.isHibernated {
            if session.isWorking { return true }
            if let hook = lastHookAt[session.terminalID], now.timeIntervalSince(hook) < window { return true }
        }
        return false
    }
}

/// In-memory recency stamps. Empty after a restart, by design (see the spec, "The scheduler").
///
/// Off until `setEnabled(true)`. Every hook handler stamps it unconditionally,
/// but only the schedule ever reads or prunes it (`RPCRouter.pollScheduleFacts`),
/// so with `pr_poll_schedule_enabled` off an always-on ledger would grow an
/// entry per terminal and worktree for the life of the daemon. `Daemon` enables
/// it on the schedule's start path, before the scheduler starts.
public actor WorktreeActivityLedger {
    private let window: TimeInterval
    /// Whether stamps are recorded at all. See the type comment.
    public private(set) var isEnabled = false
    private var lastHookAt: [UUID: Date] = [:]
    private var lastSelectedAt: [UUID: Date] = [:]
    private var lastSignalAt: [UUID: Date] = [:]
    private var onPossibleActivation: (@Sendable (UUID) async -> Void)?

    public init(window: TimeInterval = PRPollTiers.activityWindow) { self.window = window }

    public func setOnPossibleActivation(_ cb: @escaping @Sendable (UUID) async -> Void) {
        onPossibleActivation = cb
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    public func recordHookEvent(terminalID: UUID, worktreeID: UUID, at date: Date) async {
        guard isEnabled else { return }
        lastHookAt[terminalID] = date
        await signalIfLapsed(worktreeID, at: date)
    }

    public func recordSelection(worktreeID: UUID, at date: Date) async {
        guard isEnabled else { return }
        lastSelectedAt[worktreeID] = date
        await signalIfLapsed(worktreeID, at: date)
    }

    /// Hooks arrive many times a minute; only the first after a lapsed window
    /// can be an idle-to-active change, so only that one wakes the scheduler.
    private func signalIfLapsed(_ worktreeID: UUID, at date: Date) async {
        if let last = lastSignalAt[worktreeID], date.timeIntervalSince(last) < window { return }
        lastSignalAt[worktreeID] = date
        await onPossibleActivation?(worktreeID)
    }

    public func snapshot() -> (hooks: [UUID: Date], selections: [UUID: Date]) {
        (lastHookAt, lastSelectedAt)
    }

    public func retain(terminalIDs: Set<UUID>, worktreeIDs: Set<UUID>) {
        lastHookAt = lastHookAt.filter { terminalIDs.contains($0.key) }
        lastSelectedAt = lastSelectedAt.filter { worktreeIDs.contains($0.key) }
        lastSignalAt = lastSignalAt.filter { worktreeIDs.contains($0.key) }
    }
}
