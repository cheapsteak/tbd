import Foundation
import Testing
@testable import TBDShared

@Suite("SidebarOrder")
struct SidebarOrderTests {
    private static let repoID = UUID()

    private static func row(
        _ name: String, status: WorktreeStatus = .active, parent: UUID? = nil,
        sortOrder: Int = 0, minute: Int = 0, id: UUID = UUID()
    ) -> Worktree {
        Worktree(
            id: id, repoID: repoID, name: name, displayName: name, branch: name,
            path: "/tmp/acme/\(name)", status: status,
            createdAt: Date(timeIntervalSince1970: TimeInterval(minute * 60)),
            tmuxServer: "acme-server", sortOrder: sortOrder, parentWorktreeID: parent)
    }

    private static func names(_ walked: [(worktree: Worktree, depth: Int)]) -> [String] {
        walked.map { $0.worktree.name }
    }

    /// main; a (sortOrder 0) with child a.1 with child a.1.x; b (sortOrder 1).
    private static func fixture() -> [Worktree] {
        let main = Self.row("main", status: .main)
        let a = Self.row("a", sortOrder: 0)
        let a1 = Self.row("a.1", parent: a.id)
        let a1x = Self.row("a.1.x", parent: a1.id)
        let b = Self.row("b", sortOrder: 1)
        return [b, a1x, a1, a, main]
    }

    @Test func theMainRowComesFirstThenSiblingsThenChildren() {
        let rows = Self.fixture()
        let walked = SidebarOrder.walk(
            repoWorktrees: rows, children: SidebarOrder.childrenIndex(rows), order: .parentsFirst)
        #expect(Self.names(walked) == ["main", "a", "a.1", "a.1.x", "b"])
        #expect(walked.map(\.depth) == [0, 0, 1, 2, 0])
    }

    @Test func childrenFirstPutsChildrenBeforeTheirParent() {
        let rows = Self.fixture()
        let walked = SidebarOrder.walk(
            repoWorktrees: rows, children: SidebarOrder.childrenIndex(rows), order: .childrenFirst)
        #expect(Self.names(walked) == ["main", "a.1.x", "a.1", "a", "b"])
    }

    @Test func tiesOnSortOrderFallBackToCreatedAtThenID() {
        let parent = Self.row("p")
        let older = Self.row("older", parent: parent.id, sortOrder: 1, minute: 0, id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)
        let smallID = Self.row("small", parent: parent.id, sortOrder: 1, minute: 5, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let largeID = Self.row("large", parent: parent.id, sortOrder: 1, minute: 5, id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let first = Self.row("first", parent: parent.id, sortOrder: 0, minute: 9)
        let index = SidebarOrder.childrenIndex([largeID, smallID, older, first])
        #expect(index[parent.id]?.map(\.name) == ["first", "older", "small", "large"])
    }

    @Test func aCycleStopsAtTheDepthCap() {
        let aID = UUID()
        let bID = UUID()
        let top = Self.row("top")
        // a and b name each other as parent, and a also hangs under top.
        let a = Self.row("a", parent: bID, id: aID)
        let b = Self.row("b", parent: aID, id: bID)
        var children = SidebarOrder.childrenIndex([a, b])
        children[top.id] = [a]
        let walked = SidebarOrder.walk(
            repoWorktrees: [top], children: children, order: .parentsFirst)
        #expect(walked.count <= SidebarOrder.maxDepth + 1)
        #expect(walked.map(\.depth).max() == SidebarOrder.maxDepth)
    }

    @Test func archivedRowsAreNotWalked() {
        let live = Self.row("live")
        let archived = Self.row("archived", status: .archived)
        let child = Self.row("child", parent: live.id)
        let archivedChild = Self.row("archived-child", status: .archived, parent: live.id)
        let creating = Self.row("creating", status: .creating, parent: live.id, sortOrder: 5)
        let rows = [live, archived, child, archivedChild, creating]
        let walked = SidebarOrder.walk(
            repoWorktrees: rows, children: SidebarOrder.childrenIndex(rows), order: .parentsFirst)
        #expect(Self.names(walked) == ["live", "child", "creating"])
    }
}
