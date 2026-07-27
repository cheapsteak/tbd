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

    private static func remote(_ sessionID: String,
                               provider: String = "prov",
                               pinnedAt: Date? = nil,
                               dismissed: Bool = false,
                               gone: Bool = false,
                               state: RemoteProcessState = .running) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(id: sessionID, state: state, agentState: .working),
            gone: gone, dismissed: dismissed, lastSeen: at(0), pinnedAt: pinnedAt)
    }

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

    // MARK: remoteRows

    @Test("an unpinned remote session never reaches the dock")
    func remoteUnpinnedExcluded() {
        let rows = PinnedDockContent.remoteRows(
            allRemoteSessions: [Self.remote("a"), Self.remote("b", pinnedAt: Self.at(0))])
        #expect(rows.map(\.session.payload.id) == ["b"])
    }

    @Test("pinned remote sessions sort oldest-pin-first so a new pin appends")
    func remotePinOrdering() {
        let rows = PinnedDockContent.remoteRows(allRemoteSessions: [
            Self.remote("a", pinnedAt: Self.at(30)),
            Self.remote("b", pinnedAt: Self.at(10)),
            Self.remote("c", pinnedAt: Self.at(20)),
        ])
        #expect(rows.map(\.session.payload.id) == ["b", "c", "a"])
    }

    /// Two pins landing on the same timestamp must not swap places between
    /// renders — the sort has to be total, not merely stable-by-luck.
    @Test("identical pin timestamps break the tie on (provider, sessionID)")
    func remotePinTiesAreTotallyOrdered() {
        let same = Self.at(5)
        let sessions = [
            Self.remote("z", provider: "alpha", pinnedAt: same),
            Self.remote("a", provider: "beta", pinnedAt: same),
            Self.remote("b", provider: "alpha", pinnedAt: same),
        ]
        let forward = PinnedDockContent.remoteRows(allRemoteSessions: sessions)
        let reversed = PinnedDockContent.remoteRows(allRemoteSessions: sessions.reversed())
        #expect(forward.map(\.id) == reversed.map(\.id))
        #expect(forward.map(\.session.payload.id) == ["b", "z", "a"])
    }

    /// Dismiss means "get rid of it", so the row leaves the dock even if the
    /// stored pin somehow survived (an older daemon that didn't clear the
    /// column on dismiss).
    @Test("a dismissed remote session leaves the dock even while pinned")
    func remoteDismissedExcluded() {
        let rows = PinnedDockContent.remoteRows(allRemoteSessions: [
            Self.remote("a", pinnedAt: Self.at(0), dismissed: true),
            Self.remote("b", pinnedAt: Self.at(10)),
        ])
        #expect(rows.map(\.session.payload.id) == ["b"])
    }

    /// The counterpart choice: a session the provider stopped reporting keeps
    /// its slot (it self-heals when the provider lists it again) and renders
    /// with `RemoteSessionRowView`'s existing dimmed styling.
    @Test("a gone remote session keeps its pin and its dock slot")
    func remoteGoneStaysPinned() {
        let rows = PinnedDockContent.remoteRows(
            allRemoteSessions: [Self.remote("a", pinnedAt: Self.at(0), gone: true)])
        #expect(rows.map(\.session.payload.id) == ["a"])
        #expect(rows[0].session.gone)
    }

    @Test("an exited remote session keeps its pin and its dock slot")
    func remoteExitedStaysPinned() {
        let rows = PinnedDockContent.remoteRows(
            allRemoteSessions: [Self.remote("a", pinnedAt: Self.at(0), state: .exited)])
        #expect(rows.map(\.session.payload.id) == ["a"])
        #expect(rows[0].session.payload.state == .exited)
    }

    /// Two providers can mint the same session id; the dock rows must still
    /// be distinct, because `List`/`ForEach` identity is the row `id`.
    @Test("same session id on two providers yields two distinct dock rows")
    func remoteRowsAreKeyedByProviderAndSession() {
        let rows = PinnedDockContent.remoteRows(allRemoteSessions: [
            Self.remote("dup", provider: "alpha", pinnedAt: Self.at(0)),
            Self.remote("dup", provider: "beta", pinnedAt: Self.at(10)),
        ])
        #expect(rows.count == 2)
        #expect(rows[0].id != rows[1].id)
        #expect(rows[0].id == RemoteSessionIdentity.uuid(provider: "alpha", sessionID: "dup"))
    }

    @Test("no pinned remote sessions means no remote dock rows")
    func remoteRowsEmpty() {
        #expect(PinnedDockContent.remoteRows(allRemoteSessions: []).isEmpty)
        #expect(PinnedDockContent.remoteRows(allRemoteSessions: [Self.remote("a")]).isEmpty)
    }

    /// Pinning a remote session must not disturb the worktree half of the
    /// dock — the two groups are computed independently.
    @Test("remote pins do not appear in, or reorder, the worktree rows")
    func remoteAndWorktreePinsAreIndependent() {
        let wtRows = PinnedDockContent.rows(
            allWorktrees: [Self.wt("a", pinnedAt: Self.at(0)), Self.wt("b", pinnedAt: Self.at(10))],
            selectedIDs: [], children: Self.noChildren)
        #expect(wtRows.map(\.worktree.name) == ["a", "b"])
        let remoteRows = PinnedDockContent.remoteRows(
            allRemoteSessions: [Self.remote("r", pinnedAt: Self.at(5))])
        #expect(remoteRows.map(\.session.payload.id) == ["r"])
        #expect(wtRows.count == 2)   // the remote pin added no worktree row
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
