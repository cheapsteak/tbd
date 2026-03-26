import SwiftUI
import TBDShared

struct WorktreeRowView: View {
    let worktree: Worktree
    var isMain: Bool = false
    @EnvironmentObject var appState: AppState
    @State private var isEditing = false
    @State private var editText = ""
    @State private var cursorPosition = 0
    @State private var isTextFieldFocused = false
    @State private var emojiQuery: String?
    @State private var emojiSelectedIndex = 0
    @State private var isHovered = false
    @State private var frecency = EmojiFrecency.load()

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
                InlineTextField(
                    text: $editText,
                    cursorPosition: $cursorPosition,
                    isFocused: $isTextFieldFocused,
                    onSubmit: {
                        if emojiQuery != nil, let emoji = selectedEmoji() {
                            replaceColonQuery(with: emoji)
                        } else {
                            commitRename()
                        }
                    },
                    onCancel: {
                        if emojiQuery != nil {
                            emojiQuery = nil
                        } else {
                            cancelRename()
                        }
                    },
                    onKeyDown: { keyCode in
                        guard emojiQuery != nil else { return false }
                        switch keyCode {
                        case 125: emojiSelectedIndex += 7; return true  // down
                        case 126: emojiSelectedIndex = max(0, emojiSelectedIndex - 7); return true // up
                        case 124: emojiSelectedIndex += 1; return true  // right
                        case 123: emojiSelectedIndex = max(0, emojiSelectedIndex - 1); return true // left
                        default: return false
                        }
                    },
                    onSpecialKey: { key in
                        guard emojiQuery != nil, let emoji = selectedEmoji() else { return false }
                        replaceColonQuery(with: emoji)
                        return true
                    }
                )
                .onChange(of: editText) { _, newValue in
                    updateEmojiQuery(newValue)
                }
                .onChange(of: isTextFieldFocused) { _, focused in
                    if !focused {
                        emojiQuery = nil
                        commitRename()
                    }
                }
                .background(
                    EmojiPanelAnchor(
                        isPresented: emojiQuery != nil,
                        query: emojiQuery ?? "",
                        selectedIndex: $emojiSelectedIndex,
                        onSelect: { emoji in replaceColonQuery(with: emoji) }
                    )
                )
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(worktree.displayName)
                        .fontWeight(hasBoldNotification ? .bold : .regular)
                        .lineLimit(isHovered ? nil : 1)
                        .fixedSize(horizontal: isHovered, vertical: false)
                        .padding(.trailing, isHovered ? 4 : 0)
                        .background(
                            isHovered
                                ? RoundedRectangle(cornerRadius: 3)
                                    .fill(.background)
                                : nil
                        )
                    if isPending {
                        Text("Creating worktree…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .zIndex(isHovered ? 1 : 0)
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

    /// Find the `:` before the cursor with no space between it and the cursor.
    private var activeColonRange: Range<String.Index>? {
        let text = editText
        // Clamp cursor to valid UTF-16 range, convert to String.Index
        let utf16Pos = min(cursorPosition, text.utf16.count)
        let cursorIndex = String.Index(utf16Offset: utf16Pos, in: text)
        // Search backwards from cursor for `:`
        let beforeCursor = text[text.startIndex..<cursorIndex]
        guard let colonIndex = beforeCursor.lastIndex(of: ":") else { return nil }
        // Check no space between colon and cursor
        let between = text[text.index(after: colonIndex)..<cursorIndex]
        if between.contains(" ") || between.contains(":") { return nil }
        return colonIndex..<cursorIndex
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
        let newCursorUTF16 = editText[editText.startIndex..<range.lowerBound].utf16.count + emoji.utf16.count
        editText.replaceSubrange(range, with: emoji)
        cursorPosition = newCursorUTF16
        emojiQuery = nil
        frecency.record(emoji)
    }

    private func selectedEmoji() -> String? {
        guard let query = emojiQuery else { return nil }
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
