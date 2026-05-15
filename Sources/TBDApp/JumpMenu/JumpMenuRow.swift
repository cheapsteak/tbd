import SwiftUI
import TBDShared

/// A single row in the jump menu. `section` is `.unread` or `.recent` in the
/// default (empty-query) state and `.match` while the user is typing.
struct JumpMenuRow: Identifiable, Equatable {
    enum Section: Equatable {
        case unread
        case recent
        case match
    }

    let id: UUID                  // worktree ID
    let displayName: String       // includes leading emoji if any
    let repoName: String
    let severity: NotificationType?   // nil for recent / match-without-unread
    let section: Section
}

/// Color the severity dot. Mirrors WorktreeRowView's logic so the two views
/// stay visually consistent.
private func severityColor(_ type: NotificationType) -> Color {
    switch type {
    case .error:            return .red
    case .attentionNeeded:  return .orange
    case .taskComplete:     return .green
    case .responseComplete: return .blue
    }
}

/// A 6pt dot in the severity color, or a transparent spacer of the same
/// width so rows without unread notifications still align with rows that
/// have one.
private struct SeverityDot: View {
    let severity: NotificationType?
    var body: some View {
        Circle()
            .fill(severity.map(severityColor) ?? .clear)
            .frame(width: 6, height: 6)
    }
}

struct JumpMenuRowView: View {
    let row: JumpMenuRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            SeverityDot(severity: row.severity)
            Text(row.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(row.repoName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
