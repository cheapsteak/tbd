import Foundation

/// Tab-like MRU navigation history (shipped semantics of PR #472).
///
/// `entries[0]` is the most recently committed element; `cursor` indexes the
/// currently shown entry. Back/forward/jump only move the cursor and never
/// reorder; `recordReplacement` commits the current entry to the front,
/// dedupes the incoming element (an entry moves rather than duplicates),
/// inserts it at index 0, and caps at `maxEntries` by evicting the tail —
/// never the current entry.
public struct MRUHistory<Element: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public static var maxEntries: Int { 10 }

    public private(set) var entries: [Element] = []
    public private(set) var cursor: Int = -1

    public init() {}

    /// A history whose single entry is the panel's initial content
    /// (`entries[cursor] == content` from birth — Spec C §6).
    public static func seeded(with element: Element) -> MRUHistory {
        var history = MRUHistory()
        history.entries = [element]
        history.cursor = 0
        return history
    }

    /// Back moves toward older entries (higher indices).
    public var canGoBack: Bool { !entries.isEmpty && cursor < entries.count - 1 }
    /// Forward moves toward newer entries (lower indices).
    public var canGoForward: Bool { cursor > 0 }

    /// True when `(entries, cursor)` is internally consistent. In-process
    /// mutations preserve this; only decoded (persisted) data can violate it.
    public var isWellFormed: Bool {
        entries.isEmpty ? cursor == -1 : entries.indices.contains(cursor)
    }

    /// Records a real content navigation (file click, transcript toggle):
    /// moves the current entry to index 0, removes any existing occurrence
    /// of `incoming` (one entry per element), inserts `incoming` at index 0,
    /// and caps at `maxEntries` by evicting the tail — never the current
    /// entry, which was just moved to the front. No-op when nothing changed.
    public mutating func recordReplacement(outgoing: Element, incoming: Element) {
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
    public mutating func goBack() -> Element? {
        guard canGoBack else { return nil }
        cursor += 1
        return entries[cursor]
    }

    /// Moves the cursor one entry toward newer and returns it.
    public mutating func goForward() -> Element? {
        guard canGoForward else { return nil }
        cursor -= 1
        return entries[cursor]
    }

    /// Jumps the cursor to an absolute entry index (from a history menu).
    /// No reorder — selecting a menu entry only moves the cursor.
    public mutating func go(to index: Int) -> Element? {
        guard entries.indices.contains(index), index != cursor else { return nil }
        cursor = index
        return entries[index]
    }
}

/// PR #472's app-side history, now shared. Same name, same wire shape.
public typealias PaneHistory = MRUHistory<PaneContent>
