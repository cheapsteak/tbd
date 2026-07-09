import Foundation
import Testing
@testable import TBDApp
import TBDShared

// MARK: - Helpers

private extension RowActionMenu.Item {
    /// The action kind when this item is an `.action`, else nil — for terse
    /// ordered-kind assertions.
    var actionKind: RowActionMenu.Kind? {
        if case let .action(action) = self { return action.kind }
        return nil
    }

    var action: RowActionMenu.Action? {
        if case let .action(action) = self { return action }
        return nil
    }
}

private func kinds(_ items: [RowActionMenu.Item]) -> [RowActionMenu.Kind] {
    items.compactMap(\.actionKind)
}

private func session(_ label: String, profileID: UUID? = nil) -> RowActionMenu.ClaudeSessionRef {
    RowActionMenu.ClaudeSessionRef(terminalID: UUID(), profileID: profileID, label: label)
}

/// Indices of the dividers in `items` — for asserting section boundaries.
private func dividerIndices(_ items: [RowActionMenu.Item]) -> [Int] {
    items.enumerated().filter { $0.element == .divider }.map(\.offset)
}

/// Empty sections must collapse: no leading/trailing divider and never two in a row.
private func expectWellFormedDividers(_ items: [RowActionMenu.Item]) {
    #expect(items.first != .divider)
    #expect(items.last != .divider)
    for (a, b) in zip(items, items.dropFirst()) {
        #expect(!(a == .divider && b == .divider))
    }
}

// MARK: - Regular worktree branch

