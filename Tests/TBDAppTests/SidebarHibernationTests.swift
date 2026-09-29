import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("Sidebar hibernation partition")
struct SidebarHibernationTests {
    private static let parkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func worktree(
        _ name: String = "acme-task",
        repoID: UUID? = UUID(),
        parent: UUID? = nil,
        status: WorktreeStatus = .active,
        location: WorktreeLocation = .local
    ) -> Worktree {
        Worktree(repoID: repoID, name: name, displayName: name,
                 branch: "task", path: "/tmp/\(name)", status: status,
                 tmuxServer: "acme", parentWorktreeID: parent, location: location)
    }

    private func terminal(_ worktree: Worktree, parked: Bool = true, legacy: Bool = false) -> Terminal {
        Terminal(worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
                 suspendedAt: legacy ? Self.parkedAt : nil, kind: .claude,
                 hibernatedAt: parked && !legacy ? Self.parkedAt : nil)
    }

    private func partition(
        _ roots: [Worktree],
        terminals: [UUID: [Terminal]],
        descendants: [Worktree] = []
    ) -> SidebarHibernationPartition {
        let index = Dictionary(grouping: descendants, by: { $0.parentWorktreeID })
        return SidebarHibernation.partition(roots: roots, terminals: terminals) { index[$0] ?? [] }
    }

    @Test("only wholly parked roots move, preserving each partition's input order")
    func stablePartition() {
        let awake = worktree("awake")
        let parked = worktree("parked")
        let mixed = worktree("mixed")
        let legacy = worktree("legacy")
        let result = partition([awake, parked, mixed, legacy], terminals: [
            awake.id: [terminal(awake, parked: false)],
            parked.id: [terminal(parked)],
            mixed.id: [terminal(mixed), terminal(mixed, parked: false)],
            legacy.id: [terminal(legacy, legacy: true)],
        ])
        #expect(result.workingRoots.map(\.id) == [awake.id, mixed.id])
        #expect(result.hibernatedRoots.map(\.id) == [parked.id, legacy.id])
        #expect(result.hibernatedWorktreeIDs == [parked.id, legacy.id])
        #expect(result.hibernatedCount == 2)
    }

    @Test("missing, empty, and wrong-owner inventories keep rows in the working list")
    func uncertainInventoriesStayVisible() {
        let unknown = worktree("unknown")
        let empty = worktree("empty")
        let wrongOwner = worktree("wrong-owner")
        let result = partition([unknown, empty, wrongOwner], terminals: [
            empty.id: [], wrongOwner.id: [terminal(unknown)],
        ])
        #expect(result.workingRoots.map(\.id) == [unknown.id, empty.id, wrongOwner.id])
        #expect(result.hibernatedRoots.isEmpty)
        #expect(result.hibernatedCount == 0)
    }

