import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: deterministic, in-process state only. The clock is fixed and the
// scratch-directory probe is injected, so no build touches the filesystem.

/// `SidebarTreeBuilder` against `AppState` fixtures: it must produce the
/// sections, rows, order and depths the SwiftUI sidebar renders for the same
/// state, and every input a row draws must reach its model.
/// Spec: docs/specs/2026-10-31-native-sidebar-design.md, "Testing".
/// One case per `WorktreeRowModel` input, for
/// `SidebarTreeBuilderTests.eachRowInputChangesTheTree`. At file scope so the
/// test's arguments are not main-actor isolated.
enum SidebarRowInput: CaseIterable, Sendable {
    case leading, name, bold, subtitles, suffix, noStatusMark, devServerDot
    case crossRepoLabel, homeRepo, pinned, depth, dimmed, hiddenSection, isMain, heightClass
}

@MainActor
@Suite("Sidebar tree builder")
struct SidebarTreeBuilderTests {
    // MARK: Sections

    @Test func sectionsInListOrder() {
        let suite = TestDefaultsSuite("SidebarTreeBuilderTests.order")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let one = Repo(path: "/tmp/acme-one", displayName: "one")
        let two = Repo(path: "/tmp/acme-two", displayName: "two")
        // `filteredRepos` keeps `repos` order, whatever it is.
        state.repos = [two, one]
        state.worktrees = [
            one.id: [Self.row("main", repo: one.id, status: .main)],
            two.id: [Self.row("main", repo: two.id, status: .main)],
        ]
        state.remoteProviders = [SidebarGroupFixtures.provider()]

        #expect(Self.build(state).roots.map(\.id)
                == [.scratchHeader, .repoHeader(two.id), .repoHeader(one.id), .providerHeader("acme")])
        #expect(Self.build(state, Self.options(scratch: false)).roots.map(\.id)
                == [.repoHeader(two.id), .repoHeader(one.id), .providerHeader("acme")])

        state.remoteProviders = []
        #expect(Self.build(state).roots.map(\.id) == [.scratchHeader, .repoHeader(two.id), .repoHeader(one.id)],
                "No registered provider hides the Remote section")
    }

    @Test func hiddenReposOmittedUnlessShown() throws {
        let suite = TestDefaultsSuite("SidebarTreeBuilderTests.hidden")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let shown = Repo(path: "/tmp/acme-shown", displayName: "shown")
        let hidden = Repo(path: "/tmp/acme-hidden", displayName: "hidden", hidden: true)
        let shownRow = Self.row("work", repo: shown.id)
        let hiddenRow = Self.row("work", repo: hidden.id)
        state.repos = [shown, hidden]
        state.worktrees = [shown.id: [shownRow], hidden.id: [hiddenRow]]

        let filtered = Self.build(state, Self.options(hidden: false))
        #expect(Self.repoHeaders(filtered) == [shown.id])
        #expect(!filtered.contains(.worktree(hiddenRow.id)))

        let all = Self.build(state, Self.options(hidden: true))
        #expect(Self.repoHeaders(all) == [shown.id, hidden.id])
        guard case .repoHeader(let header)? = all.node(.repoHeader(hidden.id))?.kind else {
            Issue.record("The hidden repo's header is missing")
            return
        }
        #expect(header.isHidden)
        #expect(try #require(Self.worktreeModel(all, hiddenRow.id)).isInHiddenSection)
        #expect(try #require(Self.worktreeModel(all, shownRow.id)).isInHiddenSection == false)
    }

    @Test func repoFilterLimitsToOneRepo() {
        let suite = TestDefaultsSuite("SidebarTreeBuilderTests.filter")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let one = Repo(path: "/tmp/acme-one", displayName: "one")
        let two = Repo(path: "/tmp/acme-two", displayName: "two")
        state.repos = [one, two]
        state.worktrees = [one.id: [Self.row("work", repo: one.id)], two.id: [Self.row("work", repo: two.id)]]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        let session = SidebarGroupFixtures.session("lane", repoID: one.id)
        state.remoteSessions = [session]

        let unfiltered = Self.build(state)
        #expect(Self.repoHeaders(unfiltered) == [one.id, two.id])
        #expect(unfiltered.parent(of: .remoteSession(session.id)) == .repoHeader(one.id))

        state.repoFilter = two.id
        let filtered = Self.build(state)
        #expect(Self.repoHeaders(filtered) == [two.id])
        // As in `RemoteSectionView.knownRepoIDs`: while filtered, another
        // repo's sessions fall through to their provider rather than vanish.
        #expect(filtered.parent(of: .remoteSession(session.id)) == .providerHeader("acme"))
    }

    // MARK: Rows and depths

    @Test func mainRowFirstAndChildless() throws {
        let suite = TestDefaultsSuite("SidebarTreeBuilderTests.main")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let feature = Self.row("feature", repo: repo.id, order: 0)
        let main = Self.row("main", repo: repo.id, status: .main)
        // The daemon refuses `main` as a parent, but a row that names it
        // anyway renders nowhere in the `List`: not under the main row, which
        // has no subtree, and not at the top level, since it has a parent.
        let underMain = Self.row("under-main", repo: repo.id, parent: main.id)
        state.repos = [repo]
        state.worktrees = [repo.id: [feature, main, underMain]]

        let tree = Self.build(state)
        let section = try #require(tree.node(.repoHeader(repo.id)))
        #expect(section.children.map(\.id) == [.worktree(main.id), .worktree(feature.id)])
        let mainNode = try #require(tree.node(.worktree(main.id)))
        #expect(mainNode.children.isEmpty)
        #expect(try #require(Self.worktreeModel(tree, main.id)).isMain)
        #expect(try #require(Self.worktreeModel(tree, feature.id)).isMain == false)
        #expect(!tree.contains(.worktree(underMain.id)))

        state.repos[0].expanded = false
        let collapsed = Self.build(state)
        #expect(collapsed.node(.repoHeader(repo.id))?.children.isEmpty == true,
                "A collapsed section has no rows, as the List mounts none")
        #expect(collapsed.node(.repoHeader(repo.id))?.isExpanded == false)
    }

    @Test(arguments: [false, true])
    func nestedSubtreesFollowParentPointers(groups: Bool) throws {
        let suite = TestDefaultsSuite("SidebarTreeBuilderTests.nested")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let other = Repo(path: "/tmp/acme-widgets", displayName: "widgets")
        let parent = Self.row("parent", repo: repo.id)
        let second = Self.row("second", repo: repo.id, parent: parent.id, order: 1)
        let first = Self.row("first", repo: repo.id, parent: parent.id, order: 0)
        let grandchild = Self.row("grandchild", repo: repo.id, parent: first.id)
        // A child from another repo nests under its parent, in its parent's
        // section, with a shortened "(repo)" suffix.
        let crossRepo = Self.row("cross", repo: other.id, parent: parent.id, order: 2)
        state.repos = [repo, other]
        state.worktrees = [repo.id: [parent, second, first, grandchild], other.id: [crossRepo]]

        let tree = Self.build(state, Self.options(groups: groups))
        let parentNode = try #require(tree.node(.worktree(parent.id)))
        #expect(parentNode.children.map(\.id)
                == [.worktree(first.id), .worktree(second.id), .worktree(crossRepo.id)])
        #expect(tree.node(.worktree(first.id))?.children.map(\.id) == [.worktree(grandchild.id)])
        #expect(tree.parent(of: .worktree(crossRepo.id)) == .worktree(parent.id))
        #expect(tree.node(.repoHeader(other.id))?.children.isEmpty == true,
                "A nested row never renders a second time at its own repo's top level")

        #expect(try #require(Self.worktreeModel(tree, parent.id)).depth == 0)
        #expect(try #require(Self.worktreeModel(tree, first.id)).depth == 1)
        #expect(try #require(Self.worktreeModel(tree, grandchild.id)).depth == 2)
        let cross = try #require(Self.worktreeModel(tree, crossRepo.id))
        #expect(cross.depth == 1)
        #expect(cross.crossRepoLabel == "(widge…)")
        #expect(cross.homeRepoID == other.id)
        #expect(try #require(Self.worktreeModel(tree, first.id)).crossRepoLabel == nil)
        #expect(try #require(Self.worktreeModel(tree, first.id)).homeRepoID == repo.id)
        #expect(tree.node(.worktree(parent.id))?.isExpanded == true, "Worktree subtrees are always expanded")
    }

    @Test func groupsMatchSectionLayoutWhenGroupsOn() throws {
        let suite = TestDefaultsSuite("SidebarTreeBuilderTests.groups")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let fleet = Self.makeFleet(in: state)
        let repoID = fleet.repoID
        let layout = state.sidebarRepositoryLayout(
            repoID: repoID, grouped: true, collapseEnded: false,
            matchedSessions: state.sidebarMatchedRemoteSessions(repoID: repoID))
        let groups = try #require(layout.remoteGroups, "The fleet must file rows under Remote, or this test is vacuous")
        let remoteID = SidebarGroupID(owner: .repository(repoID), kind: .remote)
        let exitedID = SidebarGroupID(owner: .repository(repoID), kind: .exited)
        let hibernatedID = SidebarGroupID(owner: .repository(repoID), kind: .hibernated)
        let parentRemoteID = SidebarGroupID(owner: .parent(fleet.working.id), kind: .remote)

        // Collapsed: the headers render and nothing under them does.
        let collapsed = Self.build(state, Self.options(groups: true))
        let inlineIDs: [SidebarNodeID] = layout.inlineRoots.map { .worktree($0.id) }
        let expectedTop: [SidebarNodeID] = [.worktree(fleet.main.id)] + inlineIDs
            + [.group(remoteID), .group(hibernatedID)]
        #expect(collapsed.node(.repoHeader(repoID))?.children.map(\.id) == expectedTop)
        #expect(expectedTop == [.worktree(fleet.main.id), .worktree(fleet.working.id),
                                .group(remoteID), .group(hibernatedID)])
        #expect(collapsed.node(.group(remoteID))?.children.isEmpty == true)
        #expect(collapsed.node(.group(remoteID))?.isExpanded == false)
        #expect(collapsed.node(.worktree(fleet.working.id))?.children.map(\.id)
                == [.worktree(fleet.localChild.id), .group(parentRemoteID)])

        state.expandedSidebarGroups = [remoteID, exitedID, hibernatedID, parentRemoteID]
        let open = Self.build(state, Self.options(groups: true))
        let remoteRows: [SidebarNodeID] = groups.remoteRoots.map { .worktree($0.id) }
        let remoteSessions: [SidebarNodeID] = groups.sessions.map { .remoteSession($0.id) }
        let expectedRemote: [SidebarNodeID] = remoteRows + remoteSessions + [.group(exitedID)]
        let exitedRows: [SidebarNodeID] = groups.exitedRoots.map { .worktree($0.id) }
        let exitedSessions: [SidebarNodeID] = groups.exitedSessions.map { .remoteSession($0.id) }
        let expectedExited: [SidebarNodeID] = exitedRows + exitedSessions
        let hibernatedRoots = try #require(layout.hibernation?.hibernatedRoots)
        let expectedHibernated: [SidebarNodeID] = hibernatedRoots.map { .worktree($0.id) }
        #expect(open.node(.group(remoteID))?.children.map(\.id) == expectedRemote)
        #expect(open.node(.group(exitedID))?.children.map(\.id) == expectedExited)
        #expect(open.node(.group(hibernatedID))?.children.map(\.id) == expectedHibernated)
        #expect(open.node(.group(parentRemoteID))?.children.map(\.id) == [.worktree(fleet.worker.id)])
        #expect(expectedRemote.contains(.worktree(fleet.running.id)))
        #expect(expectedExited.contains(.worktree(fleet.ended.id)))

        // Depths follow the SwiftUI padding: each disclosure deepens its rows.
        #expect(Self.groupModel(open, remoteID)?.depth == 0)
        #expect(Self.groupModel(open, exitedID)?.depth == 1)
        #expect(Self.groupModel(open, hibernatedID)?.count == layout.hibernation?.hibernatedCount)
        #expect(Self.groupModel(open, remoteID)?.summary == groups.summary.text)
        #expect(try #require(Self.worktreeModel(open, fleet.running.id)).depth == 1)
        #expect(try #require(Self.worktreeModel(open, fleet.ended.id)).depth == 2)
        #expect(try #require(Self.worktreeModel(open, fleet.parked.id)).depth == 1)
        #expect(Self.groupModel(open, parentRemoteID)?.depth == 1)
        #expect(try #require(Self.worktreeModel(open, fleet.worker.id)).depth == 2)
        #expect(try #require(Self.worktreeModel(open, fleet.localChild.id)).depth == 1)

        // Off, the same fleet renders inline with no headers at all.
        let ungrouped = Self.build(state, Self.options(groups: false))
        let section = try #require(ungrouped.node(.repoHeader(repoID)))
        #expect(!section.children.contains { Self.isGroup($0.id) })
        #expect(ungrouped.parent(of: .worktree(fleet.running.id)) == .repoHeader(repoID))
        #expect(ungrouped.parent(of: .worktree(fleet.worker.id)) == .worktree(fleet.working.id))
    }

    @Test func endedGroupWhenCollapseEndedOn() throws {
        let suite = TestDefaultsSuite("SidebarTreeBuilderTests.ended")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let main = Self.row("main", repo: repo.id, status: .main)
        state.repos = [repo]
        state.worktrees = [repo.id: [main]]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        let live = SidebarGroupFixtures.session("live", repoID: repo.id)
        let done = SidebarGroupFixtures.session("done", state: .exited, repoID: repo.id)
        let vanished = SidebarGroupFixtures.session("vanished", gone: true, repoID: repo.id)
        state.remoteSessions = [live, done, vanished]
        let endedID = SidebarGroupID(owner: .repository(repo.id), kind: .ended)
        let layout = state.sidebarRepositoryLayout(
            repoID: repo.id, grouped: false, collapseEnded: true,
            matchedSessions: state.sidebarMatchedRemoteSessions(repoID: repo.id))
        let ended = try #require(layout.ended)

        let collapsed = Self.build(state, Self.options(collapseEnded: true))
        #expect(collapsed.node(.repoHeader(repo.id))?.children.map(\.id)
                == [.worktree(main.id), .remoteSession(live.id), .group(endedID)])
        #expect(collapsed.node(.group(endedID))?.children.isEmpty == true,
                "Collapsed, no ended session has a row, which is the option's point")
        let model = try #require(Self.groupModel(collapsed, endedID))
        #expect(model.kind == .ended)
        #expect(model.summary == ended.summary.text)
        #expect(model.isExpanded == false)

        state.expandedSidebarGroups.insert(endedID)
        let open = Self.build(state, Self.options(collapseEnded: true))
        let expectedEnded: [SidebarNodeID] = ended.ended.map { .remoteSession($0.id) }
        #expect(open.node(.group(endedID))?.children.map(\.id) == expectedEnded)
        #expect(Set(ended.ended.map(\.id)) == [done.id, vanished.id])

        let inline = Self.build(state, Self.options(collapseEnded: false))
        #expect(!inline.contains(.group(endedID)))
        #expect(inline.parent(of: .remoteSession(done.id)) == .repoHeader(repo.id))
    }

    @Test func scratchPromptWhenNoScratchSpaces() throws {
        let suite = TestDefaultsSuite("SidebarTreeBuilderTests.scratch")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)

        let empty = Self.build(state)
        #expect(empty.node(.scratchHeader)?.children.map(\.id) == [.scratchPrompt])

        let pad = Worktree(repoID: nil, name: "pad", displayName: "Pad", branch: "",
                           path: "/tmp/acme-pad", tmuxServer: "acme")
        state.scratchWorktrees = [pad]
        let one = Self.build(state)
        #expect(one.node(.scratchHeader)?.children.map(\.id) == [.worktree(pad.id)])
        let model = try #require(Self.worktreeModel(one, pad.id))
        #expect(model.depth == 0)
        #expect(model.crossRepoLabel == nil)
        #expect(model.homeRepoID == nil, "A scratch row belongs to no repo")

        let collapsed = Self.build(state, Self.options(scratchExpanded: false))
        #expect(collapsed.node(.scratchHeader)?.children.isEmpty == true)
        #expect(collapsed.node(.scratchHeader)?.isExpanded == false)
        guard case .scratchHeader(let header)? = collapsed.node(.scratchHeader)?.kind else {
            Issue.record("The Scratch header is missing")
            return
        }
        #expect(header.isExpanded == false)
        #expect(header.title == AppState.scratchSectionLabel)

        #expect(!Self.build(state, Self.options(scratch: false)).contains(.scratchHeader))
    }

    /// Review Focus 3: a corrupt parent chain stops at depth 50 and never
    /// loops, as `WorktreeSubtreeView` stops.
    @Test(arguments: [false, true])
    func depthCappedAtFiftyOnParentCycle(groups: Bool) throws {
        let suite = TestDefaultsSuite("SidebarTreeBuilderTests.cycle")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        state.repos = [repo]

        // A cycle reachable from a root: the root's ID reappears, under
        // another repo's key, as the child of its own child.
        let root = Self.row("root", repo: repo.id)
        let child = Self.row("child", repo: repo.id, parent: root.id)
        let ghostRepo = UUID()
        let ghost = Worktree(id: root.id, repoID: ghostRepo, name: "ghost", displayName: "ghost",
                             branch: "feature", path: "/tmp/acme", tmuxServer: "acme",
                             parentWorktreeID: child.id)
        state.worktrees = [repo.id: [root, child], ghostRepo: [ghost]]

        let cyclic = Self.build(state, Self.options(groups: groups))
        let visible = cyclic.visibleIDs
        #expect(Set(visible).count == visible.count, "Every row appears once")
        #expect(cyclic.node(.worktree(root.id))?.children.map(\.id) == [.worktree(child.id)])
        #expect(cyclic.node(.worktree(child.id))?.children.isEmpty == true)

        // A runaway chain sixty deep: rows down to ancestry depth 50 render,
        // and the row at 50 renders without its children.
        var chain: [Worktree] = [Self.row("w0", repo: repo.id)]
        for level in 1..<60 {
            chain.append(Self.row("w\(level)", repo: repo.id, parent: chain[level - 1].id))
        }
        state.worktrees = [repo.id: chain]
        let deep = Self.build(state, Self.options(groups: groups))
        let atCap = try #require(deep.node(.worktree(chain[50].id)))
        #expect(atCap.children.isEmpty)
        #expect(try #require(Self.worktreeModel(deep, chain[50].id)).depth == 50)
        #expect(!deep.contains(.worktree(chain[51].id)))
        #expect(chain[0...50].allSatisfy { deep.contains(.worktree($0.id)) })
    }

    // MARK: Row inputs

    /// One case per `WorktreeRowModel` input: a write to `AppState` (or, for
    /// dimming, to the scratch row's path) changes that field, and so the
    /// tree. Parity checklist item 8: every input a row draws refreshes it.
    @Test(arguments: SidebarRowInput.allCases)
    func eachRowInputChangesTheTree(input: SidebarRowInput) throws {
        let suite = TestDefaultsSuite("SidebarTreeBuilderTests.inputs")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let fixture = Self.makeRowFixture(in: state)
        let rowID = Self.subject(of: input, in: fixture)
        let options = Self.options(hidden: true)

        let before = Self.build(state, options)
        let modelBefore = try #require(Self.worktreeModel(before, rowID))
        Self.mutate(input, fixture: fixture, state: state)
        let after = Self.build(state, options)
        let modelAfter = try #require(Self.worktreeModel(after, rowID))

        #expect(Self.differs(input, modelBefore, modelAfter),
                "The \(input) input did not reach its row: \(modelBefore) → \(modelAfter)")
        #expect(before != after)
    }

    /// A creating placeholder — a row in `pendingWorktreeIDs`, which the
    /// daemon has not heard of — is marked, so the drop policy keeps off it.
    /// A daemon row that is itself `.creating`, its hook still running, is
    /// not: the daemon knows it.
    @Test func placeholderMarkFollowsPendingWorktreeIDs() throws {
        let suite = TestDefaultsSuite("SidebarTreeBuilderTests.placeholder")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let pending = Self.row("pending", repo: repo.id, order: 0, status: .creating)
        let creating = Self.row("creating", repo: repo.id, order: 1, status: .creating)
        state.repos = [repo]
        state.worktrees = [repo.id: [pending, creating]]
        state.pendingWorktreeIDs = [pending.id]

        let tree = Self.build(state)
        #expect(try #require(Self.worktreeModel(tree, pending.id)).isPlaceholder)
        #expect(try #require(Self.worktreeModel(tree, creating.id)).isPlaceholder == false)

        // Once the daemon has the row, the mark goes.
        state.pendingWorktreeIDs = []
        let settled = Self.build(state)
        #expect(try #require(Self.worktreeModel(settled, pending.id)).isPlaceholder == false)
    }

    // MARK: Purity

    /// The controller builds inside `withObservationTracking`; a tracked write
    /// during a build would schedule the next rebuild from inside this one.
    @Test func builderNeverMutatesAppState() {
        let suite = TestDefaultsSuite("SidebarTreeBuilderTests.purity")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let fleet = Self.makeFleet(in: state)
        state.expandedSidebarGroups = [
            SidebarGroupID(owner: .repository(fleet.repoID), kind: .remote),
            SidebarGroupID(owner: .repository(fleet.repoID), kind: .exited),
            SidebarGroupID(owner: .repository(fleet.repoID), kind: .hibernated),
            SidebarGroupID(owner: .parent(fleet.working.id), kind: .remote),
            SidebarGroupID(owner: .provider("acme"), kind: .remote),
        ]

        let tracker = AppStateEmissionTracker(state)
        defer { tracker.stop() }
        // Cold and warm caches, grouped and not, collapse-ended on and off.
        for groups in [true, false] {
            for collapseEnded in [false, true] {
                _ = Self.build(state, Self.options(groups: groups, collapseEnded: collapseEnded))
                _ = Self.build(state, Self.options(groups: groups, collapseEnded: collapseEnded))
            }
        }
        #expect(tracker.count == 0, "A build wrote to a tracked AppState property")

        // Positive control: the tracker hears a real write.
        state.selectedScratchSection.toggle()
        #expect(tracker.count > 0, "The tracker missed a write; the zero above would be vacuous")
    }

    // MARK: Fixtures

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func options(hidden: Bool = false, scratch: Bool = true, groups: Bool = false,
                        collapseEnded: Bool = false, scratchExpanded: Bool = true) -> SidebarBuildOptions {
        SidebarBuildOptions(showHiddenRepos: hidden, showScratchSection: scratch, workflowGroups: groups,
                            collapseEnded: collapseEnded, scratchExpanded: scratchExpanded)
    }

    /// Builds at a fixed time with a directory probe that reports any path
    /// ending in `-missing` as gone, so no build stats the disk.
    static func build(
        _ state: AppState, _ options: SidebarBuildOptions = SidebarTreeBuilderTests.options()
    ) -> SidebarTree {
        SidebarTreeBuilder.build(state, options: options, now: now,
                                 directoryExists: { !$0.hasSuffix("-missing") })
    }

    static func row(_ name: String, repo: UUID, remote: String? = nil, parent: UUID? = nil,
                    order: Int = 0, status: WorktreeStatus = .active) -> Worktree {
        SidebarGroupFixtures.row(name, repoID: repo, remote: remote, parent: parent, order: order, status: status)
    }

    static func repoHeaders(_ tree: SidebarTree) -> [UUID] {
        tree.roots.compactMap { node -> UUID? in
            if case .repoHeader(let id) = node.id { return id }
            return nil
        }
    }

    static func isGroup(_ id: SidebarNodeID) -> Bool {
        if case .group = id { return true }
        return false
    }

    static func worktreeModel(_ tree: SidebarTree, _ id: UUID) -> WorktreeRowModel? {
        guard case .worktree(let model)? = tree.node(.worktree(id))?.kind else { return nil }
        return model
    }

    static func groupModel(_ tree: SidebarTree, _ id: SidebarGroupID) -> GroupHeaderModel? {
        guard case .groupHeader(let model)? = tree.node(.group(id))?.kind else { return nil }
        return model
    }

    /// A repository holding one row of every kind the groups move — working
    /// local, running remote, exited remote, wholly parked local — plus a
    /// local and a remote child under the working row, a main row, and an
    /// unadopted running and an unadopted exited session.
    struct Fleet {
        let repoID: UUID
        let main: Worktree, working: Worktree, running: Worktree, ended: Worktree, parked: Worktree
        let localChild: Worktree, worker: Worktree
    }

    static func makeFleet(in state: AppState) -> Fleet {
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        state.repos = [repo]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        let main = row("main", repo: repo.id, status: .main)
        let working = row("working", repo: repo.id, order: 0)
        let running = row("running", repo: repo.id, remote: "lane-running", order: 1)
        let parked = row("parked", repo: repo.id, order: 2)
        let ended = row("ended", repo: repo.id, remote: "lane-ended", order: 3)
        let localChild = row("local child", repo: repo.id, parent: working.id, order: 0)
        let worker = row("worker", repo: repo.id, remote: "lane-worker", parent: working.id, order: 1)
        state.worktrees = [repo.id: [main, working, running, parked, ended, localChild, worker]]
        state.terminals[parked.id] = [TBDShared.Terminal(
            worktreeID: parked.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude,
            hibernatedAt: Date(timeIntervalSince1970: 1_800_000_000))]
        state.remoteSessions = [
            SidebarGroupFixtures.session("lane-running", repoID: repo.id),
            SidebarGroupFixtures.session("lane-ended", state: .exited, repoID: repo.id),
            SidebarGroupFixtures.session("lane-worker", repoID: repo.id),
            SidebarGroupFixtures.session("loose-running", repoID: repo.id),
            SidebarGroupFixtures.session("loose-ended", state: .exited, repoID: repo.id),
            SidebarGroupFixtures.session("unmatched"),
        ]
        return Fleet(repoID: repo.id, main: main, working: working, running: running, ended: ended,
                     parked: parked, localChild: localChild, worker: worker)
    }

    struct RowFixture {
        let repo: UUID
        let otherRepo: UUID
        let main: Worktree
        let subject: Worktree
        let parent: Worktree
        let child: Worktree
        let scratch: Worktree
        let quietTerminalID: UUID
    }

    static func makeRowFixture(in state: AppState) -> RowFixture {
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let other = Repo(path: "/tmp/acme-widgets", displayName: "widgets")
        let main = row("main", repo: repo.id, status: .main)
        let subject = row("subject", repo: repo.id, order: 0)
        let parent = row("parent", repo: repo.id, order: 1)
        let child = row("child", repo: repo.id, parent: parent.id)
        let scratch = Worktree(repoID: nil, name: "pad", displayName: "Pad", branch: "",
                               path: "/tmp/acme-pad", tmuxServer: "acme")
        // An agent session that has not reported: the no-status mark shows
        // once the app records a sighting past the grace period.
        let quiet = TBDShared.Terminal(worktreeID: subject.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)
        state.repos = [repo, other]
        state.worktrees = [repo.id: [main, subject, parent, child]]
        state.scratchWorktrees = [scratch]
        state.terminals[subject.id] = [quiet]
        return RowFixture(repo: repo.id, otherRepo: other.id, main: main, subject: subject, parent: parent,
                          child: child, scratch: scratch, quietTerminalID: quiet.id)
    }

    static func subject(of input: SidebarRowInput, in fixture: RowFixture) -> UUID {
        switch input {
        case .crossRepoLabel, .homeRepo: fixture.child.id
        case .dimmed: fixture.scratch.id
        case .isMain: fixture.main.id
        default: fixture.subject.id
        }
    }

    static func mutate(_ input: SidebarRowInput, fixture: RowFixture, state: AppState) {
        let subject = fixture.subject.id
        switch input {
        case .leading:
            state.prStatuses[subject] = PRStatus(
                number: 7, url: "https://example.invalid/acme/pull/7", state: .mergeable)
        case .name:
            update(state, fixture.repo, subject) { $0.displayName = "renamed" }
        case .bold:
            state.unreadByWorktree[subject] = UnreadSummary(
                type: .responseComplete, mostRecentAt: Date(timeIntervalSince1970: 0))
        case .subtitles:
            update(state, fixture.repo, subject) { $0.promotedToRepoID = fixture.otherRepo }
        case .suffix:
            state.terminals[subject] = [TBDShared.Terminal(
                worktreeID: subject, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .claude, activityState: .working)]
        case .noStatusMark:
            state.noStatusSightings[fixture.quietTerminalID] = NoStatusSighting(incarnationID: nil, graceElapsed: true)
        case .devServerDot:
            state.devServerRunningWorktreeIDs = [subject]
        case .crossRepoLabel, .homeRepo:
            update(state, fixture.repo, fixture.child.id) { $0.repoID = fixture.otherRepo }
        case .pinned:
            update(state, fixture.repo, subject) { $0.pinnedAt = Date(timeIntervalSince1970: 0) }
        case .depth:
            update(state, fixture.repo, subject) { $0.parentWorktreeID = fixture.parent.id }
        case .dimmed:
            state.scratchWorktrees[0].localPath = "/tmp/acme-pad-missing"
        case .hiddenSection:
            state.repos[0].hidden = true
        case .isMain:
            update(state, fixture.repo, fixture.main.id) { $0.status = .active }
        case .heightClass:
            update(state, fixture.repo, subject) { $0.status = .creating }
        }
    }

    static func differs(_ input: SidebarRowInput, _ a: WorktreeRowModel, _ b: WorktreeRowModel) -> Bool {
        switch input {
        case .leading: a.leading != b.leading
        case .name: a.name != b.name
        case .bold: a.isNameBold != b.isNameBold
        case .subtitles: a.subtitles != b.subtitles
        case .suffix: a.suffix != b.suffix
        case .noStatusMark: a.showsNoStatusMark != b.showsNoStatusMark
        case .devServerDot: a.showsDevServerDot != b.showsDevServerDot
        case .crossRepoLabel: a.crossRepoLabel != b.crossRepoLabel
        case .homeRepo: a.homeRepoID != b.homeRepoID
        case .pinned: a.isPinned != b.isPinned
        case .depth: a.depth != b.depth
        case .dimmed: a.isDimmed != b.isDimmed
        case .hiddenSection: a.isInHiddenSection != b.isInHiddenSection
        case .isMain: a.isMain != b.isMain
        case .heightClass: a.heightClass != b.heightClass
        }
    }

    static func update(_ state: AppState, _ repo: UUID, _ id: UUID, _ change: (inout Worktree) -> Void) {
        guard let index = state.worktrees[repo]?.firstIndex(where: { $0.id == id }) else {
            Issue.record("No row \(id) in repo \(repo)")
            return
        }
        change(&state.worktrees[repo]![index])
    }
}