@Suite("RowActionMenu — regular worktree")
struct RowActionMenuRegularTests {
    @Test func fullShapeWithAllSectionsPresent() {
        // Every conditional on: rename/archive | hibernation | fork/nested |
        // finder/copy — four sections, three dividers.
        let s = session("Claude 1")
        let ctx = RowActionMenu.Context(hasHibernatableClaude: true,
                                        hasHibernatedClaude: true,
                                        hasUnpinnedClaude: true,
                                        hasKeepWarmClaude: true,
                                        hasRepoID: true,
                                        branch: "tbd/x",
                                        claudeSessions: [s])
        let items = RowActionMenu.items(context: ctx)
        #expect(kinds(items) == [
            .rename,
            .archive,
            .wakeHibernated,
            .hibernateNow,
            .toggleKeepWarm(enable: true),
            .toggleKeepWarm(enable: false),
            .forkSession(terminalID: s.terminalID, profileID: s.profileID),
            .createNestedWorktree,
            .newWorktreeFromBranch,
            .openInFinder,
            .copyPath,
        ])
        // Section boundaries: after archive, after the hibernation block, and
        // after the fork/nested block.
        #expect(dividerIndices(items) == [2, 7, 11])
        expectWellFormedDividers(items)
    }

    @Test func emptyHibernationSectionCollapses() {
        // No Claude sessions at all: the hibernation and fork sections are
        // empty, so exactly two dividers remain — rename/archive | nested |
        // finder/copy — with no doubled or dangling dividers.
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "tbd/x")
        let items = RowActionMenu.items(context: ctx)
        #expect(kinds(items) == [
            .rename,
            .archive,
            .createNestedWorktree,
            .newWorktreeFromBranch,
            .openInFinder,
            .copyPath,
        ])
        #expect(dividerIndices(items) == [2, 5])
        expectWellFormedDividers(items)
    }

    @Test func emptySpawningSectionCollapses() {
        // No repo, no sessions, no hibernation: only the identity and
        // filesystem sections remain, joined by a single divider.
        let ctx = RowActionMenu.Context(hasRepoID: false, branch: "")
        let items = RowActionMenu.items(context: ctx)
        #expect(kinds(items) == [.rename, .archive, .openInFinder, .copyPath])
        #expect(dividerIndices(items) == [2])
        expectWellFormedDividers(items)
    }

    @Test func hibernateShownWhenHibernatableClaudePresent() {
        // Suspend/Resume retired: the unified park verb is "Hibernate now".
        let ctx = RowActionMenu.Context(hasHibernatableClaude: true, hasRepoID: true, branch: "b")
        #expect(kinds(RowActionMenu.items(context: ctx)).contains(.hibernateNow))
    }

    @Test func wakeShownWhenHibernatedClaudePresent() {
        // A parked session (hibernated or legacy-suspended, folded to the same
        // `hasHibernatedClaude` context flag) drives the single "Wake" verb.
        let ctx = RowActionMenu.Context(hasHibernatedClaude: true, hasRepoID: true, branch: "b")
        #expect(kinds(RowActionMenu.items(context: ctx)).contains(.wakeHibernated))
    }

    @Test func nestedWorktreeOnlyWhenRepoPresent() {
        let noRepo = RowActionMenu.Context(hasRepoID: false, branch: "b")
        #expect(!kinds(RowActionMenu.items(context: noRepo)).contains(.createNestedWorktree))
        #expect(!kinds(RowActionMenu.items(context: noRepo)).contains(.newWorktreeFromBranch))
    }

    @Test func newWorktreeFromBranchOmittedWhenBranchEmpty() {
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "")
        let ks = kinds(RowActionMenu.items(context: ctx))
        #expect(ks.contains(.createNestedWorktree))
        #expect(!ks.contains(.newWorktreeFromBranch))
    }

    @Test func archiveDisabledRetitledWithHelpWhenChildrenActive() {
        let ctx = RowActionMenu.Context(hasActiveChildren: true, hasRepoID: true, branch: "b")
        let archive = RowActionMenu.items(context: ctx)
            .compactMap(\.action).first { $0.kind == .archive }
        #expect(archive?.title == RowActionMenu.archiveHasChildrenLabel)
        #expect(archive?.title == "Archive (has children)")
        #expect(archive?.isEnabled == false)
        #expect(archive?.role == .destructive)
        #expect(archive?.disabledHelp == RowActionMenu.archiveNeedsChildrenGoneHelp)
    }

    @Test func archiveEnabledPlainTitleWhenNoChildren() {
        let ctx = RowActionMenu.Context(hasActiveChildren: false, hasRepoID: true, branch: "b")
        let archive = RowActionMenu.items(context: ctx)
            .compactMap(\.action).first { $0.kind == .archive }
        #expect(archive?.title == "Archive")
        #expect(archive?.isEnabled == true)
        #expect(archive?.disabledHelp == nil)
    }

    @Test("re-run item appears only when a preSession hook resolves")
    func rerunItemGatedOnHook() {
        let without = RowActionMenu.items(context: .init(hasPreSessionHook: false))
        #expect(!without.contains(.action(.init(
            kind: .rerunPreSessionHook, title: RowActionMenu.rerunPreSessionLabel
        ))))

        let with = RowActionMenu.items(context: .init(hasPreSessionHook: true))
        #expect(with.contains(.action(.init(
            kind: .rerunPreSessionHook, title: RowActionMenu.rerunPreSessionLabel
        ))))
    }

    @Test("re-run item sits in its own section directly above Open in Finder")
    func rerunItemSection() throws {
        let items = RowActionMenu.items(context: .init(hasPreSessionHook: true))
        let rerun = try #require(items.firstIndex(of: .action(.init(
            kind: .rerunPreSessionHook, title: RowActionMenu.rerunPreSessionLabel
        ))))
        // Divider immediately before and after → its own section.
        #expect(items[rerun - 1] == .divider)
        #expect(items[rerun + 1] == .divider)
        #expect(items[rerun + 2] == .action(.init(kind: .openInFinder, title: "Open in Finder")))
    }

    @Test("scratch rows get the re-run item, main rows never do")
    func rerunItemRowScope() {
        let scratch = RowActionMenu.items(context: .init(isScratch: true, hasPreSessionHook: true))
        #expect(scratch.contains(.action(.init(
            kind: .rerunPreSessionHook, title: RowActionMenu.rerunPreSessionLabel
        ))))

        let main = RowActionMenu.items(context: .init(
            status: .main, hasPreSessionHook: true
        ))
        #expect(!main.contains(.action(.init(
            kind: .rerunPreSessionHook, title: RowActionMenu.rerunPreSessionLabel
        ))))
    }

}

// MARK: - Scratch branch

