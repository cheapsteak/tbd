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

struct JumpMenuRowView: View {
    let row: JumpMenuRow
    let isSelected: Bool

    private var suffix: SuffixRowIndicator? {
        RowStatusIndicator.suffix(notification: row.severity, isWorking: false, isSuspended: false)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(row.displayName)
                .font(.system(size: 13))
                .fontWeight(RowStatusIndicator.shouldBoldName(row.severity) ? .bold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(row.repoName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let indicator = suffix, let symbol = indicator.systemImage {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(indicator.color)
                    .frame(width: 12, height: 12)
            }
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
