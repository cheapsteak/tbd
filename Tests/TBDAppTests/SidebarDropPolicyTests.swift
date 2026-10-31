import Foundation
import Testing
@testable import TBDApp
import TBDShared

// Tier 1: pure values, no AppKit and no AppState. Every test asks the policy
// about the fixture tree drawn under "Fixture" below, and each pins one rule.

/// `SidebarDropPolicy`: what a drag carries and where it can go.
/// Spec: docs/specs/2026-10-31-native-sidebar-design.md, "Drag and drop".
@Suite("Sidebar drop policy")
struct SidebarDropPolicyTests {
    // MARK: Where it can go

    /// Onto a worktree row: the carried rows nest as its last children.
    @Test func ontoWorktreeNestsAsLastChild() {
        let tree = Self.tree
        let single = Self.drop([Rows.b], onto: .worktree(Rows.a), in: tree)
        #expect(single.decision == .nest(under: Rows.a))
        #expect(single.retarget == nil)

        // Several rows nest together, whatever depth each comes from.
        let several = Self.drop([Rows.a2, Rows.b], onto: .worktree(Rows.a1a), in: tree)
        #expect(several.decision == .nest(under: Rows.a1a))
        #expect(several.retarget == nil)
    }

    /// Onto the main row: un-nest to the top of the repo's worktrees,
    /// directly below main, shown at that gap.
    @Test func ontoMainRowUnNestsToTopBelowMain() {
        let tree = Self.tree
        let nested = Self.drop([Rows.a1], onto: .worktree(Rows.mainA), in: tree)
        #expect(nested.decision == .place(parent: nil, before: Rows.a))
        #expect(nested.retarget == Self.at(.repoHeader(Rows.repoA), 1))

        // The first top-level row is itself carried, so the rows land before
        // the next one.
        let first = Self.drop([Rows.a], onto: .worktree(Rows.mainA), in: tree)
        #expect(first.decision == .place(parent: nil, before: Rows.b))
        #expect(first.retarget == Self.at(.repoHeader(Rows.repoA), 1))
    }

    /// Between siblings at any depth: a reorder under the same parent, a
    /// re-parent under another.
    @Test func betweenSiblingsAtDepthPlacesBefore() {
        let tree = Self.tree
        // Between y and c1, from elsewhere in the section.
        let reparent = Self.drop([Rows.d], into: .worktree(Rows.c), at: 1, depth: 1, in: tree)
        #expect(reparent.decision == .place(parent: Rows.c, before: Rows.c1))
        #expect(reparent.retarget == nil)

        // Between a1's subtree and a2, from the top level.
        let into = Self.drop([Rows.b], into: .worktree(Rows.a), at: 1, depth: 1, in: tree)
        #expect(into.decision == .place(parent: Rows.a, before: Rows.a2))
        #expect(into.retarget == nil)

        // Above a2's first child.
        let first = Self.drop([Rows.b], into: .worktree(Rows.a2), at: 0, depth: 2, in: tree)
        #expect(first.decision == .place(parent: Rows.a2, before: Rows.a2a))
        #expect(first.retarget == nil)

        // Among the row's own siblings.
        let reorder = Self.drop([Rows.c1], into: .worktree(Rows.c), at: 0, depth: 1, in: tree)
        #expect(reorder.decision == .place(parent: Rows.c, before: Rows.y))
    }

