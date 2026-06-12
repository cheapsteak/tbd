import SwiftUI
import TBDShared

/// The single status indicator a sidebar worktree row may display.
enum RowStatusIndicator: Equatable {
    case pending
    case working
    case notificationBadge(NotificationType)
    case suspended
    case prStatus

    /// Notifications at or above this `NotificationType.severity` outrank the
    /// working icon: errors and attention/focus requests must not be hidden
    /// behind a working indicator that can show for minutes. Lower-severity
    /// completion badges yield to the working icon, so a stale "done" dot
    /// never masks active work.
    private static let highSeverityThreshold = 3

    /// Resolves which indicator (if any) a worktree row should show.
    ///
    /// Invariant: a worktree row shows at most one status indicator.
    /// Add new indicators as a branch in this priority chain — never as an
    /// additional stacked icon in `WorktreeRowView`.
    ///
    /// Priority (highest first): pending > high-severity badge (error,
    /// attentionNeeded, focusRequest) > working > low-severity badge
    /// (taskComplete, responseComplete) > suspended > PR status.
    static func resolve(
        isPending: Bool,
        isWorking: Bool,
        notification: NotificationType?,
        isSuspended: Bool,
        hasPRStatus: Bool
    ) -> RowStatusIndicator? {
        if isPending {
            return .pending
        } else if let notification, notification.severity >= highSeverityThreshold {
            return .notificationBadge(notification)
        } else if isWorking {
            return .working
        } else if let notification {
            return .notificationBadge(notification)
        } else if isSuspended {
            return .suspended
        } else if hasPRStatus {
            return .prStatus
        }
        return nil
    }

    /// Badge dot color for `notificationBadge` cases.
    static func badgeColor(for notification: NotificationType) -> Color {
        switch notification {
        case .error:
            return .red
        case .attentionNeeded, .focusRequest:
            return .orange
        case .taskComplete:
            return .green
        case .responseComplete:
            return .blue
        }
    }
}
