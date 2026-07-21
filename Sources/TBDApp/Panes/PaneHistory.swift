import Foundation

/// Tab-like MRU navigation history for one viewer-class "slot" pane.
///
/// `entries[0]` is the most recently committed content; `cursor` indexes the
/// entry currently shown — the slot's current content IS `entries[cursor]`.
/// Back/forward/jump only move the cursor and never reorder the list; a real
/// navigation (`recordReplacement`) commits the current entry to the front,
/// dedupes the incoming content (an entry moves rather than duplicates), and
/// inserts it at index 0. Every entry carries the slot's own `paneID`, so
/// applying an entry via `LayoutNode.replacingContent(at:with:)` preserves
/// view identity.
struct PaneHistory: Codable, Equatable, Sendable {
    static let maxEntries = 10

    private(set) var entries: [PaneContent] = []
    private(set) var cursor: Int = -1

    /// Back moves toward older entries (higher indices).
    var canGoBack: Bool { !entries.isEmpty && cursor < entries.count - 1 }
    /// Forward moves toward newer entries (lower indices).
    var canGoForward: Bool { cursor > 0 }

    /// True when `(entries, cursor)` is internally consistent. In-process
    /// mutations preserve this; only decoded (persisted) data can violate it.
    var isWellFormed: Bool {
        entries.isEmpty ? cursor == -1 : entries.indices.contains(cursor)
    }

    /// Records a real content navigation (file click, transcript toggle):
    /// moves the current entry to index 0, removes any existing occurrence
    /// of `incoming` (one entry per content), inserts `incoming` at index 0,
    /// and caps at `maxEntries` by evicting the tail — never the current
    /// entry, which was just moved to the front. No-op when nothing changed.
    mutating func recordReplacement(outgoing: PaneContent, incoming: PaneContent) {
        guard outgoing != incoming else { return }
        if entries.isEmpty {
            entries = [outgoing]
        } else {
            // The slot's live content is authoritative for the current entry.
            entries[cursor] = outgoing
            entries.insert(entries.remove(at: cursor), at: 0)
        }
        entries.removeAll { $0 == incoming }
        entries.insert(incoming, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        cursor = 0
    }

    /// Moves the cursor one entry toward older and returns it. Navigation
    /// only moves the cursor — it never reorders or re-pushes.
    mutating func goBack() -> PaneContent? {
        guard canGoBack else { return nil }
        cursor += 1
        return entries[cursor]
    }

    /// Moves the cursor one entry toward newer and returns it.
    mutating func goForward() -> PaneContent? {
        guard canGoForward else { return nil }
        cursor -= 1
        return entries[cursor]
    }

    /// Jumps the cursor to an absolute entry index (from a history menu).
    /// No reorder — selecting a menu entry only moves the cursor.
    mutating func go(to index: Int) -> PaneContent? {
        guard entries.indices.contains(index), index != cursor else { return nil }
        cursor = index
        return entries[index]
    }
}
