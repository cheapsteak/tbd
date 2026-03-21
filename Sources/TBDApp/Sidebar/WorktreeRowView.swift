import SwiftUI
import TBDShared

struct WorktreeRowView: View {
    let worktree: Worktree
    @EnvironmentObject var appState: AppState
    @State private var showRenameAlert = false
    @State private var renameText = ""

    private var notification: NotificationType? {
        appState.notifications[worktree.id] ?? nil
    }

    private var hasBoldNotification: Bool {
        if let n = notification {
            return n == .responseComplete
        }
        return false
    }

    private var badgeColor: Color? {
        guard let n = notification else { return nil }
        switch n {
        case .error:
            return .red
        case .attentionNeeded:
            return .orange
        case .taskComplete:
            return .green
        case .responseComplete:
            return .blue
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let color = badgeColor {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.displayName)
                    .fontWeight(hasBoldNotification ? .bold : .regular)
                    .lineLimit(1)
                Text(worktree.branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contextMenu {
            SidebarContextMenu(worktree: worktree, showRenameAlert: $showRenameAlert, renameText: $renameText)
        }
        .alert("Rename Worktree", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                Task {
                    await appState.renameWorktree(id: worktree.id, displayName: renameText)
                }
            }
        } message: {
            Text("Enter a new display name for this worktree.")
        }
    }
}
