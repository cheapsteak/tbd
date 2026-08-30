import Foundation
import TestSupport
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
        // Every conditional on: rename/archive | pin | hibernation |
        // fork/nested | maintenance | finder/copy — six sections, five
        // dividers. A repo-backed row with no hook resolving offers Create.
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
            .pin,
            .wakeHibernated,
            .hibernateNow,
            .toggleKeepWarm(enable: true),
            .toggleKeepWarm(enable: false),
            .forkSession(terminalID: s.terminalID, profileID: s.profileID),
            .createNestedWorktree,
            .newWorktreeFromBranch,
            .createPreSessionHook,
            .openInFinder,
            .copyPath,
            .copyLink,
            .copyBranch,
        ])
        // Section boundaries: after archive, after pin, after the hibernation
        // block, after the fork/nested block, and after the maintenance item.
        #expect(dividerIndices(items) == [2, 4, 9, 13, 15])
        expectWellFormedDividers(items)
    }

    @Test func emptyHibernationSectionCollapses() {
        // No Claude sessions at all: the hibernation and fork sections are
        // empty, so exactly four dividers remain — rename/archive | pin |
        // nested | maintenance | finder/copy — with no doubled or dangling
        // dividers.
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "tbd/x")
        let items = RowActionMenu.items(context: ctx)
        #expect(kinds(items) == [
            .rename,
            .archive,
            .pin,
            .createNestedWorktree,
            .newWorktreeFromBranch,
            .createPreSessionHook,
            .openInFinder,
            .copyPath,
            .copyLink,
            .copyBranch,
        ])
        #expect(dividerIndices(items) == [2, 4, 7, 9])
        expectWellFormedDividers(items)
    }

    @Test func emptySpawningSectionCollapses() {
        // No repo, no sessions, no hibernation: only the identity, pin, and
        // filesystem sections remain, joined by two dividers.
        let ctx = RowActionMenu.Context(hasRepoID: false, branch: "")
        let items = RowActionMenu.items(context: ctx)
        #expect(kinds(items) == [.rename, .archive, .pin, .openInFinder, .copyPath, .copyLink])
        #expect(dividerIndices(items) == [2, 4])
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

    @Test("regular row with a hook offers Re-run; without one, offers Create")
    func maintenanceItemThreeStates() {
        let with = RowActionMenu.items(context: .init(hasPreSessionHook: true))
        #expect(with.contains(.action(.init(
            kind: .rerunPreSessionHook, title: RowActionMenu.rerunPreSessionLabel
        ))))
        #expect(!kinds(with).contains(.createPreSessionHook))

        let without = RowActionMenu.items(context: .init(hasPreSessionHook: false))
        #expect(without.contains(.action(.init(
            kind: .createPreSessionHook, title: RowActionMenu.createPreSessionLabel
        ))))
        #expect(!kinds(without).contains(.rerunPreSessionHook))
    }

    @Test("the create item sits in its own section directly above Open in Finder")
    func createItemSection() throws {
        let items = RowActionMenu.items(context: .init(hasPreSessionHook: false))
        let create = try #require(items.firstIndex(of: .action(.init(
            kind: .createPreSessionHook, title: RowActionMenu.createPreSessionLabel
        ))))
        #expect(items[create - 1] == .divider)
        #expect(items[create + 1] == .divider)
        #expect(items[create + 2] == .action(.init(kind: .openInFinder, title: "Open in Finder")))
        expectWellFormedDividers(items)
    }

    @Test("re-run item sits in its own section directly above Open in Finder")
    func rerunItemSection() throws {
        let items = RowActionMenu.items(context: .init(hasPreSessionHook: true))
        let rerun = try #require(items.firstIndex(of: .action(.init(
            kind: .rerunPreSessionHook, title: RowActionMenu.rerunPreSessionLabel
        ))))
        #expect(items[rerun - 1] == .divider)
        #expect(items[rerun + 1] == .divider)
        #expect(items[rerun + 2] == .action(.init(kind: .openInFinder, title: "Open in Finder")))
        expectWellFormedDividers(items)
    }

    @Test("scratch rows get Re-run but never Create; the section collapses cleanly")
    func maintenanceItemRowScopeScratch() {
        // A scratch space has no repo hooks editor to reveal (isScratch IS repoID == nil).
        let scratchWith = RowActionMenu.items(context: .init(
            hasRepoID: false, isScratch: true, hasPreSessionHook: true
        ))
        #expect(kinds(scratchWith).contains(.rerunPreSessionHook))

        let scratchWithout = RowActionMenu.items(context: .init(
            hasRepoID: false, isScratch: true, hasPreSessionHook: false
        ))
        #expect(!kinds(scratchWithout).contains(.createPreSessionHook))
        #expect(!kinds(scratchWithout).contains(.rerunPreSessionHook))
        // The empty maintenance section must leave no doubled or dangling divider.
        expectWellFormedDividers(scratchWithout)
    }

    @Test("main rows get neither maintenance item")
    func maintenanceItemRowScopeMain() {
        for hasHook in [true, false] {
            let main = RowActionMenu.items(context: .init(
                status: .main, hasPreSessionHook: hasHook
            ))
            #expect(!kinds(main).contains(.rerunPreSessionHook))
            #expect(!kinds(main).contains(.createPreSessionHook))
        }
    }

}

