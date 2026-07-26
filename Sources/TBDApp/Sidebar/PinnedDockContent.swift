import Foundation
import TBDShared

/// One rendered line in the sidebar's pinned dock: a worktree plus the nesting
/// context the row view needs.
struct PinnedDockRow: Identifiable, Equatable {
    let worktree: Worktree
    /// 0 = a pinned row; 1+ = an expanded descendant.
    let depth: Int
    /// The repo of this row's top-level ancestor, driving `WorktreeRowView`'s
    /// muted `(repo-name)` suffix. `nil` at depth 0 — a top-level dock row sits
    /// under no section, so a suffix there would label a section that does not
    /// exist. At depth 1+ the pinned parent *is* the section, so a child from
    /// another repo gets the same suffix it carries in the list.
    let sectionRepoID: UUID?

    var id: UUID { worktree.id }
}

/// Pure content model for the sidebar's pinned dock. Takes values and one
/// lookup closure, returns values — no SwiftUI, no `AppState`, fully testable.
///
/// The scrolling pinned area and the fixed Watch Desk slot are separate
/// functions because they render into separate containers with different scroll
/// behaviour: the desk must never scroll out from above the Day/Night toggle.
enum PinnedDockContent {
    /// The Watch Desk worktree when it should occupy its fixed slot, else nil.
    ///
    /// Returns nil when mode is off, when the experimental opt-in is unset
    /// (fail-closed, same gate as every other nightwatch surface), or when mode
    /// is on but the daemon has not created the desk worktree yet. That last
    /// case is ordinary, not an error — it gets no placeholder row.
    static func deskRow(allWorktrees: [Worktree],
                        mode: NightwatchMode,
                        experimentalEnabled: Bool) -> Worktree? {
        guard experimentalEnabled, mode != .off else { return nil }
        return allWorktrees.first { $0.isNightwatchDesk }
    }

    /// The scrolling pinned area, top to bottom. Never contains the desk.
    ///
    /// - Parameters:
    ///   - selectedIDs: drives expansion — a top-level row expands when it or
    ///     any descendant is selected. Scoping this to the row alone would make
    ///     a child vanish the moment you clicked it in the dock.
    ///   - children: injected rather than derived so the dock and the sidebar
    ///     list agree on what a child is. Callers pass `appState.children(of:)`,
    ///     which already filters to `.active`/`.creating` and sorts by
    ///     `sortOrder`; duplicating that predicate here would let the two drift.
    static func rows(allWorktrees: [Worktree],
                     selectedIDs: Set<UUID>,
                     children: (UUID) -> [Worktree]) -> [PinnedDockRow] {
        let pinned = allWorktrees
            .filter { $0.pinnedAt != nil && $0.archivedAt == nil && !$0.isNightwatchDesk }
            .sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }

        // Emit-once, which both prevents a worktree from appearing twice and
        // makes a cyclic parentWorktreeID chain terminate — so unlike
        // WorktreeSubtreeView this needs no depth cap.
        //
        // Pre-seeded with EVERY pinned id before the loop, not filled in as
        // roots are visited: a pinned worktree that is also a descendant of an
        // earlier pin owns a top-level slot, and seeding is what stops the
        // earlier pin's expansion from swallowing it into a depth-1 row.
        var emitted = Set(pinned.map(\.id))
        var result: [PinnedDockRow] = []

        for root in pinned {
            result.append(PinnedDockRow(worktree: root, depth: 0, sectionRepoID: nil))
            guard subtreeIsSelected(root.id, selectedIDs: selectedIDs,
                                    children: children, visited: []) else { continue }
            appendDescendants(of: root.id, sectionRepoID: root.repoID, depth: 1,
                              children: children, emitted: &emitted, into: &result)
        }
        return result
    }

    /// Is `id` or any of its descendants selected? `visited` guards a cyclic
    /// chain, which would otherwise recurse forever.
    private static func subtreeIsSelected(_ id: UUID,
                                          selectedIDs: Set<UUID>,
                                          children: (UUID) -> [Worktree],
                                          visited: Set<UUID>) -> Bool {
        if selectedIDs.contains(id) { return true }
        guard !visited.contains(id) else { return false }
        var seen = visited
        seen.insert(id)
        return children(id).contains {
            subtreeIsSelected($0.id, selectedIDs: selectedIDs, children: children, visited: seen)
        }
    }

    private static func appendDescendants(of parentID: UUID,
                                          sectionRepoID: UUID?,
                                          depth: Int,
                                          children: (UUID) -> [Worktree],
                                          emitted: inout Set<UUID>,
                                          into result: inout [PinnedDockRow]) {
        for child in children(parentID) where !emitted.contains(child.id) {
            emitted.insert(child.id)
            result.append(PinnedDockRow(worktree: child, depth: depth,
                                        sectionRepoID: sectionRepoID))
            appendDescendants(of: child.id, sectionRepoID: sectionRepoID,
                              depth: depth + 1, children: children,
                              emitted: &emitted, into: &result)
        }
    }
}