    @Test("main, creating, archived, failed and remote rows never qualify")
    func nonordinaryRowsStayVisible() {
        let rows = [
            worktree("main", status: .main),
            worktree("creating", status: .creating),
            worktree("archived", status: .archived),
            worktree("failed", status: .failed),
            worktree("remote", location: .remote(provider: "acme", sessionID: "worker")),
        ]
        let result = partition(rows, terminals: Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, [terminal($0)])
        }))
        #expect(result.workingRoots.map(\.id) == rows.map(\.id))
        #expect(result.hibernatedRoots.isEmpty)
    }

    @Test("scratch rows qualify but the special supervision desk stays in place")
    func scratchAndDesk() {
        let scratch = worktree("scratch", repoID: nil)
        let desk = worktree(NightwatchDeskPrompts.deskDisplayName, repoID: nil)
        let result = partition([scratch, desk], terminals: [
            scratch.id: [terminal(scratch)], desk.id: [terminal(desk)],
        ])
        #expect(result.workingRoots.map(\.id) == [desk.id])
        #expect(result.hibernatedRoots.map(\.id) == [scratch.id])
    }

    @Test("whole parked subtrees move with cross-repository ownership and descendant counts")
    func parkedSubtreeKeepsOwnership() {
        let root = worktree("parent")
        let child = worktree("child", parent: root.id)
        let grandchild = worktree("grandchild", parent: child.id)
        let rows = [root, child, grandchild]
        let result = partition([root], terminals: Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, [terminal($0)])
        }), descendants: [child, grandchild])
        #expect(result.workingRoots.isEmpty)
        #expect(result.hibernatedRoots == [root])
        #expect(result.hibernatedCount == 3)
        #expect(result.hibernatedWorktreeIDs == Set(rows.map(\.id)))
        #expect(child.repoID != root.repoID)
        #expect(result.hibernatedWorktreeIDs.contains(grandchild.id),
                "navigation must reveal the shelf when a nested row is selected")
    }

    @Test("uncertain or continuing descendants keep their parked parent visible",
          arguments: ["awake", "unknown", "empty", "remote", "creating"])
    func descendantPreventsShelving(_ condition: String) {
        let root = worktree("parent")
        let child = worktree(
            "child", parent: root.id,
            status: condition == "creating" ? .creating : .active,
            location: condition == "remote" ? .remote(provider: "acme", sessionID: "worker") : .local)
        var inventories = [root.id: [terminal(root)]]
        if condition != "unknown" {
            inventories[child.id] = condition == "empty" ? [] : [terminal(child, parked: condition != "awake")]
        }
        let result = partition([root], terminals: inventories, descendants: [child])
        #expect(result.workingRoots == [root])
        #expect(result.hibernatedCount == 0)
    }

    @Test("a parked child cannot be extracted directly from its parent")
    func nestedInputStaysVisible() {
        let child = worktree("child", parent: UUID())
        let result = partition([child], terminals: [child.id: [terminal(child)]])
        #expect(result.workingRoots == [child])
        #expect(result.hibernatedRoots.isEmpty)
    }

    @Test("inconsistent parent or archive data is not enough evidence to shelve")
    func inconsistentInventoryStaysVisible() {
        let root = worktree("parent")
        let child = worktree("child", parent: UUID())
        let badEdge = SidebarHibernation.partition(
            roots: [root], terminals: [root.id: [terminal(root)], child.id: [terminal(child)]]
        ) { $0 == root.id ? [child] : [] }
        #expect(badEdge.workingRoots == [root])
        #expect(badEdge.hibernatedCount == 0)

        var archived = root
        archived.archivedAt = Self.parkedAt
        let badStatus = partition([archived], terminals: [root.id: [terminal(root)]])
        #expect(badStatus.workingRoots == [archived])
        #expect(badStatus.hibernatedCount == 0)
    }

    @Test("pins retain their independent dock shortcut when a root is shelved")
    func pinnedRootKeepsDockShortcut() {
        var root = worktree("pinned")
        root.pinnedAt = Self.parkedAt
        let result = partition([root], terminals: [root.id: [terminal(root)]])
        let dock = PinnedDockContent.rows(allWorktrees: [root], selectedIDs: []) { _ in [] }
        #expect(result.hibernatedRoots == [root])
        #expect(dock.map(\.id) == [root.id])
    }

    @Test("a cyclic lookup keeps the root visible and terminates")
    func cycleStaysVisible() {
        let root = worktree("parent")
        let child = worktree("child", parent: root.id)
        var cycleRoot = root
        cycleRoot.parentWorktreeID = child.id
        let result = SidebarHibernation.partition(
            roots: [root], terminals: [root.id: [terminal(root)], child.id: [terminal(child)]]
        ) { $0 == root.id ? [child] : [cycleRoot] }
        #expect(result.workingRoots == [root])
        #expect(result.hibernatedRoots.isEmpty)
    }

    @Test("the render depth limit is inclusive and deeper inventories stay visible",
          arguments: [50, 51])
    func depthBound(_ depth: Int) {
        let root = worktree("root")
        var chain = [root]
        for index in 1...depth {
            chain.append(worktree("child-\(index)", parent: chain.last!.id))
        }
        let result = partition([root], terminals: Dictionary(uniqueKeysWithValues: chain.map {
            ($0.id, [terminal($0)])
        }), descendants: Array(chain.dropFirst()))
        if depth == 50 {
            #expect(result.hibernatedCount == 51)
            #expect(result.workingRoots.isEmpty)
        } else {
            #expect(result.hibernatedCount == 0)
            #expect(result.workingRoots == [root])
        }
    }

    @Test("waking one terminal returns the whole subtree to the working list")
    func wakeReclassifiesSubtree() {
        let root = worktree("parent")
        let child = worktree("child", parent: root.id)
        var inventories = [root.id: [terminal(root)], child.id: [terminal(child)]]
        #expect(partition([root], terminals: inventories, descendants: [child]).hibernatedCount == 2)
        inventories[child.id] = [terminal(child, parked: false)]
        let result = partition([root], terminals: inventories, descendants: [child])
        #expect(result.workingRoots == [root])
        #expect(result.hibernatedCount == 0)
    }
}