// MARK: - Remote lane archive capability

@Suite("RowActionMenu — remote archive capability")
struct RowActionMenuRemoteArchiveTests {
    private static let remoteLocation = WorktreeLocation.remote(provider: "acme", sessionID: "s1")

    @Test func archiveDisabledWithReasonWhenProviderLacksArchiveCapability() {
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "b",
                                        location: Self.remoteLocation,
                                        provider: "acme",
                                        providerCapabilities: ["stop"])
        let archive = RowActionMenu.items(context: ctx)
            .compactMap(\.action).first { $0.kind == .archive }
        #expect(archive?.title == RowActionMenu.archiveProviderCannotArchiveLabel)
        #expect(archive?.title == "Archive (provider can't archive)")
        #expect(archive?.isEnabled == false)
        #expect(archive?.role == .destructive)
        #expect(archive?.disabledHelp == RowActionMenu.archiveNeedsProviderCapabilityHelp)
    }

    @Test func archiveEnabledWhenProviderDeclaresArchiveCapability() {
        // If the capability gate were dropped, this and the test above would
        // both show "Archive"/enabled — this is the one that proves the gate
        // actually discriminates on the declared capability set.
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "b",
                                        location: Self.remoteLocation,
                                        provider: "acme",
                                        providerCapabilities: ["archive", "stop"])
        let archive = RowActionMenu.items(context: ctx)
            .compactMap(\.action).first { $0.kind == .archive }
        #expect(archive?.title == "Archive")
        #expect(archive?.isEnabled == true)
        #expect(archive?.disabledHelp == nil)
    }

    @Test func localRowUnaffectedByCapabilitySet() {
        // Regression guard: a local row (default `.local` location) ignores
        // `providerCapabilities` entirely — Archive stays enabled even with an
        // empty capability set, exactly as before this gate existed.
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "b")
        #expect(ctx.location.isLocal)
        let archive = RowActionMenu.items(context: ctx)
            .compactMap(\.action).first { $0.kind == .archive }
        #expect(archive?.title == "Archive")
        #expect(archive?.isEnabled == true)
        #expect(archive?.disabledHelp == nil)
    }

    /// The `gone` exemption is "the only route out for a lane whose provider
    /// cannot archive" (spec §"Archive"), and the daemon takes it happily —
    /// `archivePlan` returns `.rowOnlyGone` for exactly this shape. A menu that
    /// disabled Archive here would be the surface blocking the one gesture the
    /// daemon is willing to perform.
    @Test func archiveEnabledForAGoneLaneWhoseProviderCannotArchive() {
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "b",
                                        location: Self.remoteLocation,
                                        provider: "acme",
                                        providerCapabilities: ["stop"],
                                        isGone: true)
        let archive = RowActionMenu.items(context: ctx)
            .compactMap(\.action).first { $0.kind == .archive }
        #expect(archive?.title == "Archive")
        #expect(archive?.isEnabled == true)
        #expect(archive?.disabledHelp == nil)
    }

    /// `gone` is not a blanket override of the other gate: a lane that is still
    /// enumerated stays disabled, which is what makes the exemption narrow
    /// rather than a way around the capability entirely.
    @Test func archiveStaysDisabledForALaneThatIsNotGone() {
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "b",
                                        location: Self.remoteLocation,
                                        provider: "acme",
                                        providerCapabilities: ["stop"],
                                        isGone: false)
        let archive = RowActionMenu.items(context: ctx)
            .compactMap(\.action).first { $0.kind == .archive }
        #expect(archive?.title == RowActionMenu.archiveProviderCannotArchiveLabel)
        #expect(archive?.isEnabled == false)
    }

    /// Active children still win over `gone`: that is a reason the user can act
    /// on right now, and it is not what the exemption is about.
    @Test func activeChildrenStillBlockAGoneLane() {
        let ctx = RowActionMenu.Context(hasActiveChildren: true,
                                        hasRepoID: true, branch: "b",
                                        location: Self.remoteLocation,
                                        provider: "acme",
                                        providerCapabilities: [],
                                        isGone: true)
        let archive = RowActionMenu.items(context: ctx)
            .compactMap(\.action).first { $0.kind == .archive }
        #expect(archive?.title == RowActionMenu.archiveHasChildrenLabel)
        #expect(archive?.isEnabled == false)
    }

    @Test func activeChildrenTakePrecedenceOverMissingCapabilityOnRemoteLane() {
        // Both gates apply: a remote lane with active children AND no
        // `archive` capability. Documented precedence lives in
        // `RowActionMenu.regularItems`: active children wins the title because
        // it's the reason the user can act on right now.
        let ctx = RowActionMenu.Context(hasActiveChildren: true,
                                        hasRepoID: true, branch: "b",
                                        location: Self.remoteLocation,
                                        provider: "acme",
                                        providerCapabilities: [])
        let archive = RowActionMenu.items(context: ctx)
            .compactMap(\.action).first { $0.kind == .archive }
        #expect(archive?.title == RowActionMenu.archiveHasChildrenLabel)
        #expect(archive?.disabledHelp == RowActionMenu.archiveNeedsChildrenGoneHelp)
        #expect(archive?.isEnabled == false)
    }
}

