import Foundation
import SwiftUI
import Testing

@testable import TBDApp
@testable import TBDShared

/// The PR split button's `.id` key under multiple bindings.
///
/// AppKit materializes the split button's NSMenu and label ONCE, so anything
/// the menu or label renders that is NOT folded into this key can change in
/// SwiftUI state and never reach the built `NSMenuToolbarItem`. With several
/// bound PRs the menu lists one row per binding, so EVERY binding's rendered
/// fields have to be in the key — not just the worst one that drives the icon.
@Suite("PRSplitButtonID")
@MainActor
struct PRSplitButtonIDTests {
    private static func binding(
        _ number: Int,
        _ state: PRMergeableState,
        worktreeID: UUID,
        url: String? = nil,
        detached: Bool = false,
        reason: String? = nil,
        headBranch: String? = nil
    ) -> PRBinding {
        let prURL = url ?? "https://github.com/acme/acme-prod/pull/\(number)"
        return PRBinding(
            worktreeID: worktreeID,
            owner: "acme",
            repo: "acme-prod",
            number: number,
            url: prURL,
            headBranch: headBranch,
            status: PRStatus(number: number, url: prURL, state: state, reason: reason),
            source: .hook,
            detached: detached
        )
    }

    private static func key(
        worktreeID: UUID,
        worktreeFound: Bool = true,
        armed: Bool = false,
        hibernateArmed: Bool = false,
        blocked: Bool = false,
        bindings: [PRBinding],
        colorScheme: ColorScheme = .light
    ) -> String {
        PRButtonLabel.prSplitButtonID(
            worktreeID: worktreeID,
            worktreeFound: worktreeFound,
            armed: armed,
            hibernateArmed: hibernateArmed,
            blocked: blocked,
            bindings: bindings,
            colorScheme: colorScheme
        )
    }

    @Test("the split-button id changes when any bound PR's state changes")
    func idCoversEveryBinding() {
        let wt = UUID()
        let a = Self.binding(412, .mergeable, worktreeID: wt)
        let b = Self.binding(413, .draft, worktreeID: wt)
        let bChanged = Self.binding(413, .checksFailed, worktreeID: wt)

        let base = Self.key(worktreeID: wt, bindings: [a, b])
        let changed = Self.key(worktreeID: wt, bindings: [a, bChanged])
        #expect(base != changed)
    }

    @Test("the id changes when a PR is added or removed")
    func idCoversCount() {
        let wt = UUID()
        let a = Self.binding(412, .mergeable, worktreeID: wt)
        let b = Self.binding(413, .draft, worktreeID: wt)
        let one = Self.key(worktreeID: wt, bindings: [a])
        let two = Self.key(worktreeID: wt, bindings: [a, b])
        #expect(one != two)
    }

    @Test("the id is stable for identical inputs")
    func idStable() {
        let wt = UUID()
        let bindings = [Self.binding(412, .mergeable, worktreeID: wt)]
        let first = Self.key(worktreeID: wt, armed: true, bindings: bindings, colorScheme: .dark)
        let second = Self.key(worktreeID: wt, armed: true, bindings: bindings, colorScheme: .dark)
        #expect(first == second)
    }

    @Test("the id changes when a non-worst binding's url or number changes")
    func idCoversUrlAndNumber() {
        let wt = UUID()
        // The FIRST binding is the worst one (checksFailed), so it owns the
        // icon; the second only ever appears as a menu row. A menu row change
        // must still rebuild the item.
        let worst = Self.binding(412, .checksFailed, worktreeID: wt)
        let row = Self.binding(413, .mergeable, worktreeID: wt)
        let renumbered = Self.binding(414, .mergeable, worktreeID: wt)
        let repointed = Self.binding(
            413, .mergeable, worktreeID: wt,
            url: "https://github.com/acme/acme-prod/pull/413?tab=files")

        let base = Self.key(worktreeID: wt, bindings: [worst, row])
        #expect(base != Self.key(worktreeID: wt, bindings: [worst, renumbered]))
        #expect(base != Self.key(worktreeID: wt, bindings: [worst, repointed]))
    }

    @Test("the id changes when a binding is tombstoned")
    func idCoversDetached() {
        let wt = UUID()
        let live = Self.binding(412, .mergeable, worktreeID: wt)
        let tombstoned = Self.binding(412, .mergeable, worktreeID: wt, detached: true)
        #expect(Self.key(worktreeID: wt, bindings: [live])
                != Self.key(worktreeID: wt, bindings: [tombstoned]))
    }

    @Test("the id changes when only a status REASON changes")
    func idCoversReason() {
        let wt = UUID()
        // `menuRows` renders `status.reason ?? state.displayReason` into every
        // row title, so "1 check failing" → "3 checks failing" under an
        // unchanged `.checksFailed` must still recreate the materialized menu.
        // Two bindings, because that is when rows are rendered at all.
        let other = Self.binding(413, .mergeable, worktreeID: wt)
        let one = Self.binding(412, .checksFailed, worktreeID: wt, reason: "1 check failing")
        let three = Self.binding(412, .checksFailed, worktreeID: wt, reason: "3 checks failing")
        #expect(Self.key(worktreeID: wt, bindings: [one, other])
                != Self.key(worktreeID: wt, bindings: [three, other]))
    }

    @Test("the id changes when only the head branch changes")
    func idCoversHeadBranch() {
        let wt = UUID()
        // `menuRows` appends `headBranch` to the row title, and the daemon now
        // populates it — so it is neither always-nil nor immutable.
        let other = Self.binding(413, .mergeable, worktreeID: wt)
        let before = Self.binding(412, .mergeable, worktreeID: wt, headBranch: "fix-login-timeout")
        let after = Self.binding(412, .mergeable, worktreeID: wt, headBranch: "fix-login-timeout-2")
        #expect(Self.key(worktreeID: wt, bindings: [before, other])
                != Self.key(worktreeID: wt, bindings: [after, other]))
        // nil → set is a change too (the row gains a branch clause).
        let unset = Self.binding(412, .mergeable, worktreeID: wt, headBranch: nil)
        #expect(Self.key(worktreeID: wt, bindings: [unset, other])
                != Self.key(worktreeID: wt, bindings: [before, other]))
    }

    @Test("PRBinding field-count tripwire for prSplitButtonID")
    func prBindingFieldCountTripwire() {
        // If this fails, a PRBinding field was added. prSplitButtonID
        // hand-enumerates the fields the split button renders per binding
        // (number, state, url, mergeQueuePosition, detached, status reason and
        // headBranch), so a new field is otherwise silently unkeyed: decide
        // whether the split button renders it and update prSplitButtonID (and
        // this count) accordingly.
        // 13 = id, worktreeID, host, owner, repo, number, url, headBranch,
        // baseRef, status, source, detached, boundAt.
        let value = Self.binding(1, .mergeable, worktreeID: UUID())
        #expect(Mirror(reflecting: value).children.count == 13)
    }
}
