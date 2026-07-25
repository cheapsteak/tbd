import SwiftUI
import TBDShared

// MARK: - Label / search-text helpers
//
// Single source of truth for how a pane-history entry reads, reused by
// `PaneHistoryPaletteView` below. This is exactly the labeling the old
// right-click history dropdown used (PR #472) before the palette replaced it.

/// Display label for a pane-history entry.
func paneHistoryLabel(for content: PaneContent) -> String {
    switch content {
    case .codeViewer(_, let path):
        return URL(fileURLWithPath: path).lastPathComponent
    case .webview(_, let url):
        return (url.host ?? "") + url.path
    case .liveTranscript:
        return "Transcript"
    case .terminal:
        return "Terminal"
    case .note:
        return "Note"
    }
}

/// Text the palette's search field matches against. Same as the display
/// label, except file entries match on their full path — not just the
/// basename — so a query like `foo/bar` finds a file at that path.
func paneHistorySearchText(for content: PaneContent) -> String {
    if case .codeViewer(_, let path) = content {
        return path
    }
    return paneHistoryLabel(for: content)
}

/// Parent directory shown dimmed under a file entry's basename; nil for
/// every other pane type (and for a bare filename with no directory).
func paneHistoryParentDirectory(for content: PaneContent) -> String? {
    guard case .codeViewer(_, let path) = content else { return nil }
    let dir = (path as NSString).deletingLastPathComponent
    return dir.isEmpty ? nil : dir
}

/// Pure substring filter behind the palette's search field: case-insensitive,
/// no fuzzy matching. Empty query matches everything, preserving MRU order.
enum PaneHistoryPaletteFilter {
    static func filteredIndices(entries: [PaneContent], query: String) -> [Int] {
        guard !query.isEmpty else { return Array(entries.indices) }
        let needle = query.lowercased()
        return entries.indices.filter {
            paneHistorySearchText(for: entries[$0]).lowercased().contains(needle)
        }
    }
}

/// Pure gate behind the search icon: disabled when there's one entry or
/// fewer — nothing else to jump to. Extracted from the view so it's
/// unit-testable without SwiftUI (same pattern as `ParkedPaneWakeModel`).
enum PaneHistoryPaletteButtonModel {
    static func isEnabled(entryCount: Int) -> Bool {
        entryCount > 1
    }
}

// MARK: - PaneHistoryPaletteView

/// Searchable palette over a pane's MRU history (PR #472/#478's
/// `PaneHistory` / `MRUHistory<PaneContent>`). Replaces the old right-click
/// dropdown on the history chevrons, which was undiscoverable. Read-only over
/// the passed-in `history`; selecting an entry calls back with its index so
/// the caller can drive the SAME `go(to:)` cursor-jump the old menu used —
/// this view never mutates history itself.
struct PaneHistoryPaletteView: View {
    let history: PaneHistory
    let onSelect: (Int) -> Void

    @State private var query = ""
    @State private var highlightedPosition = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var filteredIndices: [Int] {
        PaneHistoryPaletteFilter.filteredIndices(entries: history.entries, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search history", text: $query)
                .textFieldStyle(.plain)
                .padding(8)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { move(by: 1); return .handled }
                .onKeyPress(.upArrow) { move(by: -1); return .handled }
                .onKeyPress(.return) { selectHighlighted(); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredIndices.isEmpty {
                        Text("No matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ForEach(Array(filteredIndices.enumerated()), id: \.element) { position, entryIndex in
                            row(entryIndex: entryIndex, isHighlighted: position == highlightedPosition)
                                .onTapGesture { select(entryIndex) }
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .frame(width: 280)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in highlightedPosition = 0 }
    }

    @ViewBuilder
    private func row(entryIndex: Int, isHighlighted: Bool) -> some View {
        let content = history.entries[entryIndex]
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.caption2)
                .opacity(entryIndex == history.cursor ? 1 : 0)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 0) {
                Text(paneHistoryLabel(for: content))
                    .font(.caption)
                    .lineLimit(1)
                if let parentDir = paneHistoryParentDirectory(for: content) {
                    Text(parentDir)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }

    private func move(by delta: Int) {
        guard !filteredIndices.isEmpty else { return }
        let count = filteredIndices.count
        highlightedPosition = ((highlightedPosition + delta) % count + count) % count
    }

    private func selectHighlighted() {
        guard filteredIndices.indices.contains(highlightedPosition) else { return }
        select(filteredIndices[highlightedPosition])
    }

    private func select(_ entryIndex: Int) {
        onSelect(entryIndex)
        dismiss()
    }
}
