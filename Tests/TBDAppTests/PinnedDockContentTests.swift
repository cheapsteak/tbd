import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

@Suite("Pinned dock contents")
struct PinnedDockContentTests {
    // MARK: Fixtures

    private static func wt(_ name: String,
                           id: UUID = UUID(),
                           repoID: UUID? = UUID(),
                           parent: UUID? = nil,
                           pinnedAt: Date? = nil,
                           archivedAt: Date? = nil,
                           displayName: String? = nil,
                           pinSortOrder: Int? = nil) -> Worktree {
        Worktree(id: id, repoID: repoID, name: name,
                 displayName: displayName ?? name,
                 branch: "b", path: "/tmp/\(name)",
                 archivedAt: archivedAt, tmuxServer: "s",
                 parentWorktreeID: parent, pinnedAt: pinnedAt,
                 pinSortOrder: pinSortOrder)
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    /// A `children` closure backed by a plain list, mirroring
    /// `AppState.children(of:)`: repo worktrees only, non-archived.
    private static func childLookup(_ all: [Worktree]) -> (UUID) -> [Worktree] {
        { parentID in
            all.filter { $0.parentWorktreeID == parentID && $0.archivedAt == nil }
        }
    }

    /// `@Sendable` because a plain `static let` closure is not concurrency-safe
    /// and Swift 6 rejects it outright.
    private static let noChildren: @Sendable (UUID) -> [Worktree] = { _ in [] }

    // MARK: deskRow

    @Test("desk resolves only when the flag is on and mode is not off",
          arguments: [
            (NightwatchMode.off, true, false),
            (NightwatchMode.off, false, false),
            (NightwatchMode.daywatch, true, true),
            (NightwatchMode.daywatch, false, false),
            (NightwatchMode.nightwatch, true, true),
            (NightwatchMode.nightwatch, false, false),
          ])
    func deskGate(mode: NightwatchMode, enabled: Bool, expected: Bool) {
        let desk = Self.wt("desk", repoID: nil,
                           displayName: NightwatchDeskPrompts.deskDisplayName)
        let resolved = PinnedDockContent.deskRow(
            allWorktrees: [desk, Self.wt("other")],
            mode: mode, experimentalEnabled: enabled)
        #expect((resolved != nil) == expected)
    }

    @Test("mode on but no desk worktree yet resolves to nil")
    func deskMissing() {
        let resolved = PinnedDockContent.deskRow(
            allWorktrees: [Self.wt("other")],
            mode: .nightwatch, experimentalEnabled: true)
        #expect(resolved == nil)
    }

    // MARK: rows — pins

    @Test("pins sort oldest-first so new pins append")
    func pinOrdering() {
        let a = Self.wt("a", pinnedAt: Self.at(30))
        let b = Self.wt("b", pinnedAt: Self.at(10))
        let c = Self.wt("c", pinnedAt: Self.at(20))
        let rows = PinnedDockContent.rows(allWorktrees: [a, b, c],
                                          selectedIDs: [], children: Self.noChildren)
        #expect(rows.map(\.worktree.name) == ["b", "c", "a"])
    }

    @Test("unpinned worktrees are excluded")
    func unpinnedExcluded() {
        let rows = PinnedDockContent.rows(
            allWorktrees: [Self.wt("a"), Self.wt("b", pinnedAt: Self.at(0))],
            selectedIDs: [], children: Self.noChildren)
        #expect(rows.map(\.worktree.name) == ["b"])
    }

    @Test("an archived worktree keeps its pin but does not render")
    func archivedExcluded() {
        let archived = Self.wt("a", pinnedAt: Self.at(0), archivedAt: Self.at(5))
        let rows = PinnedDockContent.rows(allWorktrees: [archived],
                                          selectedIDs: [], children: Self.noChildren)
        #expect(rows.isEmpty)
        #expect(archived.pinnedAt != nil)   // pin survives for revive
    }

    @Test("the desk never appears in the scrolling area, even if it carries a pin")
    func deskExcludedFromRows() {
        let desk = Self.wt("desk", repoID: nil, pinnedAt: Self.at(0),
                           displayName: NightwatchDeskPrompts.deskDisplayName)
        let rows = PinnedDockContent.rows(allWorktrees: [desk],
                                          selectedIDs: [], children: Self.noChildren)
        #expect(rows.isEmpty)
    }

    // MARK: rows — expansion

    @Test("nothing selected means no expansion")
    func collapsedByDefault() {
        let parentID = UUID()
        let parent = Self.wt("p", id: parentID, pinnedAt: Self.at(0))
        let child = Self.wt("c", parent: parentID)
        let all = [parent, child]
        let rows = PinnedDockContent.rows(allWorktrees: all, selectedIDs: [],
                                          children: Self.childLookup(all))
        #expect(rows.map(\.worktree.name) == ["p"])
    }

    @Test("selecting a pinned parent expands its children at depth 1")
    func expandsOnSelect() {
        let parentID = UUID()
        let parent = Self.wt("p", id: parentID, pinnedAt: Self.at(0))
        let child = Self.wt("c", parent: parentID)
        let all = [parent, child]
        let rows = PinnedDockContent.rows(allWorktrees: all, selectedIDs: [parentID],
                                          children: Self.childLookup(all))
        #expect(rows.map(\.worktree.name) == ["p", "c"])
        #expect(rows.map(\.depth) == [0, 1])
    }

    @Test("selecting a grandchild keeps the whole chain visible")
    func expandsFromDescendant() {
        let pID = UUID(), cID = UUID(), gID = UUID()
        let p = Self.wt("p", id: pID, pinnedAt: Self.at(0))
        let c = Self.wt("c", id: cID, parent: pID)
        let g = Self.wt("g", id: gID, parent: cID)
        let all = [p, c, g]
        let rows = PinnedDockContent.rows(allWorktrees: all, selectedIDs: [gID],
                                          children: Self.childLookup(all))
        #expect(rows.map(\.worktree.name) == ["p", "c", "g"])
        #expect(rows.map(\.depth) == [0, 1, 2])
    }

    @Test("selecting one pin leaves a sibling pin collapsed")
    func siblingStaysCollapsed() {
        let aID = UUID(), bID = UUID()
        let a = Self.wt("a", id: aID, pinnedAt: Self.at(0))
        let aKid = Self.wt("aKid", parent: aID)
        let b = Self.wt("b", id: bID, pinnedAt: Self.at(10))
        let bKid = Self.wt("bKid", parent: bID)
        let all = [a, aKid, b, bKid]
        let rows = PinnedDockContent.rows(allWorktrees: all, selectedIDs: [aID],
                                          children: Self.childLookup(all))
        #expect(rows.map(\.worktree.name) == ["a", "aKid", "b"])
    }

    @Test("sectionRepoID is nil at depth 0 and the ancestor's repo below")
    func sectionRepoIDPropagation() {
        let repo = UUID(), otherRepo = UUID()
        let pID = UUID()
        let p = Self.wt("p", id: pID, repoID: repo, pinnedAt: Self.at(0))
        let c = Self.wt("c", repoID: otherRepo, parent: pID)
        let all = [p, c]
        let rows = PinnedDockContent.rows(allWorktrees: all, selectedIDs: [pID],
                                          children: Self.childLookup(all))
        #expect(rows[0].sectionRepoID == nil)
        #expect(rows[1].sectionRepoID == repo)
    }

    @Test("a worktree that is both pinned and a descendant appears once, at top level")
    func noDuplicates() {
        let pID = UUID(), cID = UUID()
        let p = Self.wt("p", id: pID, pinnedAt: Self.at(0))
        let c = Self.wt("c", id: cID, parent: pID, pinnedAt: Self.at(10))
        let all = [p, c]
        let rows = PinnedDockContent.rows(allWorktrees: all, selectedIDs: [pID],
                                          children: Self.childLookup(all))
        #expect(rows.map(\.worktree.name) == ["p", "c"])
        #expect(rows.map(\.depth) == [0, 0])   // c keeps its own top-level slot
    }

    @Test("a cyclic parent chain terminates and emits each worktree once")
    func cycleTerminates() {
        let aID = UUID(), bID = UUID()
        let a = Self.wt("a", id: aID, parent: bID, pinnedAt: Self.at(0))
        let b = Self.wt("b", id: bID, parent: aID)
        let all = [a, b]
        let rows = PinnedDockContent.rows(allWorktrees: all, selectedIDs: [aID],
                                          children: Self.childLookup(all))
        #expect(rows.map(\.worktree.name) == ["a", "b"])
    }

    @Test("an empty children closure matches the collapsed result")
    func emptyChildrenClosure() {
        let pID = UUID()
        let p = Self.wt("p", id: pID, pinnedAt: Self.at(0))
        let c = Self.wt("c", parent: pID)
        let rows = PinnedDockContent.rows(allWorktrees: [p, c], selectedIDs: [pID],
                                          children: Self.noChildren)
        #expect(rows.map(\.worktree.name) == ["p"])
    }

    // MARK: rows — pinSortOrder

    @Test("pins sort by pinSortOrder ascending when every pin has one")
    func sortsByPinSortOrder() {
        let a = Self.wt("a", pinnedAt: Self.at(0), pinSortOrder: 2)
        let b = Self.wt("b", pinnedAt: Self.at(10), pinSortOrder: 0)
        let c = Self.wt("c", pinnedAt: Self.at(20), pinSortOrder: 1)
        let rows = PinnedDockContent.rows(allWorktrees: [a, b, c],
                                          selectedIDs: [], children: Self.noChildren)
        #expect(rows.map(\.worktree.name) == ["b", "c", "a"])
    }

    @Test("pins without an order sort after pins that have one")
    func unorderedSortsLast() {
        let ordered = Self.wt("ordered", pinnedAt: Self.at(100), pinSortOrder: 5)
        let unordered = Self.wt("unordered", pinnedAt: Self.at(0))
        let rows = PinnedDockContent.rows(allWorktrees: [unordered, ordered],
                                          selectedIDs: [], children: Self.noChildren)
        #expect(rows.map(\.worktree.name) == ["ordered", "unordered"])
    }

    @Test("two unordered pins fall back to pinnedAt — the no-backfill guarantee")
    func fallsBackToPinnedAt() {
        let older = Self.wt("older", pinnedAt: Self.at(0))
        let newer = Self.wt("newer", pinnedAt: Self.at(50))
        let rows = PinnedDockContent.rows(allWorktrees: [newer, older],
                                          selectedIDs: [], children: Self.noChildren)
        #expect(rows.map(\.worktree.name) == ["older", "newer"])
    }

    // MARK: subtree

    @Test("subtree returns just the root when collapsed")
    func subtreeCollapsed() {
        let root = Self.wt("root", pinnedAt: Self.at(0), pinSortOrder: 0)
        let rows = PinnedDockContent.rows(allWorktrees: [root],
                                          selectedIDs: [], children: Self.noChildren)
        #expect(PinnedDockContent.subtree(of: root.id, in: rows).map(\.worktree.name) == ["root"])
    }

    @Test("subtree returns the root plus its descendants, and nothing from a sibling")
    func subtreeExpanded() {
        let aID = UUID(), bID = UUID()
        let a = Self.wt("a", id: aID, pinnedAt: Self.at(0), pinSortOrder: 0)
        let aKid = Self.wt("aKid", parent: aID)
        let b = Self.wt("b", id: bID, pinnedAt: Self.at(10), pinSortOrder: 1)
        let all = [a, aKid, b]
        let rows = PinnedDockContent.rows(allWorktrees: all, selectedIDs: [aID],
                                          children: Self.childLookup(all))
        #expect(PinnedDockContent.subtree(of: aID, in: rows).map(\.worktree.name) == ["a", "aKid"])
        #expect(PinnedDockContent.subtree(of: bID, in: rows).map(\.worktree.name) == ["b"])
    }

    @Test("subtree of an id not in the rows is empty")
    func subtreeMissing() {
        let root = Self.wt("root", pinnedAt: Self.at(0))
        let rows = PinnedDockContent.rows(allWorktrees: [root],
                                          selectedIDs: [], children: Self.noChildren)
        #expect(PinnedDockContent.subtree(of: UUID(), in: rows).isEmpty)
    }
}
