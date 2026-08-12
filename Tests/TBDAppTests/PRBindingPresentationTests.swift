import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

@Suite("PR binding presentation")
struct PRBindingPresentationTests {

    private func binding(_ n: Int, _ state: PRMergeableState) -> PRBinding {
        let url = "https://github.com/acme/acme-prod/pull/\(n)"
        return PRBinding(worktreeID: UUID(), owner: "acme", repo: "acme-prod",
                         number: n, url: url,
                         status: PRStatus(number: n, url: url, state: state),
                         source: .hook)
    }

    private func binding(_ n: Int, url: String) -> PRBinding {
        PRBinding(worktreeID: UUID(), owner: "acme", repo: "acme-prod",
                  number: n, url: url,
                  status: PRStatus(number: n, url: url, state: .mergeable),
                  source: .hook)
    }

    // MARK: - The `+N` overflow chip's wording

    /// The chip is labelled by how many PRs did NOT fit, but its menu lists
    /// EVERY binding — deliberately, so the status bar and the toolbar dropdown
    /// cannot describe one worktree differently. The wording has to match the
    /// menu, not the label.
    @Test("the overflow chip's wording describes the full list it opens")
    func overflowWordingNamesTheWholeList() {
        let tooltip = PRBindingPresentation.overflowChipTooltip(total: 7, overflow: 3)
        #expect(tooltip.contains("all 7 pull requests"))
        #expect(tooltip.contains("3 not shown here"))
        // The old wording claimed the menu held only the remainder.
        #expect(tooltip != "3 more pull requests")

        let label = PRBindingPresentation.overflowChipAccessibilityLabel(total: 7, overflow: 3)
        #expect(label.contains("all 7 pull requests"))
        #expect(label != "3 more pull requests")
    }

    @Test("the overflow wording singularises a one-PR total")
    func overflowWordingSingular() {
        #expect(PRBindingPresentation.overflowChipTooltip(total: 1, overflow: 1)
                    .contains("all 1 pull request ("))
    }

    // MARK: - The toolbar's primary-action branch

    /// A lone binding with an unparseable URL used to fall into the several-PR
    /// shape while the menu still gated its rows on `count > 1` — the label read
    /// `#412` and nothing anywhere offered that PR. It now has no primary
    /// action, which routes it through the menu shape and drops the "Open"
    /// promise from the tooltip.
    @Test("one binding with a usable url gets a primary action")
    func primaryActionForOneUsableURL() {
        let bindings = [binding(412, url: "https://github.com/acme/acme-prod/pull/412")]
        #expect(ContentView.prPrimaryActionURL(bindings)?.absoluteString
                    == "https://github.com/acme/acme-prod/pull/412")
        #expect(ContentView.prSplitButtonHelp(
            bindings: bindings, armed: false, hibernateArmed: false, blocked: false)
            .hasPrefix("Open PR #412"))
    }

    /// `URL(string:)` is lenient — it percent-encodes almost anything — so the
    /// reachable failure is an EMPTY url string, which is what a legacy
    /// `PRStatus` lifted by `effectiveBindings` carries when the daemon never
    /// recorded one.
    @Test("one binding with an unparseable url gets no primary action and no Open promise")
    func noPrimaryActionForUnparseableURL() {
        let bindings = [binding(412, url: "")]
        #expect(ContentView.prPrimaryActionURL(bindings) == nil)
        let help = ContentView.prSplitButtonHelp(
            bindings: bindings, armed: false, hibernateArmed: false, blocked: false)
        #expect(help.hasPrefix("PR #412"))
        #expect(!help.contains("Open"))
        // It still renders as one PR — the fix changes the click target, not
        // the label.
        #expect(PRBindingPresentation.buttonLabel(bindings) == "#412")
        // And the menu shape it now takes lists that PR as a row.
        #expect(PRBindingPresentation.menuRows(bindings).map(\.number) == [412])
    }

    @Test("several bindings never get a primary action")
    func noPrimaryActionForSeveral() {
        let bindings = [binding(412, url: "https://github.com/acme/acme-prod/pull/412"),
                        binding(413, url: "https://github.com/acme/acme-prod/pull/413")]
        #expect(ContentView.prPrimaryActionURL(bindings) == nil)
    }

    @Test("no bindings renders no control")
    func zero() {
        #expect(PRBindingPresentation.buttonLabel([]) == nil)
        #expect(PRBindingPresentation.iconBinding([]) == nil)
    }

    @Test("one binding shows its number, as today")
    func one() {
        #expect(PRBindingPresentation.buttonLabel([binding(412, .mergeable)]) == "#412")
    }

    @Test("several bindings show a count")
    func many() {
        let label = PRBindingPresentation.buttonLabel(
            [binding(412, .mergeable), binding(413, .checksFailed), binding(414, .draft)])
        #expect(label == "3 PRs")
    }

    @Test("the icon follows the worst state at any count")
    func iconFollowsWorst() {
        let bindings = [binding(412, .mergeable), binding(413, .checksFailed),
                        binding(414, .draft)]
        #expect(PRBindingPresentation.iconBinding(bindings)?.number == 413)
        #expect(PRBindingPresentation.iconBinding([binding(9, .draft)])?.number == 9)
    }

    @Test("status-bar chips cap and report overflow")
    func chipCap() {
        let bindings = (1...7).map { binding($0, .mergeable) }
        let result = PRBindingPresentation.statusBarChips(bindings, limit: 4)
        #expect(result.chips.count == 4)
        #expect(result.overflow == 3)
        #expect(result.chips.map(\.number) == [1, 2, 3, 4])   // bind order
    }

    @Test("no overflow when within the cap")
    func chipNoOverflow() {
        let result = PRBindingPresentation.statusBarChips(
            [binding(1, .mergeable), binding(2, .draft)], limit: 4)
        #expect(result.chips.count == 2)
        #expect(result.overflow == 0)
    }

    @Test("menu rows keep bind order, not severity order")
    func menuOrder() {
        let bindings = [binding(30, .mergeable), binding(10, .checksFailed),
                        binding(20, .draft)]
        #expect(PRBindingPresentation.menuRows(bindings).map(\.number) == [30, 10, 20])
    }

    @Test("a menu row carries number, reason and branch")
    func menuRowContent() {
        var b = binding(412, .checksFailed)
        b = PRBinding(id: b.id, worktreeID: b.worktreeID, host: b.host, owner: b.owner,
                      repo: b.repo, number: b.number, url: b.url,
                      headBranch: "fix-login-timeout", baseRef: "main",
                      status: b.status, source: b.source, detached: false, boundAt: b.boundAt)
        let row = PRBindingPresentation.menuRows([b])[0]
        #expect(row.number == 412)
        #expect(row.title.contains("#412"))
        #expect(row.title.contains("Checks failing"))
        #expect(row.title.contains("fix-login-timeout"))
    }
}
