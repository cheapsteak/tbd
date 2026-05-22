import Combine
import Foundation
import TBDShared

/// A minimal snapshot of one worktree's data, captured at menu-open time so
/// the menu's display is immune to mid-triage list mutation. Decoupling from
/// `Worktree` itself also keeps the view model trivially mockable from tests.
struct JumpMenuWorktreeSnapshot: Equatable {
    let id: UUID
    let displayName: String
    let repoName: String
}

/// Pure view model — no SwiftUI, no AppState. The controller assembles a
/// snapshot once when opening the panel and hands it to the view model;
/// the view model handles query mutation, filtering, sorting, capping.
@MainActor
final class JumpMenuViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var selectedIndex: Int = 0

    private let allWorktrees: [JumpMenuWorktreeSnapshot]
    private let unread: [UUID: UnreadSummary]
    private let recentIDs: [UUID]

    static let rowCap = 20

    init(
        worktrees: [JumpMenuWorktreeSnapshot],
        unread: [UUID: UnreadSummary],
        recentIDs: [UUID]
    ) {
        self.allWorktrees = worktrees
        self.unread = unread
        self.recentIDs = recentIDs
    }

    /// Currently-displayed rows, recomputed when `query` changes.
    var rows: [JumpMenuRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? defaultRows() : matchRows(query: trimmed)
    }

    /// Reset selection to the top whenever the query changes. The view binds
    /// `query` directly to `@Published var query`, so call this from the
    /// view's `.onChange(of: viewModel.query)` hook.
    func resetSelection() {
        selectedIndex = 0
    }

    func moveSelectionDown() {
        let count = rows.count
        guard count > 0 else { return }
        selectedIndex = min(selectedIndex + 1, count - 1)
    }

    func moveSelectionUp() {
        guard rows.count > 0 else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    /// The row the user would jump to right now. `nil` when there are no
    /// rows (the view should treat enter-on-nil as a no-op + close).
    var selectedRow: JumpMenuRow? {
        let r = rows
        guard !r.isEmpty, selectedIndex >= 0, selectedIndex < r.count else { return nil }
        return r[selectedIndex]
    }

    // MARK: - Default (empty query)

    private func defaultRows() -> [JumpMenuRow] {
        let snapshotByID = Dictionary(uniqueKeysWithValues: allWorktrees.map { ($0.id, $0) })

        // Unreads, sorted by mostRecentAt desc, with UUID lexicographic tiebreak.
        let unreadRows: [JumpMenuRow] = unread
            .compactMap { (id, summary) -> (UUID, UnreadSummary, JumpMenuWorktreeSnapshot)? in
                guard let snap = snapshotByID[id] else { return nil }   // filters deletions
                return (id, summary, snap)
            }
            .sorted { lhs, rhs in
                if lhs.1.mostRecentAt != rhs.1.mostRecentAt {
                    return lhs.1.mostRecentAt > rhs.1.mostRecentAt
                }
                return lhs.0.uuidString < rhs.0.uuidString
            }
            .map { (id, summary, snap) in
                JumpMenuRow(
                    id: id,
                    displayName: snap.displayName,
                    repoName: snap.repoName,
                    severity: summary.type,
                    section: .unread
                )
            }

        // Recents minus anything already in unread, minus deletions. LRU
        // position is preserved by iterating `recentIDs` in order; no
        // timestamp is needed since rows no longer display time-ago.
        let unreadIDs = Set(unread.keys)
        let recentRows: [JumpMenuRow] = recentIDs
            .filter { !unreadIDs.contains($0) }
            .compactMap { id -> (UUID, JumpMenuWorktreeSnapshot)? in
                guard let snap = snapshotByID[id] else { return nil }   // filters deletions
                return (id, snap)
            }
            .map { pair in
                JumpMenuRow(
                    id: pair.0,
                    displayName: pair.1.displayName,
                    repoName: pair.1.repoName,
                    severity: nil,
                    section: .recent
                )
            }

        let combined = unreadRows + recentRows
        return Array(combined.prefix(Self.rowCap))
    }

    // MARK: - Typed query

    private func matchRows(query: String) -> [JumpMenuRow] {
        let needle = query.lowercased()
        // Recency rank: position in the LRU list (0 = most recent). Worktrees
        // absent from the list (never visited this session, or past the
        // 32-item cap) rank `Int.max` and sink to the bottom of their tier.
        let recencyRank: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: recentIDs.enumerated().map { ($0.element, $0.offset) }
        )
        return allWorktrees
            .filter { snap in
                snap.displayName.lowercased().contains(needle)
                    || snap.repoName.lowercased().contains(needle)
            }
            .map { snap in
                JumpMenuRow(
                    id: snap.id,
                    displayName: snap.displayName,
                    repoName: snap.repoName,
                    severity: unread[snap.id]?.type,
                    section: .match
                )
            }
            // Order: unread rows first (severity desc), then recency
            // (most-recently-used first) across both tiers, then an
            // emoji-stripped alphabetical fallback, then a UUID tiebreak
            // for determinism (dict iteration order is otherwise arbitrary).
            .sorted { lhs, rhs in
                let lhsHas = lhs.severity != nil
                let rhsHas = rhs.severity != nil
                if lhsHas != rhsHas { return lhsHas && !rhsHas }
                let lhsSev = lhs.severity?.severity ?? -1
                let rhsSev = rhs.severity?.severity ?? -1
                if lhsSev != rhsSev { return lhsSev > rhsSev }
                let lhsRank = recencyRank[lhs.id] ?? Int.max
                let rhsRank = recencyRank[rhs.id] ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                let lhsKey = Self.alphabeticalSortKey(lhs.displayName)
                let rhsKey = Self.alphabeticalSortKey(rhs.displayName)
                if lhsKey != rhsKey { return lhsKey < rhsKey }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(Self.rowCap)
            .map { $0 }
    }

    /// Sort key for the alphabetical fallback. Display names are formatted
    /// `<emoji> <Title Case>`, so leading non-alphanumeric characters (the
    /// emoji and the space after it) are dropped to order by words rather
    /// than emoji codepoints. A `Character` is a grapheme cluster, so a
    /// multi-scalar emoji (flags, ZWJ sequences) is dropped as one unit. A
    /// name that is entirely emoji yields an empty key; the UUID tiebreak
    /// keeps such rows deterministically ordered.
    private static func alphabeticalSortKey(_ displayName: String) -> String {
        displayName
            .drop { !$0.isLetter && !$0.isNumber }
            .lowercased()
    }
}