    /// The gap below a2a — the last row of a2's subtree and of a's — can mean
    /// the end of a2's children, the end of a's, or the top level. The
    /// pointer's x picks, clamped between the depths of b below (0) and a2a
    /// above (2), whichever level the outline proposed.
    @Test func endOfSubtreeGapResolvesByPointerX() {
        let tree = Self.tree
        let inset: CGFloat = 20
        let depths = [4, 17, 31].map { SidebarDropPolicy.pointerDepth(x: inset + CGFloat($0), inset: inset) }
        #expect(depths == [0, 1, 2])

        let answers = depths.map { depth in
            Self.drop([Rows.a1], into: .repoHeader(Rows.repoA), at: 2, depth: depth, in: tree)
        }
        let decisions = answers.map { $0.decision }
        #expect(decisions == [
            .place(parent: nil, before: Rows.b),
            .place(parent: Rows.a, before: nil),
            .place(parent: Rows.a2, before: nil),
        ])
        let retargets = answers.map { $0.retarget }
        #expect(retargets == [nil, Self.at(.worktree(Rows.a), 2), Self.at(.worktree(Rows.a2), 1)])

        // The outline may name the same gap from a2's level; the pointer
        // still decides.
        let fromA2 = Self.drop([Rows.a1], into: .worktree(Rows.a2), at: 1, depth: 0, in: tree)
        #expect(fromA2.decision == .place(parent: nil, before: Rows.b))
        #expect(fromA2.retarget == Self.at(.repoHeader(Rows.repoA), 2))

        // Past either end, the depth clamps to the rows around the gap.
        let tooDeep = Self.drop([Rows.a1], into: .repoHeader(Rows.repoA), at: 2, depth: 7, in: tree)
        #expect(tooDeep.decision == .place(parent: Rows.a2, before: nil))
        let tooShallow = Self.drop([Rows.a1], into: .worktree(Rows.a), at: 2, depth: -3, in: tree)
        #expect(tooShallow.decision == .place(parent: nil, before: Rows.b))
    }

    /// A proposal between two section headers is the end of the section above.
    @Test func gapBetweenSectionsReadsAsEndOfSectionAbove() {
        let tree = Self.tree
        // Between Repo B and Repo E: the end of Repo B's rows.
        let endOfB = Self.drop([Rows.c1], into: nil, at: 3, depth: 0, in: tree)
        #expect(endOfB.decision == .place(parent: nil, before: nil))
        #expect(endOfB.retarget == Self.at(.repoHeader(Rows.repoB), 3))

        // Between Repo A and Repo B, below Repo A's Hibernated group. At depth
        // 0 it is Repo A's top level, past its sessions and groups, so it
        // moves to the end of Repo A's worktree rows.
        let endOfA = Self.drop([Rows.a1], into: nil, at: 2, depth: 0, in: tree)
        #expect(endOfA.decision == .place(parent: nil, before: nil))
        #expect(endOfA.retarget == Self.at(.repoHeader(Rows.repoA), 3))

        // One level deeper it is the end of the group, open to its own rows.
        let endOfGroup = Self.drop([Rows.h1], into: nil, at: 2, depth: 1, in: tree)
        #expect(endOfGroup.decision == .place(parent: nil, before: nil))
        #expect(endOfGroup.retarget == Self.at(.group(Self.hibernatedA), 2))
    }

    @Test func noRetargetWhenAnswerMatchesProposal() {
        let tree = Self.tree
        #expect(Self.drop([Rows.b], onto: .worktree(Rows.a), in: tree).retarget == nil)
        #expect(Self.drop([Rows.d], into: .worktree(Rows.c), at: 1, depth: 1, in: tree).retarget == nil)
        #expect(Self.drop([Rows.a1], into: .repoHeader(Rows.repoA), at: 2, depth: 0, in: tree).retarget == nil)

        // The same answer reached from another proposal retargets.
        let moved = Self.drop([Rows.a1], into: .worktree(Rows.a2), at: 1, depth: 0, in: tree)
        #expect(moved.decision == .place(parent: nil, before: Rows.b))
        #expect(moved.retarget == Self.at(.repoHeader(Rows.repoA), 2))
    }

    /// Between a repo's top-level rows: un-nest to the top level.
    @Test func betweenTopLevelRowsUnNests() {
        let tree = Self.tree
        // Between main and a, however far right the pointer is.
        let top = Self.drop([Rows.a1a], into: .repoHeader(Rows.repoA), at: 1, depth: 3, in: tree)
        #expect(top.decision == .place(parent: nil, before: Rows.a))
        #expect(top.retarget == nil)

        // Between a's subtree and b, at the top level's depth.
        let afterSubtree = Self.drop([Rows.a1], into: .repoHeader(Rows.repoA), at: 2, depth: 0, in: tree)
        #expect(afterSubtree.decision == .place(parent: nil, before: Rows.b))

        // Between b and the first inline session: the end of the worktree rows.
        let end = Self.drop([Rows.a2a], into: .repoHeader(Rows.repoA), at: 3, depth: 0, in: tree)
        #expect(end.decision == .place(parent: nil, before: nil))
        #expect(end.retarget == nil)
    }

    /// Scratch rows reorder within the scratch section, and nest nowhere.
    @Test func scratchReordersOnlyWithinScratch() {
        let tree = Self.tree
        let first = Self.drop([Rows.s2], into: .scratchHeader, at: 0, in: tree)
        #expect(first.decision == .place(parent: nil, before: Rows.s1))
        #expect(first.retarget == nil)
        let last = Self.drop([Rows.s1], into: .scratchHeader, at: 2, in: tree)
        #expect(last.decision == .place(parent: nil, before: nil))
        #expect(last.retarget == nil)

        #expect(Self.drop([Rows.s1], into: .repoHeader(Rows.repoA), at: 2, in: tree).decision == .reject)
        #expect(Self.drop([Rows.s1], into: nil, at: 2, in: tree).decision == .reject)
        #expect(Self.drop([Rows.s1], onto: .worktree(Rows.a), in: tree).decision == .reject)
        #expect(Self.drop([Rows.s1], onto: .worktree(Rows.mainA), in: tree).decision == .reject)
    }

    /// No row but a scratch row drops into the scratch section.
    @Test func worktreeIntoScratchSectionRejected() {
        let tree = Self.tree
        #expect(Self.drop([Rows.b], into: .scratchHeader, at: 1, in: tree).decision == .reject)
        // The gap between the Scratch section and Repo A is the end of Scratch.
        #expect(Self.drop([Rows.b], into: nil, at: 1, in: tree).decision == .reject)
        #expect(Self.drop([Rows.b], into: .group(Self.scratchHibernated), at: 0, depth: 1, in: tree).decision
                == .reject)
    }

    @Test func ontoCarriedRowOrDescendantRejected() {
        let tree = Self.tree
        #expect(Self.drop([Rows.a], onto: .worktree(Rows.a), in: tree).decision == .reject)
        #expect(Self.drop([Rows.a], onto: .worktree(Rows.a1a), in: tree).decision == .reject)
        #expect(Self.drop([Rows.a, Rows.b], onto: .worktree(Rows.b), in: tree).decision == .reject)

        // Gaps inside a carried row's subtree.
        #expect(Self.drop([Rows.a], into: .worktree(Rows.a), at: 1, depth: 1, in: tree).decision == .reject)
        #expect(Self.drop([Rows.a], into: .worktree(Rows.a1), at: 1, depth: 2, in: tree).decision == .reject)

        // The gap just below the subtree, at the row's own level, is outside it.
        #expect(Self.drop([Rows.a], into: .repoHeader(Rows.repoA), at: 2, depth: 0, in: tree).decision
                == .place(parent: nil, before: Rows.b))
    }

    /// Nothing nests under a scratch row, a remote session or a header.
    @Test func ontoScratchSessionOrHeaderRejected() {
        let tree = Self.tree
        let targets: [SidebarNodeID?] = [
            .worktree(Rows.s1), .remoteSession(Rows.r1), .repoHeader(Rows.repoA), .scratchHeader,
            .group(Self.remoteA), .group(Self.hibernatedA), nil,
        ]
        for target in targets {
            #expect(Self.drop([Rows.b], onto: target, in: tree).decision == .reject,
                    "onto \(String(describing: target))")
        }
        #expect(Self.drop([Rows.s2], onto: .worktree(Rows.s1), in: tree).decision == .reject)
    }

    /// Another repo's section takes nothing but a reorder among the carried
    /// rows' current siblings there.
    @Test func otherRepoSectionRejectedExceptSiblingReorder() {
        let tree = Self.tree
        // Repo A's b into Repo B's section.
        #expect(Self.drop([Rows.b], into: .repoHeader(Rows.repoB), at: 2, in: tree).decision == .reject)
        #expect(Self.drop([Rows.b], onto: .worktree(Rows.c), in: tree).decision == .reject)
        #expect(Self.drop([Rows.b], onto: .worktree(Rows.mainB), in: tree).decision == .reject)

        // y renders in Repo B's section but belongs to another repo: it
        // reorders among its current siblings and goes nowhere else.
        let after = Self.drop([Rows.y], into: .worktree(Rows.c), at: 2, depth: 1, in: tree)
        #expect(after.decision == .place(parent: Rows.c, before: nil))
        #expect(Self.drop([Rows.y], onto: .worktree(Rows.c), in: tree).decision == .nest(under: Rows.c))
        #expect(Self.drop([Rows.y], into: .repoHeader(Rows.repoB), at: 2, depth: 0, in: tree).decision == .reject)
        #expect(Self.drop([Rows.y], onto: .worktree(Rows.d), in: tree).decision == .reject)
        #expect(Self.drop([Rows.y], onto: .worktree(Rows.mainB), in: tree).decision == .reject)
    }

    /// A row's state decides which group renders it, so a gap inside a state
    /// group takes only the rows that came from that group.
    @Test func otherStateGroupGapRejected() {
        let tree = Self.tree
        #expect(Self.drop([Rows.b], into: .group(Self.hibernatedA), at: 1, depth: 1, in: tree).decision == .reject)
        #expect(Self.drop([Rows.l1], into: .group(Self.hibernatedA), at: 0, depth: 1, in: tree).decision == .reject)
        #expect(Self.drop([Rows.h1], into: .group(Self.remoteA), at: 1, depth: 1, in: tree).decision == .reject)

        let within = Self.drop([Rows.h2], into: .group(Self.hibernatedA), at: 0, depth: 1, in: tree)
        #expect(within.decision == .place(parent: nil, before: Rows.h1))
        #expect(within.retarget == nil)
    }

    /// No position inside a collapsed section takes rows.
    @Test func collapsedSectionRejected() {
        let tree = Self.tree
        #expect(Self.drop([Rows.b], into: .repoHeader(Rows.repoE), at: 0, in: tree).decision == .reject)
        // Below Repo E's header, the last section: the end of Repo E.
        #expect(Self.drop([Rows.b], into: nil, at: 4, in: tree).decision == .reject)

        // The same section and rows, open and closed: the rows' own positions
        // are taken only while it is open.
        let rows = [Self.row(Rows.mainE, main: true), Self.row(Rows.e1), Self.row(Rows.e2)]
        let open = SidebarTree(roots: [Self.repo(Rows.repoE, rows)])
        let closed = SidebarTree(roots: [Self.repo(Rows.repoE, rows, expanded: false)])
        #expect(Self.drop([Rows.e2], into: .repoHeader(Rows.repoE), at: 1, in: open).decision
                == .place(parent: nil, before: Rows.e1))
        #expect(Self.drop([Rows.e2], into: .repoHeader(Rows.repoE), at: 1, in: closed).decision == .reject)
        #expect(Self.drop([Rows.e2], onto: .worktree(Rows.e1), in: open).decision == .nest(under: Rows.e1))
        #expect(Self.drop([Rows.e2], onto: .worktree(Rows.e1), in: closed).decision == .reject)
        #expect(Self.drop([Rows.e2], into: nil, at: 1, in: open).decision == .place(parent: nil, before: nil))
        #expect(Self.drop([Rows.e2], into: nil, at: 1, in: closed).decision == .reject)
    }

    @Test func aboveMainRetargetsBelowMain() {
        let tree = Self.tree
        let aboveA = Self.drop([Rows.b], into: .repoHeader(Rows.repoA), at: 0, in: tree)
        #expect(aboveA.decision == .place(parent: nil, before: Rows.a))
        #expect(aboveA.retarget == Self.at(.repoHeader(Rows.repoA), 1))

        let aboveB = Self.drop([Rows.c1], into: .repoHeader(Rows.repoB), at: 0, in: tree)
        #expect(aboveB.decision == .place(parent: nil, before: Rows.c))
        #expect(aboveB.retarget == Self.at(.repoHeader(Rows.repoB), 1))
    }

    /// A gap among the inline remote sessions that follow a repo's worktrees
    /// moves to the gap after the last worktree row.
    @Test func amongInlineSessionsRetargetsToLastWorktreeGap() {
        let tree = Self.tree
        // Between r1 and r2, and between r2 and the Remote group.
        for childIndex in [4, 5] {
            let answer = Self.drop([Rows.a1], into: .repoHeader(Rows.repoA), at: childIndex, in: tree)
            #expect(answer.decision == .place(parent: nil, before: nil))
            #expect(answer.retarget == Self.at(.repoHeader(Rows.repoA), 3))
        }
        // Directly after the last worktree row, the proposal stands.
        #expect(Self.drop([Rows.a1], into: .repoHeader(Rows.repoA), at: 3, in: tree).retarget == nil)
    }

    // MARK: What a drag carries

    @Test func carriedDropsMainSessionsAndDescendants() {
        let tree = Self.tree
        let selection: [SidebarNodeID] = [
            .worktree(Rows.mainA), .remoteSession(Rows.r1), .worktree(Rows.a), .worktree(Rows.a1),
            .worktree(Rows.a1a), .worktree(Rows.b), .repoHeader(Rows.repoA), .group(Self.hibernatedA),
        ]
        let fromA = SidebarDropPolicy.carried(selection: selection, origin: .worktree(Rows.a), tree: tree)
        #expect(fromA == [Rows.a, Rows.b])

        // An adopted remote lane is a worktree row and travels; the rows come
        // back in tree order, not selection order.
        let lane = SidebarDropPolicy.carried(
            selection: [.worktree(Rows.l1), .worktree(Rows.b)], origin: .worktree(Rows.l1), tree: tree)
        #expect(lane == [Rows.b, Rows.l1])

        // A child travels with its selected parent.
        let child = SidebarDropPolicy.carried(
            selection: [.worktree(Rows.a1a), .worktree(Rows.a1)], origin: .worktree(Rows.a1a), tree: tree)
        #expect(child == [Rows.a1])
    }

    @Test func carriedMixedSelectionKeepsKindUnderCursor() {
        let tree = Self.tree
        let mixed: [SidebarNodeID] = [.worktree(Rows.b), .worktree(Rows.s2), .worktree(Rows.a), .worktree(Rows.s1)]
        let scratch = SidebarDropPolicy.carried(selection: mixed, origin: .worktree(Rows.s2), tree: tree)
        #expect(scratch == [Rows.s1, Rows.s2])
        let worktrees = SidebarDropPolicy.carried(selection: mixed, origin: .worktree(Rows.a), tree: tree)
        #expect(worktrees == [Rows.a, Rows.b])

        // A drag from an unselected row carries that row alone.
        let unselected = SidebarDropPolicy.carried(selection: mixed, origin: .worktree(Rows.d), tree: tree)
        #expect(unselected == [Rows.d])

        // A row that cannot be dragged starts no drag, selected or not.
        let main = SidebarDropPolicy.carried(
            selection: mixed + [.worktree(Rows.mainA)], origin: .worktree(Rows.mainA), tree: tree)
        #expect(main.isEmpty)
        let session = SidebarDropPolicy.carried(selection: mixed, origin: .remoteSession(Rows.r1), tree: tree)
        #expect(session.isEmpty)
    }

    // MARK: Cost

    /// A decision reads only the nodes on the paths it asks about. Over an
    /// 800-row section — 700 top-level rows, a 12-deep chain under one of
    /// them, and 87 inline sessions — no call reads more than a small
    /// multiple of the tree's depth, where a walk of the tree would read
    /// every row.
    @Test func resolveIsDepthBounded() {
        let chainDepth = 12
        var chain = Self.row(Rows.id(9_000 + chainDepth))
        for link in stride(from: chainDepth - 1, through: 1, by: -1) {
            chain = Self.row(Rows.id(9_000 + link), [chain])
        }
        var rows: [SidebarNode] = [Self.row(Rows.id(500), main: true)]
        for number in 0..<700 {
            rows.append(Self.row(Rows.id(1_000 + number), number == 350 ? [chain] : []))
        }
        for number in 0..<87 {
            rows.append(Self.session(Rows.id(5_000 + number)))
        }
        let tree = SidebarTree(roots: [Self.repo(Rows.repoA, rows)])
        // 800 rows under one header.
        #expect(tree.visibleRowCount == 801)

        let counter = SidebarDropIndex.ReadCounter()
        let index = SidebarDropIndex(tree, counter: counter)
        let section = SidebarNodeID.repoHeader(Rows.repoA)
        let links = (1...chainDepth).map { SidebarNodeID.worktree(Rows.id(9_000 + $0)) }
        var proposals: [(parent: SidebarNodeID?, childIndex: Int)] = [(nil, 1)]
        for childIndex in stride(from: 0, through: rows.count, by: 7) {
            proposals.append((section, childIndex))
        }
        for number in stride(from: 0, to: 700, by: 13) {
            proposals.append((.worktree(Rows.id(1_000 + number)), SidebarDropPolicy.dropOnItemIndex))
        }
        for link in links {
            proposals.append((link, 0))
            proposals.append((link, 1))
            proposals.append((link, SidebarDropPolicy.dropOnItemIndex))
        }

        let carried = [Rows.id(1_010), Rows.id(1_011)]
        var mostReads = 0
        for call in 0..<10_000 {
            let proposal = proposals[call % proposals.count]
            counter.count = 0
            _ = SidebarDropPolicy.resolve(
                carried: carried, proposedParent: proposal.parent, childIndex: proposal.childIndex,
                pointerDepth: call % 16, index: index)
            mostReads = max(mostReads, counter.count)
        }
        // The deepest row sits at outline level 13: the header, row 350, then
        // the chain. Each carried row, and each of four walks — down to the
        // row above a gap, up to the row below it, up to the landing level,
        // and up from the landing parent — reads at most one node per level.
        let maxLevel = chainDepth + 1
        let bound = (carried.count + 4) * (maxLevel + 1) + carried.count + 1
        #expect(mostReads > 0, "The counter sees the reads")
        #expect(mostReads <= bound)
        #expect(bound < rows.count / 4)

        // Onto the chain's innermost row, the walk does climb the whole chain.
        counter.count = 0
        _ = SidebarDropPolicy.resolve(
            carried: carried, proposedParent: links[chainDepth - 1], childIndex: SidebarDropPolicy.dropOnItemIndex,
            pointerDepth: 0, index: index)
        #expect(counter.count >= chainDepth)
    }

    // MARK: Fixture
    //
    // Scratch
    //   s1
    //   s2
    //   Hibernated
    //     s3
    // Repo A
    //   main A
    //   a
    //     a1
    //       a1a
    //     a2
    //       a2a
    //   b
    //   session r1
    //   session r2
    //   Remote
    //     lane l1         an adopted remote lane: a worktree row
    //   Hibernated
    //     h1
    //     h2
    // Repo B
    //   main B
    //   c
    //     y               another repo's row, with the "(repo)" suffix
    //     c1
    //   d
    // Repo E              collapsed

    enum Rows {
        static let s1 = id(101), s2 = id(102), s3 = id(103)
        static let repoA = id(1), mainA = id(10), a = id(11), a1 = id(12), a1a = id(13), a2 = id(14), a2a = id(15)
        static let b = id(16), r1 = id(17), r2 = id(18), l1 = id(19), h1 = id(20), h2 = id(21)
        static let repoB = id(2), mainB = id(30), c = id(31), y = id(32), c1 = id(33), d = id(34)
        static let repoE = id(3), mainE = id(40), e1 = id(41), e2 = id(42)

        static func id(_ number: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", number))!
        }
    }

    static var scratchHibernated: SidebarGroupID { SidebarGroupID(owner: .scratch, kind: .hibernated) }
    static var remoteA: SidebarGroupID { SidebarGroupID(owner: .repository(Rows.repoA), kind: .remote) }
    static var hibernatedA: SidebarGroupID { SidebarGroupID(owner: .repository(Rows.repoA), kind: .hibernated) }

    static var tree: SidebarTree {
        SidebarTree(roots: [
            scratch([
                row(Rows.s1),
                row(Rows.s2),
                group(scratchHibernated, [row(Rows.s3)]),
            ]),
            repo(Rows.repoA, [
                row(Rows.mainA, main: true),
                row(Rows.a, [
                    row(Rows.a1, [row(Rows.a1a)]),
                    row(Rows.a2, [row(Rows.a2a)]),
                ]),
                row(Rows.b),
                session(Rows.r1),
                session(Rows.r2),
                group(remoteA, [row(Rows.l1)]),
                group(hibernatedA, [row(Rows.h1), row(Rows.h2)]),
            ]),
            repo(Rows.repoB, [
                row(Rows.mainB, main: true),
                row(Rows.c, [row(Rows.y, foreign: true), row(Rows.c1)]),
                row(Rows.d),
            ]),
            repo(Rows.repoE, [], expanded: false),
        ])
    }

    static func row(_ id: UUID, _ children: [SidebarNode] = [], main: Bool = false, foreign: Bool = false) -> SidebarNode {
        let model = WorktreeRowModel(
            name: "row", leading: nil, isNameBold: false, subtitles: [], suffix: nil,
            showsNoStatusMark: false, showsDevServerDot: false, crossRepoLabel: foreign ? "(acme)" : nil,
            isPinned: false, depth: 0, isDimmed: false, isInHiddenSection: false, isMain: main,
            heightClass: .single)
        return SidebarNode(id: .worktree(id), kind: .worktree(model), children: children, isExpanded: true)
    }

    static func session(_ id: UUID) -> SidebarNode {
        let model = RemoteSessionRowModel(
            title: "session", isPending: false, isNameBold: false, isExited: false, caption: nil,
            suffix: nil, isGone: false, isSelected: false, depth: 0, isInHiddenSection: false)
        return SidebarNode(id: .remoteSession(id), kind: .remoteSession(model), children: [], isExpanded: false)
    }

    static func group(_ id: SidebarGroupID, _ children: [SidebarNode]) -> SidebarNode {
        let model = GroupHeaderModel(
            kind: id.kind, count: nil, summary: nil, attention: nil, hasUncertainty: false,
            isExpanded: true, depth: 0, isInHiddenSection: false)
        return SidebarNode(id: .group(id), kind: .groupHeader(model), children: children, isExpanded: true)
    }

    static func repo(_ id: UUID, _ children: [SidebarNode], expanded: Bool = true) -> SidebarNode {
        SidebarNode(id: .repoHeader(id), kind: .repoHeader(header(expanded: expanded)),
                    children: children, isExpanded: expanded)
    }

    static func scratch(_ children: [SidebarNode]) -> SidebarNode {
        SidebarNode(id: .scratchHeader, kind: .scratchHeader(header(expanded: true)),
                    children: children, isExpanded: true)
    }

    static func header(expanded: Bool) -> SectionHeaderModel {
        SectionHeaderModel(title: "section", isExpanded: expanded, isHidden: false, isMissing: false, isSelected: false)
    }

    // MARK: Asking the policy

    /// A retarget as a value `#expect` can compare.
    struct Target: Equatable {
        let parent: SidebarNodeID?
        let childIndex: Int
    }

    struct Answer {
        let decision: SidebarDropDecision
        let retarget: Target?
    }

    static func at(_ parent: SidebarNodeID?, _ childIndex: Int) -> Target {
        Target(parent: parent, childIndex: childIndex)
    }

    /// Drops `carried` onto `target`.
    static func drop(_ carried: [UUID], onto target: SidebarNodeID?, in tree: SidebarTree) -> Answer {
        answer(SidebarDropPolicy.resolve(
            carried: carried, proposedParent: target, childIndex: SidebarDropPolicy.dropOnItemIndex,
            pointerDepth: 0, tree: tree))
    }

    /// Drops `carried` into the gap at `childIndex` among `parent`'s
    /// children — the roots for nil — with the pointer at visual `depth`.
    static func drop(_ carried: [UUID], into parent: SidebarNodeID?, at childIndex: Int, depth: Int = 0,
                     in tree: SidebarTree) -> Answer {
        answer(SidebarDropPolicy.resolve(
            carried: carried, proposedParent: parent, childIndex: childIndex, pointerDepth: depth, tree: tree))
    }

    static func answer(_ resolved: SidebarDropPolicy.Answer) -> Answer {
        Answer(decision: resolved.decision,
               retarget: resolved.retarget.map { Target(parent: $0.parent, childIndex: $0.childIndex) })
    }
}
