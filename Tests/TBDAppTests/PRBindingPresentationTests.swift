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

    // MARK: - Per-binding wording versus aggregate wording

    private func gitLabBinding(_ n: Int) -> PRBinding {
        let url = "https://git.acme.example/acme/platform/api-gateway/-/merge_requests/\(n)"
        return PRBinding(worktreeID: UUID(), host: "git.acme.example",
                         owner: "acme/platform", repo: "api-gateway",
                         number: n, url: url,
                         status: PRStatus(number: n, url: url, state: .mergeable),
                         source: .hook)
    }

    @Test("a lone GitLab binding is described in GitLab's own syntax")
    func gitLabSplitButtonHelp() {
        let help = ContentView.prSplitButtonHelp(
            bindings: [gitLabBinding(412)], armed: false, hibernateArmed: false, blocked: false)
        #expect(help.hasPrefix("Open MR !412"))
        #expect(!help.contains("PR #"))
    }

    /// The reason aggregates stay neutral: one worktree can hold a GitHub PR
    /// and a GitLab MR at once, and no single vocabulary is true of both.
    @Test("a worktree spanning both forges keeps neutral aggregate wording")
    func mixedForgeAggregateStaysNeutral() {
        let help = ContentView.prSplitButtonHelp(
            bindings: [binding(412, .mergeable), gitLabBinding(7)],
            armed: false, hibernateArmed: false, blocked: false)
        #expect(help.hasPrefix("2 pull requests"))
        #expect(!help.contains("MR !"))
        // And the count label, which the same set feeds.
        #expect(PRBindingPresentation.buttonLabel(
            [binding(412, .mergeable), gitLabBinding(7)]) == "2 PRs")

        // The `+N` chip counts a set too, so its wording keeps the neutral noun
        // for the same reason — it has no single binding to take a forge from,
        // and its signature carries none.
        let tooltip = PRBindingPresentation.overflowChipTooltip(total: 2, overflow: 1)
        let announced = PRBindingPresentation.overflowChipAccessibilityLabel(
            total: 2, overflow: 1)
        for aggregate in [tooltip, announced] {
            #expect(aggregate.contains("2 pull requests"))
            #expect(!aggregate.contains(Forge.gitlab.refNoun))
        }
    }

    /// A menu row describes ONE binding, so it takes the per-binding rule the
    /// aggregates above are exempt from — and each row in one menu can take a
    /// different forge. A bare `#7` named a merge request in GitHub's syntax;
    /// `#7` is an issue reference on GitLab, whose syntax for this row's
    /// subject is `!7`.
    @Test("each menu row names its own binding's forge")
    func menuRowsSpeakPerBindingForge() {
        let rows = PRBindingPresentation.menuRows(
            [binding(412, .mergeable), gitLabBinding(7)])
        #expect(rows.map(\.title) == ["PR #412  Ready to merge",
                                      "MR !7  Ready to merge"])
        // The GitLab row borrows nothing from the forge beside it.
        #expect(!rows[1].title.contains("#7"))
        #expect(!rows[1].title.contains(Forge.github.refNoun))
        // …and it is the same wording the split button's help gives a lone
        // binding, rather than a second vocabulary beside it.
        #expect(rows[1].title.hasPrefix(gitLabBinding(7).refLabel))
    }

    @Test("a status-bar chip carries its binding's own forge vocabulary")
    func chipRefLabelPerForge() {
        let chips = StatusBarView.prChips([binding(412, .mergeable), gitLabBinding(7)]).chips
        #expect(chips.map(\.refLabel) == ["PR #412", "MR !7"])
        // The visible chip text stays the bare number on both forges — only the
        // tooltip, which names the thing in words, speaks a dialect.
        #expect(chips.map(\.label) == ["#412", "#7"])
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
        #expect(row.title == "PR #412  Checks failing  fix-login-timeout")
        #expect(row.title.contains("#412"))
        #expect(row.title.contains("Checks failing"))
        #expect(row.title.contains("fix-login-timeout"))
    }

    /// These rows share a screen with the status-bar chips: the `+N` menu is
    /// opened from beside them, and on a multi-PR worktree the chip and the row
    /// for one PR can be visible at once. So a row for a queued PR has to say
    /// the same thing the bus glyph beside it does — it used to render the
    /// literal "Checks pending" for the very PR whose chip read "In merge
    /// queue".
    @Test("a menu row for a queued PR leads with its queue position")
    func menuRowSpeaksTheQueue() {
        let url = "https://github.com/acme/acme-prod/pull/412"
        func queued(_ state: PRMergeableState, position: Int?) -> PRBinding {
            PRBinding(worktreeID: UUID(), owner: "acme", repo: "acme-prod",
                      number: 412, url: url,
                      status: PRStatus(number: 412, url: url, state: state,
                                       mergeQueuePosition: position),
                      source: .hook)
        }
        // The pending reason is the UNKNOWN decay artifact, so it goes.
        #expect(PRBindingPresentation.menuRows([queued(.pending, position: 3)])[0].title
            == "PR #412  In merge queue, position 3")
        // A failing check on a queued PR is live news — it says the PR is about
        // to be evicted — so it rides along.
        #expect(PRBindingPresentation.menuRows([queued(.checksFailed, position: 2)])[0].title
            == "PR #412  In merge queue, position 2 · Checks failing")
        // Unqueued rows are untouched by any of it.
        #expect(PRBindingPresentation.menuRows([queued(.checksFailed, position: nil)])[0].title
            == "PR #412  Checks failing")
        #expect(PRBindingPresentation.menuRows([queued(.pending, position: nil)])[0].title
            == "PR #412  Checks pending")
    }

    // MARK: - The overflow menu's refresh key

    /// AppKit materializes an `NSMenu` ONCE, so the `+N` menu carries an `.id`
    /// keyed on its rendered rows. This is the tripwire on that key, and it has
    /// to fail on the field that moves fastest: a queue position counting down
    /// 3 → 2 → 1 under an unchanged `state` would otherwise leave the menu row
    /// contradicting the bus badge on the chip two pixels away.
    @Test("the overflow menu's id moves when anything its rows render moves")
    func menuRowsIDTracksTheRenderedRows() {
        let bindingID = UUID()
        let defaultURL = "https://github.com/acme/acme-prod/pull/412"
        func bound(state: PRMergeableState = .checksFailed,
                   reason: String? = "Checks failing",
                   position: Int? = nil,
                   branch: String? = "fix-login-timeout",
                   prURL: String? = nil) -> [MenuRow] {
            let url = prURL ?? defaultURL
            return PRBindingPresentation.menuRows([
                PRBinding(id: bindingID, worktreeID: UUID(), owner: "acme", repo: "acme-prod",
                          number: 412, url: url, headBranch: branch,
                          status: PRStatus(number: 412, url: url, state: state,
                                           reason: reason, mergeQueuePosition: position),
                          source: .hook)
            ])
        }
        let base = PRBindingPresentation.menuRowsID(bound())
        #expect(PRBindingPresentation.menuRowsID(bound()) == base)
        // The fast-moving field: same state, same reason, one place nearer the
        // front of the queue.
        #expect(PRBindingPresentation.menuRowsID(bound(position: 3))
            != PRBindingPresentation.menuRowsID(bound(position: 2)))
        // Everything else a row renders. The state reaches the title only
        // through the words it falls back to, so it moves the key exactly when
        // the status brought none of its own.
        #expect(PRBindingPresentation.menuRowsID(bound(reason: "1 check failing")) != base)
        #expect(PRBindingPresentation.menuRowsID(bound(state: .blocked, reason: nil))
            != PRBindingPresentation.menuRowsID(bound(state: .checksFailed, reason: nil)))
        #expect(PRBindingPresentation.menuRowsID(bound(branch: "fix-login-timeout-2")) != base)
        // Identical text, re-pointed target — the row title carries the number
        // and the branch, not the url. The row's action captures that url and
        // `disabled` reads it, so the item still has to be rebuilt.
        let repointed = bound(prURL: "https://github.com/acme/acme-prod/pull/999")
        #expect(repointed[0].title == bound()[0].title)
        #expect(PRBindingPresentation.menuRowsID(repointed) != base)
        // A reason is whatever the forge wrote, and both of the key's own
        // separators are legal in it. They go through
        // `PRButtonLabel.escapedIDField`, so a value carrying either keys
        // distinctly rather than reading as a field boundary.
        #expect(PRBindingPresentation.menuRowsID(bound(reason: "a|b-c")) != base)
        #expect(PRBindingPresentation.menuRowsID(bound(reason: "a|b-c"))
            != PRBindingPresentation.menuRowsID(bound(reason: "abc")))
    }
}