@Suite("RowActionMenu — scratch")
struct RowActionMenuScratchTests {
    @Test func fullShapeWithAllSectionsPresent() {
        // Every conditional on: rename/archive | hibernation | fork |
        // finder/copy | delete + promote hint — five sections, four dividers,
        // Delete last among the actions and the caption at the very bottom.
        let s = session("Claude 1")
        let ctx = RowActionMenu.Context(hasHibernatableClaude: true,
                                        hasHibernatedClaude: true,
                                        hasUnpinnedClaude: true,
                                        hasKeepWarmClaude: true,
                                        isScratch: true,
                                        isPromoted: false,
                                        claudeSessions: [s])
        let items = RowActionMenu.items(context: ctx)
        #expect(kinds(items) == [
            .rename,
            .archiveScratch,
            .wakeHibernated,
            .hibernateNow,
            .toggleKeepWarm(enable: true),
            .toggleKeepWarm(enable: false),
            .forkSession(terminalID: s.terminalID, profileID: s.profileID),
            .openInFinder,
            .copyPath,
            .deleteScratch,
        ])
        #expect(dividerIndices(items) == [2, 7, 9, 12])
        // Promote hint caption is the very last item, under Delete.
        #expect(items.last == .caption(RowActionMenu.promoteHint))
        #expect(kinds(items).last == .deleteScratch)
        expectWellFormedDividers(items)
    }

    @Test func emptyMiddleSectionsCollapse() {
        // No Claude sessions at all: hibernation and fork sections vanish, so
        // the menu is rename/archive | finder/copy | delete(+caption) with
        // exactly two dividers — never doubled.
        let ctx = RowActionMenu.Context(isScratch: true, isPromoted: false)
        let items = RowActionMenu.items(context: ctx)
        #expect(kinds(items) == [
            .rename,
            .archiveScratch,
            .openInFinder,
            .copyPath,
            .deleteScratch,
        ])
        #expect(dividerIndices(items) == [2, 5])
        #expect(items.last == .caption(RowActionMenu.promoteHint))
        expectWellFormedDividers(items)
    }

    @Test func promoteHintOmittedWhenAlreadyPromoted() {
        let ctx = RowActionMenu.Context(isScratch: true, isPromoted: true)
        let items = RowActionMenu.items(context: ctx)
        #expect(!items.contains(.caption(RowActionMenu.promoteHint)))
        // Delete then becomes the literal last item.
        #expect(items.last?.actionKind == .deleteScratch)
    }

    @Test func scratchWithClaudeSessionCarriesForkEntries() {
        // Scratch spaces host Claude sessions too: the fork entries appear in
        // the middle section, same as the regular branch.
        let s = session("Claude 1")
        let ctx = RowActionMenu.Context(isScratch: true, claudeSessions: [s])
        let items = RowActionMenu.items(context: ctx)
        #expect(kinds(items) == [
            .rename,
            .archiveScratch,
            .forkSession(terminalID: s.terminalID, profileID: s.profileID),
            .openInFinder,
            .copyPath,
            .deleteScratch,
        ])
        expectWellFormedDividers(items)
    }

    @Test func scratchArchiveAndDeleteAreDestructive() {
        let ctx = RowActionMenu.Context(isScratch: true)
        let actions = RowActionMenu.items(context: ctx).compactMap(\.action)
        #expect(actions.first { $0.kind == .archiveScratch }?.role == .destructive)
        #expect(actions.first { $0.kind == .deleteScratch }?.role == .destructive)
    }
}

// MARK: - Main / creating branch

@Suite("RowActionMenu — main/creating")
struct RowActionMenuMainTests {
    @Test func mainShowsOnlyFinderAndCopyWhenPathPresent() {
        let ctx = RowActionMenu.Context(pathIsEmpty: false, status: .main)
        #expect(kinds(RowActionMenu.items(context: ctx)) == [.openInFinder, .copyPath])
    }

    @Test func creatingBehavesLikeMain() {
        let ctx = RowActionMenu.Context(pathIsEmpty: false, status: .creating)
        #expect(kinds(RowActionMenu.items(context: ctx)) == [.openInFinder, .copyPath])
    }

    @Test func emptyPathMainYieldsNoItems() {
        let ctx = RowActionMenu.Context(pathIsEmpty: true, status: .main)
        #expect(RowActionMenu.items(context: ctx).isEmpty)
    }
}

// MARK: - Fork session

