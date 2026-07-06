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

// MARK: - Regular worktree branch

@Suite("RowActionMenu — regular worktree")
struct RowActionMenuRegularTests {
    @Test func baseOrderMatchesLegacyContextMenu() {
        // No Claude sessions, has repo, non-empty branch: rename → nested →
        // fromBranch → archive → divider → finder → copy.
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "tbd/x")
        let items = RowActionMenu.items(context: ctx)
        #expect(kinds(items) == [
            .rename,
            .createNestedWorktree,
            .newWorktreeFromBranch,
            .archive,
            .openInFinder,
            .copyPath,
        ])
        // Divider sits between archive and Open in Finder.
        #expect(items.contains(.divider))
    }

    @Test func suspendShownOnlyWhenUnsuspendedClaudePresent() {
        let ctx = RowActionMenu.Context(hasUnsuspendedClaude: true, hasRepoID: true, branch: "b")
        #expect(kinds(RowActionMenu.items(context: ctx)).contains(.suspendClaude))
        #expect(!kinds(RowActionMenu.items(context: ctx)).contains(.resumeClaude))
    }

    @Test func resumeShownOnlyWhenSuspendedClaudePresent() {
        let ctx = RowActionMenu.Context(hasSuspendedClaude: true, hasRepoID: true, branch: "b")
        #expect(kinds(RowActionMenu.items(context: ctx)).contains(.resumeClaude))
        #expect(!kinds(RowActionMenu.items(context: ctx)).contains(.suspendClaude))
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

    @Test func archiveDisabledWithHelpAndDestructiveWhenChildrenActive() {
        let ctx = RowActionMenu.Context(hasActiveChildren: true, hasRepoID: true, branch: "b")
        let archive = RowActionMenu.items(context: ctx)
            .compactMap(\.action).first { $0.kind == .archive }
        #expect(archive?.isEnabled == false)
        #expect(archive?.role == .destructive)
        #expect(archive?.disabledHelp == RowActionMenu.archiveNeedsChildrenGoneHelp)
    }

    @Test func archiveEnabledWithNoHelpWhenNoChildren() {
        let ctx = RowActionMenu.Context(hasActiveChildren: false, hasRepoID: true, branch: "b")
        let archive = RowActionMenu.items(context: ctx)
            .compactMap(\.action).first { $0.kind == .archive }
        #expect(archive?.isEnabled == true)
        #expect(archive?.disabledHelp == nil)
    }
}

// MARK: - Scratch branch

@Suite("RowActionMenu — scratch")
struct RowActionMenuScratchTests {
    @Test func scratchOrderWithPromoteHint() {
        let ctx = RowActionMenu.Context(isScratch: true, isPromoted: false)
        let items = RowActionMenu.items(context: ctx)
        #expect(kinds(items) == [
            .newClaudeTerminal,
            .newCodexTerminal,
            .newShellTerminal,
            .rename,
            .openInFinder,
            .copyPath,
            .archiveScratch,
            .deleteScratch,
        ])
        // Promote hint caption present when not yet promoted.
        #expect(items.contains(.caption(RowActionMenu.promoteHint)))
    }

    @Test func promoteHintOmittedWhenAlreadyPromoted() {
        let ctx = RowActionMenu.Context(isScratch: true, isPromoted: true)
        #expect(!RowActionMenu.items(context: ctx).contains(.caption(RowActionMenu.promoteHint)))
    }

    @Test func scratchWithClaudeSessionGetsForkParityOnRightClickOnly() {
        // Scratch spaces host Claude sessions too: right-click carries the fork
        // entries (after the New-Terminal trio); the "…" action block does not
        // (its account section renders fork instead).
        let s = session("Claude 1")
        let ctx = RowActionMenu.Context(isScratch: true, claudeSessions: [s])
        let rightClick = kinds(RowActionMenu.items(context: ctx, includeSessionForks: true))
        #expect(rightClick.contains(.forkSession(terminalID: s.terminalID,
                                                 profileID: s.profileID)))
        #expect(rightClick[3] == .forkSession(terminalID: s.terminalID,
                                              profileID: s.profileID))
        let ellipsis = kinds(RowActionMenu.items(context: ctx, includeSessionForks: false))
        #expect(!ellipsis.contains { if case .forkSession = $0 { return true }; return false })
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
        let forks = RowActionMenu.sessionForkActions(context: ctx)
        #expect(forks.count == 1)
        if case let .forkSession(_, profileID) = forks[0].kind {
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

// MARK: - Shared-list invariant across surfaces

@Suite("RowActionMenu — shared surfaces")
struct RowActionMenuSurfaceInvariantTests {
    /// The "…" action block (includeSessionForks: false) is the right-click list
    /// with the per-session fork entries removed — everything else identical.
    @Test func ellipsisActionBlockOmitsForksButOtherwiseMatchesRightClick() {
        let s = session("Claude 1")
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "b", claudeSessions: [s])

        let rightClick = RowActionMenu.items(context: ctx, includeSessionForks: true)
        let ellipsis = RowActionMenu.items(context: ctx, includeSessionForks: false)

        // Right-click includes the fork; the "…" action block does not.
        #expect(kinds(rightClick).contains { if case .forkSession = $0 { return true }; return false })
        #expect(!kinds(ellipsis).contains { if case .forkSession = $0 { return true }; return false })

        // Removing the fork entries from the right-click list yields the "…" list.
        let rightClickSansForks = rightClick.filter {
            if case let .action(a) = $0, case .forkSession = a.kind { return false }
            return true
        }
        #expect(rightClickSansForks == ellipsis)
    }

    /// The account section is contributed by `RowAccountMenu`, never
    /// `RowActionMenu`: no action item is an account/switch entry.
    @Test func actionItemsContainNoAccountOrSwitchEntries() {
        let s = session("Claude 1")
        let ctx = RowActionMenu.Context(hasRepoID: true, branch: "b", claudeSessions: [s])
        for item in RowActionMenu.items(context: ctx) {
            if case let .action(action) = item {
                // No switch-account kinds exist in RowActionMenu.Kind at all;
                // assert titles don't leak the account section's copy either.
                #expect(action.title != RowAccountMenu.switchAccountLabel)
            }
        }
    }
}
