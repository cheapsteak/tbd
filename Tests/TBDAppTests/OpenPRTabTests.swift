import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// Tier 1. The rule the TOOLBAR's PR surfaces share: clicking a PR opens an
/// in-app webview tab, and clicking the SAME PR again focuses the tab that is
/// already there instead of piling up duplicates.
///
/// `AppState.openPR` is the single helper behind the toolbar split button and
/// its multi-PR dropdown rows, so asserting it here covers both. The status-bar
/// chips and the sidebar row indicator are deliberately NOT callers — they open
/// the default browser directly, which is the user's stated preference for those
/// two surfaces. Every case passes `inBrowser: false` explicitly — the production
/// default reads `NSEvent.modifierFlags` at the call site, which a test must not
/// depend on (and whose `true` arm would launch a real browser).
///
/// Each test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite: TBDApp ships as an unbundled SPM executable, so `UserDefaults.standard`
/// is the running developer's real `TBDApp.plist`.
@MainActor
@Suite("Open PR in tab")
struct OpenPRTabTests {

    private func withAppState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.OpenPRTab.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func prURL(_ number: Int) -> URL {
        URL(string: "https://github.com/acme/acme-prod/pull/\(number)")!
    }

    /// The URL a tab is showing, or nil when it is not a webview tab.
    private func webviewURL(_ tab: TBDShared.Tab) -> URL? {
        if case .webview(_, let url) = tab.content { return url }
        return nil
    }

    @Test("no tab for that PR yet: one is created and becomes active")
    func createsAndFocusesNewTab() {
        withAppState { state in
            let worktreeID = UUID()
            state.openPR(url: prURL(412), number: 412, worktreeID: worktreeID, inBrowser: false)

            let tabs = state.tabs[worktreeID] ?? []
            #expect(tabs.count == 1)
            #expect(webviewURL(tabs[0]) == prURL(412))
            #expect(tabs[0].label == "PR #412")
            #expect(state.activeTabIndices[worktreeID] == 0)
        }
    }

    @Test("a tab already on that URL is focused, and nothing new is created")
    func reusesExistingTab() {
        withAppState { state in
            let worktreeID = UUID()
            // A non-PR tab in front, so "focused" is a real assertion rather
            // than index 0 by default.
            state.tabs[worktreeID] = [
                TBDShared.Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: nil)
            ]
            state.openPR(url: prURL(412), number: 412, worktreeID: worktreeID, inBrowser: false)
            let afterFirst = state.tabs[worktreeID] ?? []
            #expect(afterFirst.count == 2)
            let prTabID = afterFirst[1].id

            // Move the selection away, then click the same PR again.
            state.activeTabIndices[worktreeID] = 0
            state.openPR(url: prURL(412), number: 412, worktreeID: worktreeID, inBrowser: false)

            let tabs = state.tabs[worktreeID] ?? []
            #expect(tabs.count == 2)
            #expect(tabs[1].id == prTabID)
            #expect(state.activeTabIndices[worktreeID] == 1)
        }
    }

    @Test("a different PR's URL gets its own second tab")
    func differentURLCreatesSecondTab() {
        withAppState { state in
            let worktreeID = UUID()
            state.openPR(url: prURL(412), number: 412, worktreeID: worktreeID, inBrowser: false)
            state.openPR(url: prURL(999), number: 999, worktreeID: worktreeID, inBrowser: false)

            let tabs = state.tabs[worktreeID] ?? []
            #expect(tabs.count == 2)
            #expect(tabs.compactMap(webviewURL) == [prURL(412), prURL(999)])
            #expect(tabs.map(\.label) == ["PR #412", "PR #999"])
            #expect(state.activeTabIndices[worktreeID] == 1)
        }
    }

    @Test("another worktree's identical PR tab is not reused")
    func reuseIsScopedToTheWorktree() {
        withAppState { state in
            let one = UUID()
            let two = UUID()
            state.openPR(url: prURL(412), number: 412, worktreeID: one, inBrowser: false)
            state.openPR(url: prURL(412), number: 412, worktreeID: two, inBrowser: false)

            #expect(state.tabs[one]?.count == 1)
            #expect(state.tabs[two]?.count == 1)
        }
    }

    // MARK: - The pure decision behind the reuse rule

    @Test("webviewTabIndex reports the tab to focus, or nil to create one")
    func webviewTabIndexDecision() {
        let terminal = TBDShared.Tab(id: UUID(), content: .terminal(terminalID: UUID()), label: nil)
        let pr412 = TBDShared.Tab(
            id: UUID(), content: .webview(id: UUID(), url: prURL(412)), label: "PR #412")

        #expect(AppState.webviewTabIndex(in: [], showing: prURL(412)) == nil)
        #expect(AppState.webviewTabIndex(in: [terminal], showing: prURL(412)) == nil)
        #expect(AppState.webviewTabIndex(in: [terminal, pr412], showing: prURL(412)) == 1)
        #expect(AppState.webviewTabIndex(in: [terminal, pr412], showing: prURL(999)) == nil)
    }
}