// MARK: - Scratch branch

@Suite("RowActionMenu — scratch")
struct RowActionMenuScratchTests {
    @Test func fullShapeWithAllSectionsPresent() {
        // Every conditional on: rename/archive | pin | hibernation | fork |
        // finder/copy | delete + promote hint — six sections, five dividers,
        // Delete last among the actions and the caption at the very bottom.
        let s = session("Claude 1")
        let ctx = RowActionMenu.Context(hasHibernatableClaude: true,
                                        hasHibernatedClaude: true,
                                        hasUnpinnedClaude: true,
                                        hasKeepWarmClaude: true,
                                        hasRepoID: false,
                                        isScratch: true,
                                        isPromoted: false,
                                        claudeSessions: [s])
        let items = RowActionMenu.items(context: ctx)
        #expect(kinds(items) == [
            .rename,
            .archiveScratch,
            .pin,
            .wakeHibernated,
            .hibernateNow,
            .toggleKeepWarm(enable: true),
            .toggleKeepWarm(enable: false),
            .forkSession(terminalID: s.terminalID, profileID: s.profileID),
            .openInFinder,
            .copyPath,
            .copyLink,
            .deleteScratch,
        ])
        #expect(dividerIndices(items) == [2, 4, 9, 11, 15])
        // Promote hint caption is the very last item, under Delete.
        #expect(items.last == .caption(RowActionMenu.promoteHint))
        #expect(kinds(items).last == .deleteScratch)
        expectWellFormedDividers(items)
    }

    @Test func emptyMiddleSectionsCollapse() {
        // No Claude sessions at all: hibernation and fork sections vanish, so
        // the menu is rename/archive | pin | finder/copy | delete(+caption)
        // with exactly three dividers — never doubled.
        let ctx = RowActionMenu.Context(hasRepoID: false, isScratch: true, isPromoted: false)
        let items = RowActionMenu.items(context: ctx)
        #expect(kinds(items) == [
            .rename,
            .archiveScratch,
            .pin,
            .openInFinder,
            .copyPath,
            .copyLink,
            .deleteScratch,
        ])
        #expect(dividerIndices(items) == [2, 4, 8])
        #expect(items.last == .caption(RowActionMenu.promoteHint))
        expectWellFormedDividers(items)
    }

    @Test func promoteHintOmittedWhenAlreadyPromoted() {
        let ctx = RowActionMenu.Context(hasRepoID: false, isScratch: true, isPromoted: true)
        let items = RowActionMenu.items(context: ctx)
        #expect(!items.contains(.caption(RowActionMenu.promoteHint)))
        // Delete then becomes the literal last item.
        #expect(items.last?.actionKind == .deleteScratch)
        // A scratch row has no repo hooks editor to reveal: neither
        // maintenance item should ever appear.
        #expect(!kinds(items).contains(.createPreSessionHook))
        #expect(!kinds(items).contains(.rerunPreSessionHook))
    }

    @Test func scratchWithClaudeSessionCarriesForkEntries() {
        // Scratch spaces host Claude sessions too: the fork entries appear in
        // the middle section, same as the regular branch.
        let s = session("Claude 1")
        let ctx = RowActionMenu.Context(hasRepoID: false, isScratch: true, claudeSessions: [s])
        let items = RowActionMenu.items(context: ctx)
        #expect(kinds(items) == [
            .rename,
            .archiveScratch,
            .pin,
            .forkSession(terminalID: s.terminalID, profileID: s.profileID),
            .openInFinder,
            .copyPath,
            .copyLink,
            .deleteScratch,
        ])
        expectWellFormedDividers(items)
    }

    @Test func scratchArchiveAndDeleteAreDestructive() {
        let ctx = RowActionMenu.Context(hasRepoID: false, isScratch: true)
        let items = RowActionMenu.items(context: ctx)
        let actions = items.compactMap(\.action)
        #expect(actions.first { $0.kind == .archiveScratch }?.role == .destructive)
        #expect(actions.first { $0.kind == .deleteScratch }?.role == .destructive)
        // A scratch row has no repo hooks editor to reveal: neither
        // maintenance item should ever appear.
        #expect(!kinds(items).contains(.createPreSessionHook))
        #expect(!kinds(items).contains(.rerunPreSessionHook))
    }
}