@Suite("RowActionMenu — fork session")
struct RowActionMenuForkTests {
    @Test func noForkEntriesWhenNoClaudeSessions() {
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "b", claudeSessions: [])
        #expect(!kinds(RowActionMenu.items(context: ctx)).contains {
            if case .forkSession = $0 { return true }; return false
        })
    }

    @Test func singleSessionForkHasPlainTitle() {
        let s = session("Claude 1", profileID: UUID())
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "b", claudeSessions: [s])
        let fork = RowActionMenu.items(context: ctx).compactMap(\.action).first {
            if case .forkSession = $0.kind { return true }; return false
        }
        #expect(fork?.title == RowActionMenu.forkSessionLabel)
        if case let .forkSession(id, profileID)? = fork?.kind {
            #expect(id == s.terminalID)
            #expect(profileID == s.profileID)
        } else {
            Issue.record("expected a forkSession action")
        }
    }

    @Test func multipleSessionsForkTitlesCarryLabels() {
        let a = session("Reviewer")
        let b = session("Builder")
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "b", claudeSessions: [a, b])
        let forks = RowActionMenu.items(context: ctx).compactMap(\.action).filter {
            if case .forkSession = $0.kind { return true }; return false
        }
        #expect(forks.count == 2)
        #expect(forks.map(\.title) == [
            "\(RowActionMenu.forkSessionLabel) — Reviewer",
            "\(RowActionMenu.forkSessionLabel) — Builder",
        ])
    }

    @Test func forkAmbientSessionCarriesNilProfile() {
        let s = session("Claude 1", profileID: nil)
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "b", claudeSessions: [s])
        let forks = RowActionMenu.items(context: ctx).compactMap(\.action).filter {
            if case .forkSession = $0.kind { return true }; return false
        }
        #expect(forks.count == 1)
        if case let .forkSession(_, profileID)? = forks.first?.kind {
            #expect(profileID == nil)
        } else {
            Issue.record("expected forkSession")
        }
    }
}

// MARK: - Hibernation actions

@Suite("RowActionMenu — hibernation")
struct RowActionMenuHibernationTests {
    @Test func hibernateNowShownOnlyWhenHibernatableClaudePresent() {
        let ctx = RowActionMenu.Context(hasHibernatableClaude: true, hasRepoID: true, branch: "b")
        #expect(kinds(RowActionMenu.items(context: ctx)).contains(.hibernateNow))
        // Absent when nothing is hibernatable.
        let none = RowActionMenu.Context(hasRepoID: true, branch: "b")
        #expect(!kinds(RowActionMenu.items(context: none)).contains(.hibernateNow))
    }

    @Test func wakeShownOnlyWhenHibernatedClaudePresent() {
        let ctx = RowActionMenu.Context(hasHibernatedClaude: true, hasRepoID: true, branch: "b")
        #expect(kinds(RowActionMenu.items(context: ctx)).contains(.wakeHibernated))
        let none = RowActionMenu.Context(hasRepoID: true, branch: "b")
        #expect(!kinds(RowActionMenu.items(context: none)).contains(.wakeHibernated))
    }

    @Test func keepWarmToggleEnableShownWhenUnpinned() {
        let ctx = RowActionMenu.Context(hasUnpinnedClaude: true, hasRepoID: true, branch: "b")
        #expect(kinds(RowActionMenu.items(context: ctx)).contains(.toggleKeepWarm(enable: true)))
        #expect(!kinds(RowActionMenu.items(context: ctx)).contains(.toggleKeepWarm(enable: false)))
    }

    @Test func keepWarmToggleDisableShownWhenPinned() {
        let ctx = RowActionMenu.Context(hasKeepWarmClaude: true, hasRepoID: true, branch: "b")
        #expect(kinds(RowActionMenu.items(context: ctx)).contains(.toggleKeepWarm(enable: false)))
        #expect(!kinds(RowActionMenu.items(context: ctx)).contains(.toggleKeepWarm(enable: true)))
    }

    @Test func noHibernationEntriesInDefaultContext() {
        // A worktree with no Claude sessions shows none of the hibernation
        // actions — they don't clutter the common case.
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "b")
        let ks = kinds(RowActionMenu.items(context: ctx))
        #expect(!ks.contains(.hibernateNow))
        #expect(!ks.contains(.wakeHibernated))
        #expect(!ks.contains(.toggleKeepWarm(enable: true)))
        #expect(!ks.contains(.toggleKeepWarm(enable: false)))
    }

    @Test func hibernationActionsAppearInScratchToo() {
        let ctx = RowActionMenu.Context(hasHibernatedClaude: true, isScratch: true)
        #expect(kinds(RowActionMenu.items(context: ctx)).contains(.wakeHibernated))
    }
}
