import SwiftUI
import TBDShared

struct WorktreeRowView: View {
    let worktree: Worktree
    var isMain: Bool = false
    @EnvironmentObject var appState: AppState
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isTextFieldFocused: Bool

    private var isPending: Bool {
        worktree.status == .creating
    }

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

    private var gitStatusIcon: String? {
        guard !isMain, worktree.hasConflicts else { return nil }
        return "exclamationmark.triangle"
    }

    private var gitStatusColor: Color {
        worktree.hasConflicts ? .orange : .secondary
    }

    private var prIcon: String? {
        guard !isMain, let status = appState.prStatuses[worktree.id] else { return nil }
        switch status.state {
        case .open, .changesRequested: return "git-pull-request"
        case .mergeable:               return "git-pull-request"
        case .merged:                  return "git-merge"
        case .closed:                  return "git-pull-request-closed"
        }
    }

    private var prIconColor: Color {
        guard !isMain, let status = appState.prStatuses[worktree.id] else { return .secondary }
        switch status.state {
        case .open:             return .secondary
        case .changesRequested: return .red
        case .mergeable:        return .green
        case .merged:           return .purple
        case .closed:           return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if isMain {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isPending && !isEditing {
                ProgressView()
                    .controlSize(.small)
            } else if let color = badgeColor {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            if let icon = gitStatusIcon {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(gitStatusColor)
            }
            if let icon = prIcon, let nsImage = loadIcon(icon) {
                Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(prIconColor)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(worktree.displayName)
                        .fontWeight(hasBoldNotification ? .bold : .regular)
                        .lineLimit(1)
                    if isPending {
                        Text("Creating worktree…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
            } else if !isMain && appState.selectedWorktreeIDs.contains(worktree.id) && !isEditing {
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
        .onChange(of: appState.editingWorktreeID) { _, newID in
            if newID == worktree.id {
                startRename()
                appState.editingWorktreeID = nil
            }
        }
    }

    func startRename() {
        guard !isMain else { return }
        editText = worktree.displayName
        isEditing = true
        isTextFieldFocused = true
    }

    private func commitRename() {
        let trimmed = editText.trimmingCharacters(in: .whitespaces)
        isEditing = false
        guard !trimmed.isEmpty, trimmed != worktree.displayName else { return }
        // Update local model immediately so the UI reflects the new name
        for repoID in appState.worktrees.keys {
            if let idx = appState.worktrees[repoID]?.firstIndex(where: { $0.id == worktree.id }) {
                appState.worktrees[repoID]?[idx].displayName = trimmed
            }
        }
        // Then persist to daemon
        Task {
            await appState.renameWorktree(id: worktree.id, displayName: trimmed)
        }
    }

    private func cancelRename() {
        isEditing = false
    }

    private func loadIcon(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
}