// MARK: - Main / creating branch

@Suite("RowActionMenu — main/creating")
struct RowActionMenuMainTests {
    @Test func mainShowsOnlyFinderAndCopyWhenPathPresent() {
        let ctx = RowActionMenu.Context(pathIsEmpty: false, status: .main)
        #expect(kinds(RowActionMenu.items(context: ctx)) == [.openInFinder, .copyPath, .copyLink])
    }

    @Test func creatingBehavesLikeMain() {
        let ctx = RowActionMenu.Context(pathIsEmpty: false, status: .creating)
        #expect(kinds(RowActionMenu.items(context: ctx)) == [.openInFinder, .copyPath, .copyLink])
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

    @Test func keepWarmToggleAbsentWhenAutoHibernateDisabled() {
        // Keep-warm is meaningless when the global auto-hibernate switch is
        // off — both toggle directions must be hidden even with eligible
        // sessions on both sides.
        let ctx = RowActionMenu.Context(hasUnpinnedClaude: true,
                                        hasKeepWarmClaude: true,
                                        autoHibernateEnabled: false,
                                        hasRepoID: true,
                                        branch: "b")
        let ks = kinds(RowActionMenu.items(context: ctx))
        #expect(!ks.contains(.toggleKeepWarm(enable: true)))
        #expect(!ks.contains(.toggleKeepWarm(enable: false)))
    }

    @Test func keepWarmTogglePresentWhenAutoHibernateEnabled() {
        let ctx = RowActionMenu.Context(hasUnpinnedClaude: true,
                                        hasKeepWarmClaude: true,
                                        autoHibernateEnabled: true,
                                        hasRepoID: true,
                                        branch: "b")
        let ks = kinds(RowActionMenu.items(context: ctx))
        #expect(ks.contains(.toggleKeepWarm(enable: true)))
        #expect(ks.contains(.toggleKeepWarm(enable: false)))
    }
}

// MARK: - Copy branch name

@Suite("RowActionMenu — copy branch")
struct RowActionMenuCopyBranchTests {
    @Test func copyBranchPresentWhenBranchNonEmpty() {
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "tbd/x")
        #expect(kinds(RowActionMenu.items(context: ctx)).contains(.copyBranch))
    }

