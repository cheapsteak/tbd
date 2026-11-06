import Foundation
import TBDShared

/// Whether a parked row belongs to a session restore pass: a `recovery` park
/// this startup made, in a worktree a restored session may run in. Design:
/// `docs/specs/2026-11-06-session-restore-after-restart-design.md`.
///
/// One rule with two readers. The pass selects with it and then hands it to each
/// wake, because a pass selects once and takes about 90 seconds. In that time the
/// user can wake a row and park it again, or archive its worktree. Only the wake
/// can ask late enough: it reads the row after the start-admission check, which
/// runs between the pass and the wake.
///
/// Whether the row can resume is no part of this rule, because every wake asks
/// that for itself.
public struct SessionRestoreCondition: Sendable, Equatable {
    /// The worktree statuses a restored session may belong to. A whitelist, so a
    /// status added later stays left out until somebody decides otherwise.
    static let worktreeStatuses: Set<WorktreeStatus> = [.active, .main]

    /// How far before `parkedSince` a park still counts as this startup's. The
    /// store keeps `hibernatedAt` to the millisecond, so a row parked in the
    /// same millisecond as a `parkedSince` with finer precision reads back
    /// slightly earlier than the moment that preceded it.
    static let stampResolution: TimeInterval = 0.001

    /// When this daemon began its startup reconcile. It separates this startup's
    /// parks from those of earlier restarts.
    public let parkedSince: Date

    public init(parkedSince: Date) {
        self.parkedSince = parkedSince
    }

    public func isMet(by terminal: Terminal, worktreeStatus: WorktreeStatus) -> Bool {
        guard terminal.hibernateReason == .recovery,
              let hibernatedAt = terminal.hibernatedAt else { return false }
        return hibernatedAt >= parkedSince.addingTimeInterval(-Self.stampResolution)
            && Self.worktreeStatuses.contains(worktreeStatus)
    }
}
