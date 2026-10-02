import Foundation
import TBDShared

/// Which schedule a polled item is on. See
/// docs/specs/2026-10-01-pr-polling-schedule-design.md, "Intervals by status".
public enum PRPollTier: String, Sendable, Equatable {
    /// Required checks running. Fast, never stretched, bounded by count.
    case checksRunning
    /// Waiting on people: checks failed, changes requested, blocked, draft, ready.
    case waiting
    /// A closed PR's branch, back in discovery while its worktree is active.
    case closedDiscovery
    /// A branch with no known PR.
    case discovery
}

/// What the schedule knows about one item before choosing its interval.
public enum PRPollSubject: Sendable, Equatable {
    /// No PR bound: discovery by branch.
    case noPR
    /// A bound PR; `nil` state means bound but never observed.
    case pr(PRMergeableState?)
}

public struct PRPollSlot: Sendable, Equatable {
    public let tier: PRPollTier
    public let interval: Duration
    public init(tier: PRPollTier, interval: Duration) {
        self.tier = tier
        self.interval = interval
    }
}

public enum PRPollTiers {
    public static let checksRunningInterval: Duration = .seconds(60)
    public static let waitingActiveInterval: Duration = .seconds(120)
    public static let waitingIdleInterval: Duration = .seconds(360)
    public static let closedActiveInterval: Duration = .seconds(1800)
    public static let discoveryActiveInterval: Duration = .seconds(600)
    public static let discoveryIdleInterval: Duration = .seconds(3600)
    /// Pending PRs beyond `fastTierCapacity` wait here, oldest first to move up.
    public static let fastTierOverflowInterval: Duration = .seconds(120)
    /// No stretched interval exceeds this.
    public static let maxStretchedInterval: Duration = .seconds(3600)
    public static let fastTierCapacity = 10
    /// How long a hook event or a selection keeps a worktree active.
    public static let activityWindow: TimeInterval = 1800
    /// Spec: every item counts 1 point per round. Items due together share a
    /// query per repo and GitHub charges per query, so this is an upper bound.
    public static let pointsPerItem: Double = 1

    /// `(status, active) -> interval`. `nil` means the item is not scheduled.
    public static func slot(for subject: PRPollSubject, active: Bool) -> PRPollSlot? {
        switch subject {
        case .noPR:
            return PRPollSlot(tier: .discovery,
                              interval: active ? discoveryActiveInterval : discoveryIdleInterval)
        case .pr(let state):
            switch state {
            case .pending:
                return PRPollSlot(tier: .checksRunning, interval: checksRunningInterval)
            case nil, .blocked, .changesRequested, .draft, .checksFailed, .mergeable:
                return PRPollSlot(tier: .waiting,
                                  interval: active ? waitingActiveInterval : waitingIdleInterval)
            case .closed:
                return active ? PRPollSlot(tier: .closedDiscovery, interval: closedActiveInterval) : nil
            case .merged:
                return nil
            }
        }
    }

    public static func points(for tier: PRPollTier) -> Double { pointsPerItem }

    public static func isStretchable(_ tier: PRPollTier) -> Bool { tier != .checksRunning }
}
