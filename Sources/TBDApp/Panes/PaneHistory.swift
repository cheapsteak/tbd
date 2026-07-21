import Foundation

/// Back/forward navigation history for one viewer-class "slot" pane.
///
/// `entries` is the full trail (oldest first) INCLUDING the slot's current
/// content; `cursor` indexes the current content. Every entry carries the
/// slot's own `paneID`, so applying an entry via
/// `LayoutNode.replacingContent(at:with:)` preserves view identity.
struct PaneHistory: Codable, Equatable, Sendable {
    static let maxEntries = 10

    private(set) var entries: [PaneContent] = []
    private(set) var cursor: Int = -1

    var canGoBack: Bool { cursor > 0 }
    var canGoForward: Bool { !entries.isEmpty && cursor < entries.count - 1 }

    /// Entries behind the cursor, nearest first, paired with their absolute
    /// index for `go(to:)`.
    var backEntries: [(index: Int, content: PaneContent)] {
        guard canGoBack else { return [] }
        return (0..<cursor).reversed().map { ($0, entries[$0]) }
    }

    /// Entries ahead of the cursor, nearest first.
    var forwardEntries: [(index: Int, content: PaneContent)] {
        guard canGoForward else { return [] }
        return ((cursor + 1)..<entries.count).map { ($0, entries[$0]) }
    }

    /// Records a content-navigation replacement: drops any forward entries,
    /// appends the incoming content, and caps the trail at `maxEntries`
    /// (dropping oldest). No-op when nothing actually changed.
    mutating func recordReplacement(outgoing: PaneContent, incoming: PaneContent) {
        guard outgoing != incoming else { return }
        if entries.isEmpty {
            entries = [outgoing]
            cursor = 0
        } else {
            entries.removeSubrange((cursor + 1)...)
            // The slot's live content is authoritative for the current entry.
            entries[cursor] = outgoing
        }
        entries.append(incoming)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        cursor = entries.count - 1
    }

    /// Moves the cursor back one entry and returns it. Navigation only moves
    /// the cursor — it never re-pushes.
    mutating func goBack() -> PaneContent? {
        guard canGoBack else { return nil }
        cursor -= 1
        return entries[cursor]
    }

    /// Moves the cursor forward one entry and returns it.
    mutating func goForward() -> PaneContent? {
        guard canGoForward else { return nil }
        cursor += 1
        return entries[cursor]
    }

    /// Jumps the cursor to an absolute entry index (from a history menu).
    mutating func go(to index: Int) -> PaneContent? {
        guard entries.indices.contains(index), index != cursor else { return nil }
        cursor = index
        return entries[index]
    }
}
