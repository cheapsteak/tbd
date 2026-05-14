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
    private let now: Date

    static let rowCap = 20

    init(
        worktrees: [JumpMenuWorktreeSnapshot],
        unread: [UUID: UnreadSummary],
        recentIDs: [UUID],
        now: Date = Date()
    ) {
        self.allWorktrees = worktrees
        self.unread = unread
        self.recentIDs = recentIDs
        self.now = now
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
                    timestamp: summary.mostRecentAt,
                    section: .unread
                )
            }

        // Recents minus anything already in unread, minus deletions. The LRU
        // doesn't carry a timestamp — we approximate the "time since last
        // visit" by index-based deltas from `now`, one minute per position,
        // so the first recent gets "now" and older ones get progressively
        // dimmer relative labels. The spec says time-ago is hidden while
        // typing anyway; for default-state display this is an honest "most
        // recent" indicator without needing wall-clock visit timestamps.
        let unreadIDs = Set(unread.keys)
        let recentRows: [JumpMenuRow] = recentIDs
            .filter { !unreadIDs.contains($0) }
            .compactMap { id -> (UUID, JumpMenuWorktreeSnapshot)? in
                guard let snap = snapshotByID[id] else { return nil }   // filters deletions
                return (id, snap)
            }
            .enumerated()
            .map { (offset, pair) in
                JumpMenuRow(
                    id: pair.0,
                    displayName: pair.1.displayName,
                    repoName: pair.1.repoName,
                    severity: nil,
                    timestamp: now.addingTimeInterval(-Double(offset) * 60),
                    section: .recent
                )
            }

        let combined = unreadRows + recentRows
        return Array(combined.prefix(Self.rowCap))
    }

    // MARK: - Typed query

    private func matchRows(query: String) -> [JumpMenuRow] {
        let needle = query.lowercased()
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
                    timestamp: unread[snap.id]?.mostRecentAt,
                    section: .match
                )
            }
            .prefix(Self.rowCap)
            .map { $0 }
    }
}
