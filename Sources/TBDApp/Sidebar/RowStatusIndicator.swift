import SwiftUI
import TBDShared

/// The single status indicator a sidebar worktree row may display.
enum RowStatusIndicator: Equatable {
    case pendingSpinner
    case workingSpinner
    case notificationBadge(NotificationType)
    case suspended
    case prStatus

    /// Resolves which indicator (if any) a worktree row should show.
    ///
    /// Invariant: a worktree row shows at most one status indicator.
    /// Add new indicators as a branch in this priority chain — never as an
    /// additional stacked icon in `WorktreeRowView`.
    ///
    /// Priority (highest first): pending > working > notification badge > suspended > PR status.
    static func resolve(
        isPending: Bool,
        isWorking: Bool,
        notification: NotificationType?,
        isSuspended: Bool,
        hasPRStatus: Bool
    ) -> RowStatusIndicator? {
        if isPending {
            return .pendingSpinner
        } else if isWorking {
            return .workingSpinner
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
