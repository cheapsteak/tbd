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
        detached: Bool = false
    ) -> PRBinding {
        let prURL = url ?? "https://github.com/acme/acme-prod/pull/\(number)"
        return PRBinding(
            worktreeID: worktreeID,
            owner: "acme",
            repo: "acme-prod",
            number: number,
            url: prURL,
            status: PRStatus(number: number, url: prURL, state: state),
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

    @Test("PRBinding field-count tripwire for prSplitButtonID")
    func prBindingFieldCountTripwire() {
        // If this fails, a PRBinding field was added. prSplitButtonID
        // hand-enumerates the fields the split button renders per binding
        // (number, state, url, mergeQueuePosition, detached), so a new field is
        // otherwise silently unkeyed: decide whether the split button renders
        // it and update prSplitButtonID (and this count) accordingly.
        // 13 = id, worktreeID, host, owner, repo, number, url, headBranch,
        // baseRef, status, source, detached, boundAt.
        let value = Self.binding(1, .mergeable, worktreeID: UUID())
        #expect(Mirror(reflecting: value).children.count == 13)
    }
}
