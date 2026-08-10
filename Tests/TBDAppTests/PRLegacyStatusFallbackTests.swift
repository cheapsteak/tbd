import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

/// Tier 1. The no-bindings-but-a-status fallback.
///
/// Multi-PR moved every PR surface off `AppState.prStatuses` onto
/// `AppState.prBindings`. That silently dropped the control for a worktree that
/// HAS a persisted status but NO bindings — a persistent state, not just a
/// startup blip: with `gh` unavailable or unauthenticated the daemon still
/// hydrates `Worktree.prStatus`, but no bind can resolve a repo, so the
/// bindings table stays empty forever. `effectiveBindings` is the one place
/// that decides, and every surface reads it through
/// `AppState.effectivePRBindings`, so the toolbar and the sidebar cannot
/// disagree.
@Suite("PR legacy-status fallback")
struct PRLegacyStatusFallbackTests {

    private func status(_ n: Int, _ state: PRMergeableState = .mergeable) -> PRStatus {
        PRStatus(number: n, url: "https://github.com/acme/acme-prod/pull/\(n)", state: state)
    }

    private func binding(_ n: Int, _ state: PRMergeableState, worktreeID: UUID) -> PRBinding {
        let url = "https://github.com/acme/acme-prod/pull/\(n)"
        return PRBinding(worktreeID: worktreeID, owner: "acme", repo: "acme-prod",
                         number: n, url: url,
                         status: PRStatus(number: n, url: url, state: state),
                         source: .hook)
    }

    @Test("one binding and no legacy status: the binding drives the control")
    func bindingOnly() {
        let wt = UUID()
        let effective = PRBindingPresentation.effectiveBindings(
            [binding(412, .checksFailed, worktreeID: wt)], legacyStatus: nil, worktreeID: wt)
        #expect(effective.map(\.number) == [412])
        #expect(PRBindingPresentation.buttonLabel(effective) == "#412")
        #expect(PRBindingPresentation.iconBinding(effective)?.status?.state == .checksFailed)
    }

    @Test("no bindings and a legacy status: the legacy status drives the control")
    func legacyOnly() {
        let wt = UUID()
        let effective = PRBindingPresentation.effectiveBindings(
            [], legacyStatus: status(99, .changesRequested), worktreeID: wt)
        #expect(effective.count == 1)
        #expect(effective[0].number == 99)
        #expect(effective[0].url == "https://github.com/acme/acme-prod/pull/99")
        #expect(effective[0].status?.state == .changesRequested)
        #expect(effective[0].detached == false)
        // The label, the icon selection and the click target are all the
        // pre-multi-PR ones — nothing about the fallback is a different shape.
        #expect(PRBindingPresentation.buttonLabel(effective) == "#99")
        #expect(PRBindingPresentation.iconBinding(effective)?.number == 99)
        #expect(ContentView.prSplitButtonHelp(
            bindings: effective, armed: false, hibernateArmed: false, blocked: false)
            .hasPrefix("Open PR #99"))
    }

    /// The whole value has to compare equal across evaluations, not just the
    /// id: it feeds `ForEach` identity, the split button's `.id` key, and
    /// SwiftUI's view-value diffing. The initializer's `UUID()` / `Date()`
    /// defaults would churn all three on every render.
    @Test("the synthetic binding is value-stable, so ForEach and .id keys do not churn")
    func legacyIDStable() {
        let wt = UUID()
        let first = PRBindingPresentation.effectiveBindings([], legacyStatus: status(99), worktreeID: wt)
        let second = PRBindingPresentation.effectiveBindings([], legacyStatus: status(99), worktreeID: wt)
        #expect(first[0].id == second[0].id)
        #expect(first == second)
    }

    @Test("both present: bindings win")
    func bindingsWin() {
        let wt = UUID()
        let effective = PRBindingPresentation.effectiveBindings(
            [binding(412, .mergeable, worktreeID: wt), binding(413, .draft, worktreeID: wt)],
            legacyStatus: status(99),
            worktreeID: wt
        )
        #expect(effective.map(\.number) == [412, 413])
        #expect(PRBindingPresentation.buttonLabel(effective) == "2 PRs")
    }

    @Test("neither: no control")
    func neither() {
        let effective = PRBindingPresentation.effectiveBindings([], legacyStatus: nil, worktreeID: UUID())
        #expect(effective.isEmpty)
        #expect(PRBindingPresentation.buttonLabel(effective) == nil)
        #expect(PRBindingPresentation.iconBinding(effective) == nil)
    }

    /// The accessor every surface actually calls. Constructs
    /// `AppState(userDefaults:)` against a throwaway suite: TBDApp is an
    /// unbundled SPM executable, so `UserDefaults.standard` is the running
    /// developer's real `TBDApp.plist`.
    @MainActor
    private func withAppState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.PRLegacyFallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    @MainActor
    @Test("AppState.effectivePRBindings applies the same precedence")
    func appStatePrecedence() {
        withAppState { state in
            let wt = UUID()

            // Neither → nothing to render.
            #expect(state.effectivePRBindings(worktreeID: wt).isEmpty)

            // Legacy status only → one synthetic binding.
            state.prStatuses[wt] = status(99)
            #expect(state.effectivePRBindings(worktreeID: wt).map(\.number) == [99])

            // Bindings arrive → they win, the legacy status is ignored.
            state.prBindings[wt] = [binding(412, .mergeable, worktreeID: wt)]
            #expect(state.effectivePRBindings(worktreeID: wt).map(\.number) == [412])

            // A different worktree with neither is unaffected.
            #expect(state.effectivePRBindings(worktreeID: UUID()).isEmpty)
        }
    }
}