    @Test func copyBranchAbsentWhenBranchEmpty() {
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "")
        #expect(!kinds(RowActionMenu.items(context: ctx)).contains(.copyBranch))
    }

    @Test func copyBranchAlsoAppearsInScratchAndMainWhenBranchPresent() {
        let scratch = RowActionMenu.Context(isScratch: true, branch: "tbd/x")
        #expect(kinds(RowActionMenu.items(context: scratch)).contains(.copyBranch))

        let main = RowActionMenu.Context(pathIsEmpty: false, status: .main, branch: "main")
        #expect(kinds(RowActionMenu.items(context: main)).contains(.copyBranch))
    }
}

// MARK: - Pin/unpin

@Suite("RowActionMenu — pin/unpin")
struct RowActionMenuPinTests {
    @Test("an unpinned regular row offers Pin, not Unpin")
    func offersPin() {
        let items = RowActionMenu.items(context: .init(isPinned: false))
        #expect(items.contains(.action(.init(kind: .pin, title: RowActionMenu.pinLabel))))
        #expect(!kinds(items).contains(.unpin))
    }

    @Test("a pinned regular row offers Unpin, not Pin")
    func offersUnpin() {
        let items = RowActionMenu.items(context: .init(isPinned: true))
        #expect(items.contains(.action(.init(kind: .unpin, title: RowActionMenu.unpinLabel))))
        #expect(!kinds(items).contains(.pin))
    }

    @Test("an unpinned scratch row offers Pin")
    func scratchOffersPin() {
        let items = RowActionMenu.items(context: .init(isScratch: true, isPinned: false))
        #expect(kinds(items).contains(.pin))
    }

    @Test("the Watch Desk offers neither Pin nor Unpin")
    func deskOffersNeither() {
        // The desk is a scratch row, so this must be suppressed in the scratch
        // branch — not only the regular one.
        let items = RowActionMenu.items(
            context: .init(isScratch: true, isPinned: false, isNightwatchDesk: true))
        #expect(!kinds(items).contains(.pin))
        #expect(!kinds(items).contains(.unpin))
    }
}

// MARK: - The real call site

/// Every suite above hands `RowActionMenu.items` a hand-built `Context`, which
/// says what the pure function does with the inputs it is given and nothing at
/// all about what the app actually gives it. These tests go through
/// `RowActionMenuActions.context()` — the ONE place in `Sources/` that builds a
/// `Context` — so a field the production call site never populates fails here
/// rather than passing everywhere.
///
/// The gap this closes was live: `isGone` defaulted to `false` at the call
/// site, so the `gone` exemption's whole surface half was unreachable in the
/// running app while three tests over a hand-built `Context` stayed green.
@MainActor
@Suite("RowActionMenu — built from live AppState")
struct RowActionMenuCallSiteTests {

    private func withState(_ body: (AppState) -> Void) {
        let defaultsSuite = TestDefaultsSuite("RowActionMenuCallSite")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        body(AppState(userDefaults: defaults))
    }

