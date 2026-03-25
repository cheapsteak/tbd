import SwiftUI
import TBDShared

struct WorktreeRowView: View {
    let worktree: Worktree
    var isMain: Bool = false
    @EnvironmentObject var appState: AppState
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var emojiQuery: String?
    @State private var emojiSelectedIndex = 0

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

    private var worktreeIcon: String? {
        guard !isMain else { return nil }
        let prState = appState.prStatuses[worktree.id]?.state
        // PR state takes priority over local conflict detection —
        // a merged PR means the branch is done regardless of local git status.
        if let prState {
            switch prState {
            case .open, .changesRequested, .mergeable: return "git-pull-request"
            case .merged:                              return "git-merge"
            case .closed:                              return "git-pull-request-closed"
            }
        }
        if worktree.hasConflicts {
            return "git-merge-conflict"
        }
        return nil
    }

    private var worktreeIconColor: Color {
        guard !isMain else { return .secondary }
        let prState = appState.prStatuses[worktree.id]?.state
        if let prState {
            switch prState {
            case .open:             return .secondary
            case .changesRequested: return .red
            case .mergeable:        return .green
            case .merged:           return .purple
            case .closed:           return .secondary
            }
        }
        if worktree.hasConflicts {
            return .orange
        }
        return .secondary
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
            if let icon = worktreeIcon, let nsImage = loadIcon(icon) {
                Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(worktreeIconColor)
            }
            if isEditing {
                TextField("Name", text: $editText)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        if emojiQuery != nil, let emoji = selectedEmoji() {
                            replaceColonQuery(with: emoji)
                        } else {
                            commitRename()
                        }
                    }
                    .onExitCommand {
                        if emojiQuery != nil {
                            emojiQuery = nil
                        } else {
                            cancelRename()
                        }
                    }
                    .onKeyPress(.downArrow) {
                        guard emojiQuery != nil else { return .ignored }
                        emojiSelectedIndex += 7 // grid row = 7 columns
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard emojiQuery != nil else { return .ignored }
                        emojiSelectedIndex = max(0, emojiSelectedIndex - 7)
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        guard emojiQuery != nil else { return .ignored }
                        emojiSelectedIndex += 1
                        return .handled
                    }
                    .onKeyPress(.leftArrow) {
                        guard emojiQuery != nil else { return .ignored }
                        emojiSelectedIndex = max(0, emojiSelectedIndex - 1)
                        return .handled
                    }
                    .onChange(of: editText) { _, newValue in
                        updateEmojiQuery(newValue)
                    }
                    .onChange(of: isTextFieldFocused) { _, focused in
                        if !focused && emojiQuery == nil {
                            commitRename()
                        }
                    }
                    .popover(isPresented: showEmojiPicker, arrowEdge: .bottom) {
                        EmojiPickerView(
                            query: emojiQuery ?? "",
                            selectedIndex: $emojiSelectedIndex,
                            onSelect: { emoji in replaceColonQuery(with: emoji) }
                        )
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

    // MARK: - Emoji autocomplete

    private var showEmojiPicker: Binding<Bool> {
        Binding(
            get: { emojiQuery != nil },
            set: { if !$0 { emojiQuery = nil } }
        )
    }

    /// Find the last unmatched `:` in editText (no space or `:` after it).
    private var activeColonRange: Range<String.Index>? {
        guard let colonIndex = editText.lastIndex(of: ":") else { return nil }
        let afterColon = editText[editText.index(after: colonIndex)...]
        if afterColon.contains(" ") || afterColon.contains(":") { return nil }
        return colonIndex..<editText.endIndex
    }

    private func updateEmojiQuery(_ text: String) {
        if let range = activeColonRange {
            let query = String(editText[editText.index(after: range.lowerBound)..<range.upperBound])
            emojiQuery = query
            emojiSelectedIndex = 0
        } else {
            emojiQuery = nil
        }
    }

    private func replaceColonQuery(with emoji: String) {
        guard let range = activeColonRange else { return }
        editText.replaceSubrange(range, with: emoji)
        emojiQuery = nil
        var frecency = EmojiFrecency.load()
        frecency.record(emoji)
        // Re-focus the text field after popover dismissal
        DispatchQueue.main.async {
            isTextFieldFocused = true
        }
    }

    private func selectedEmoji() -> String? {
        guard let query = emojiQuery else { return nil }
        let frecency = EmojiFrecency.load()
        let results = query.isEmpty
            ? frecency.defaults()
            : frecency.search(query, limit: 21)
        guard !results.isEmpty else { return nil }
        let index = min(emojiSelectedIndex, results.count - 1)
        return results[index].emoji
    }

    private func loadIcon(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
}
