import SwiftUI
import TBDShared

struct WorktreeRowView: View {
    let worktree: Worktree
    @EnvironmentObject var appState: AppState
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isTextFieldFocused: Bool

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
            if isEditing {
                TextField("Name", text: $editText)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
                    .onChange(of: isTextFieldFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(worktree.displayName)
                    .fontWeight(hasBoldNotification ? .bold : .regular)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                if appState.selectedWorktreeIDs.contains(worktree.id) {
                    appState.selectedWorktreeIDs.remove(worktree.id)
                } else {
                    appState.selectedWorktreeIDs.insert(worktree.id)
                }
            } else if appState.selectedWorktreeIDs.contains(worktree.id) && !isEditing {
                startRename()
            } else {
                appState.selectedWorktreeIDs = [worktree.id]
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(appState.selectedWorktreeIDs.contains(worktree.id) ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contextMenu {
            SidebarContextMenu(worktree: worktree, onRename: startRename)
        }
    }

    func startRename() {
        editText = worktree.displayName
        isEditing = true
        isTextFieldFocused = true
    }

    private func commitRename() {
        let trimmed = editText.trimmingCharacters(in: .whitespaces)
        isEditing = false
        guard !trimmed.isEmpty, trimmed != worktree.displayName else { return }
        Task {
            await appState.renameWorktree(id: worktree.id, displayName: trimmed)
        }
    }

    private func cancelRename() {
        isEditing = false
    }
}