    private func remoteWorktree(sessionID: String = "s1") -> Worktree {
        Worktree(
            repoID: UUID(), name: "acme-lane", displayName: "acme lane",
            branch: "acme-branch", path: "remote://fake/\(sessionID)",
            tmuxServer: "unused",
            location: .remote(provider: "fake", sessionID: sessionID))
    }

    private func session(_ sessionID: String, gone: Bool) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: "fake",
            payload: RemoteSessionPayload(id: sessionID, state: .running),
            gone: gone, dismissed: false, lastSeen: Date())
    }

    private func provider(capabilities: [String]) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: "fake", exec: "/nonexistent"),
            describe: ProviderDescribe(
                contractVersions: [1], name: "fake", capabilities: capabilities),
            health: .ok, errorMessage: nil,
            remediationLabel: nil, remediationCommand: nil)
    }

    private func actions(_ state: AppState, _ worktree: Worktree) -> RowActionMenuActions {
        RowActionMenuActions(appState: state, worktree: worktree, onRename: {})
    }

    @Test("the built context carries the mirror's `gone` flag")
    func contextCarriesGone() {
        withState { state in
            let worktree = remoteWorktree()
            state.remoteProviders = [provider(capabilities: ["stop"])]
            state.remoteSessions = [session("s1", gone: true)]
            #expect(actions(state, worktree).context().isGone)
        }
    }

    /// The bug the `gone` exemption's menu half exists to prevent, asserted
    /// end-to-end from `AppState`: the daemon WILL archive this lane through
    /// `.rowOnlyGone`, so the menu must not be the thing that blocks it.
    @Test("a gone lane on a provider that cannot archive still offers Archive")
    func goneLaneOffersArchiveThroughTheCallSite() {
        withState { state in
            let worktree = remoteWorktree()
            state.remoteProviders = [provider(capabilities: ["stop"])]
            state.remoteSessions = [session("s1", gone: true)]
            let archive = actions(state, worktree).items()
                .compactMap(\.action).first { $0.kind == .archive }
            #expect(archive?.title == "Archive")
            #expect(archive?.isEnabled == true)
        }
    }

    /// The discriminating half: the same wiring with the mirror reporting the
    /// session still enumerated must stay disabled, so a call site that
    /// hardcoded `isGone: true` could not pass either.
    @Test("a lane the provider still enumerates stays disabled through the call site")
    func enumeratedLaneStaysDisabledThroughTheCallSite() {
        withState { state in
            let worktree = remoteWorktree()
            state.remoteProviders = [provider(capabilities: ["stop"])]
            state.remoteSessions = [session("s1", gone: false)]
            let built = actions(state, worktree).context()
            #expect(!built.isGone)
            let archive = actions(state, worktree).items()
                .compactMap(\.action).first { $0.kind == .archive }
            #expect(archive?.title == RowActionMenu.archiveProviderCannotArchiveLabel)
            #expect(archive?.isEnabled == false)
        }
    }

    /// A local row has no mirror entry to consult and must read `false`
    /// regardless of what the mirror holds for some other session.
    @Test("a local row is never gone")
    func localRowIsNeverGone() {
        withState { state in
            let local = Worktree(
                repoID: UUID(), name: "local", displayName: "local",
                branch: "b", path: "/tmp/x", tmuxServer: "t")
            state.remoteSessions = [session("s1", gone: true)]
            #expect(!actions(state, local).context().isGone)
        }
    }

    /// The other two remote fields the call site populates, pinned here for the
    /// same reason `isGone` is: nothing else proves they are wired.
    @Test("the built context carries the row's provider and its capabilities")
    func contextCarriesProviderAndCapabilities() {
        withState { state in
            let worktree = remoteWorktree()
            state.remoteProviders = [provider(capabilities: ["archive", "stop"])]
            state.remoteSessions = [session("s1", gone: false)]
            let built = actions(state, worktree).context()
            #expect(built.provider == "fake")
            #expect(built.providerCapabilities == ["archive", "stop"])
            #expect(built.location == .remote(provider: "fake", sessionID: "s1"))
        }
    }
}
