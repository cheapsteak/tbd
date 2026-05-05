// Sources/TBDApp/Sidebar/RenameableLabel.swift
import SwiftUI

/// Inline-editable label with `:emoji:` autocomplete support.
/// When `isEditing` is true, displays a TextField with emoji autocomplete;
/// otherwise displays static text via `displayContent`.
///
/// The caller is responsible for:
///   - flipping `isEditing` to true to enter edit mode
///   - providing the static display via `displayContent`
///   - persisting on `onCommit`
struct RenameableLabel<DisplayContent: View>: View {
    let text: String
    @Binding var isEditing: Bool
    let onCommit: (String) -> Void
    var onCancel: () -> Void = {}
    var onStartEditing: () -> Void = {}
    var onStopEditing: () -> Void = {}
    @ViewBuilder let displayContent: () -> DisplayContent

    @State private var editText = ""
    @State private var cursorPosition = 0
    @State private var isTextFieldFocused = false
    @State private var emojiQuery: String?
    @State private var emojiSelectedIndex = 0
    @State private var frecency = EmojiFrecency.load()

    var body: some View {
        if isEditing {
            InlineTextField(
                text: $editText,
                cursorPosition: $cursorPosition,
                isFocused: $isTextFieldFocused,
                onSubmit: {
                    if emojiQuery != nil, let emoji = selectedEmoji() {
                        replaceColonQuery(with: emoji)
                    } else {
                        commit()
                    }
                },
                onCancel: {
                    if emojiQuery != nil {
                        emojiQuery = nil
                    } else {
                        cancel()
                    }
                },
                onKeyDown: { keyCode in
                    guard emojiQuery != nil else { return false }
                    switch keyCode {
                    case 125: emojiSelectedIndex += 7; return true   // down
                    case 126: emojiSelectedIndex = max(0, emojiSelectedIndex - 7); return true // up
                    case 124: emojiSelectedIndex += 1; return true   // right
                    case 123: emojiSelectedIndex = max(0, emojiSelectedIndex - 1); return true // left
                    default: return false
                    }
                },
                onSpecialKey: { _ in
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
                    commit()
                }
            }
            .onAppear {
                editText = text
                onStartEditing()
                isTextFieldFocused = true
                // Re-assert focus after a delay to win any focus race with terminal views
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTextFieldFocused = true
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
            displayContent()
        }
    }

    private func commit() {
        let trimmed = editText.trimmingCharacters(in: .whitespaces)
        isEditing = false
        onStopEditing()
        guard !trimmed.isEmpty, trimmed != text else { return }
        onCommit(trimmed)
    }

    private func cancel() {
        isEditing = false
        onStopEditing()
        onCancel()
    }

    // MARK: - Emoji autocomplete

    private var activeColonRange: Range<String.Index>? {
        let utf16Pos = min(cursorPosition, editText.utf16.count)
        let cursorIndex = String.Index(utf16Offset: utf16Pos, in: editText)
        let beforeCursor = editText[editText.startIndex..<cursorIndex]
        guard let colonIndex = beforeCursor.lastIndex(of: ":") else { return nil }
        let between = editText[editText.index(after: colonIndex)..<cursorIndex]
        if between.contains(" ") || between.contains(":") { return nil }
        return colonIndex..<cursorIndex
    }

    private func updateEmojiQuery(_ text: String) {
        if let range = activeColonRange {
            emojiQuery = String(editText[editText.index(after: range.lowerBound)..<range.upperBound])
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
}
