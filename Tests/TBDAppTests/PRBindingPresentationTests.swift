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

    @Test("with the done chip showing, the overflow wording says the list is open PRs")
    func overflowWordingOpenOnly() {
        #expect(PRBindingPresentation.overflowChipTooltip(total: 4, overflow: 2, openOnly: true)
                    == "Show all 4 open pull requests (2 not shown here)")
        #expect(PRBindingPresentation.overflowChipAccessibilityLabel(
            total: 4, overflow: 2, openOnly: true)
                    == "Show all 4 open pull requests, 2 not shown here")
        #expect(PRBindingPresentation.overflowChipTooltip(total: 1, overflow: 1, openOnly: true)
                    == "Show all 1 open pull request (1 not shown here)")
        // Ungrouped, the wording is unchanged.
        #expect(PRBindingPresentation.overflowChipTooltip(total: 4, overflow: 2, openOnly: false)
                    == "Show all 4 pull requests (2 not shown here)")
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

    // MARK: - The done chip split

    private func unobserved(_ n: Int) -> PRBinding {
        let url = "https://github.com/acme/acme-prod/pull/\(n)"
        return PRBinding(worktreeID: UUID(), owner: "acme", repo: "acme-prod",
                         number: n, url: url, status: nil, source: .hook)
    }

    @Test("with no finished PRs the split is exactly today's chip selection")
    func doneSplitNoFinished() {
        let bindings = (1...9).map { binding($0, .mergeable) }
        let groups = PRBindingPresentation.statusBarGroups(bindings, limit: 4)
        let today = PRBindingPresentation.statusBarChips(bindings, limit: 4)
        #expect(groups.chips == today.chips)
        #expect(groups.overflow == today.overflow)
        #expect(groups.overflowMenu == bindings)
        #expect(groups.done.isEmpty)
    }

    @Test("a single finished PR stays a normal chip")
    func doneSplitOneFinished() {
        let bindings = [binding(1, .mergeable), binding(2, .merged),
                        binding(3, .draft), binding(4, .checksFailed),
                        binding(5, .mergeable)]
        let groups = PRBindingPresentation.statusBarGroups(bindings, limit: 4)
        let today = PRBindingPresentation.statusBarChips(bindings, limit: 4)
        #expect(groups.chips == today.chips)
        #expect(groups.chips.map(\.number) == [1, 2, 3, 4])
        #expect(groups.overflow == today.overflow)
        #expect(groups.overflow == 1)
        #expect(groups.overflowMenu == bindings)
        #expect(groups.done.isEmpty)
    }

    @Test("two or more finished PRs fold into the done group, both groups in bind order")
    func doneSplitGroups() {
        let bindings = [binding(10, .merged), binding(20, .mergeable),
                        binding(30, .closed), binding(40, .draft),
                        binding(50, .merged), binding(60, .checksFailed)]
        let groups = PRBindingPresentation.statusBarGroups(bindings, limit: 7)
        #expect(groups.chips.map(\.number) == [20, 40, 60])
        #expect(groups.overflow == 0)
        #expect(groups.overflowMenu.map(\.number) == [20, 40, 60])
        // `.closed` folds alongside `.merged`.
        #expect(groups.done.map(\.number) == [10, 30, 50])
    }

    @Test("a binding with no observed status counts as open")
    func doneSplitUnobservedIsOpen() {
        let bindings = [unobserved(1), binding(2, .merged), binding(3, .closed)]
        #expect(!PRBindingPresentation.isFinished(bindings[0]))
        let groups = PRBindingPresentation.statusBarGroups(bindings, limit: 7)
        #expect(groups.chips.map(\.number) == [1])
        #expect(groups.done.map(\.number) == [2, 3])
    }

    @Test("when grouping, the cap and the overflow count cover open PRs only")
    func doneSplitLimitCountsOpenOnly() {
        let bindings = [binding(1, .merged), binding(2, .mergeable),
                        binding(3, .merged), binding(4, .mergeable),
                        binding(5, .mergeable), binding(6, .closed),
                        binding(7, .mergeable)]
        let groups = PRBindingPresentation.statusBarGroups(bindings, limit: 2)
        #expect(groups.chips.map(\.number) == [2, 4])
        #expect(groups.overflow == 2)
        // The `+N` menu lists the open PRs, not the finished ones.
        #expect(groups.overflowMenu.map(\.number) == [2, 4, 5, 7])
        #expect(groups.done.map(\.number) == [1, 3, 6])
    }

    @Test("when every PR is finished, the cluster is the done group alone")
    func doneSplitAllFinished() {
        let bindings = [binding(1, .merged), binding(2, .closed), binding(3, .merged)]
        let groups = PRBindingPresentation.statusBarGroups(bindings, limit: 7)
        #expect(groups.chips.isEmpty)
        #expect(groups.overflow == 0)
        #expect(groups.overflowMenu.isEmpty)
        #expect(groups.done == bindings)
    }

    @Test("the done chip label names the request noun of the forges it holds")
    func doneChipLabelNoun() {
        let mr = { (n: Int) in self.finished(n, url: "https://gitlab.acme.dev/acme/acme-prod/-/merge_requests/\(n)") }
        #expect(PRBindingPresentation.doneChipLabel([finished(1), finished(2)]) == "\u{2713} 2 PRs done")
        #expect(PRBindingPresentation.doneChipLabel([mr(1), mr(2)]) == "\u{2713} 2 MRs done")
        // A set spanning both forges takes the more common word.
        #expect(PRBindingPresentation.doneChipLabel([finished(1), mr(2)]) == "\u{2713} 2 PRs done")
        #expect(PRBindingPresentation.doneChipLabel([mr(1)]) == "\u{2713} 1 MR done")
        #expect(PRBindingPresentation.doneChipLabel([finished(1)]) == "\u{2713} 1 PR done")
    }

    @Test("the done chip names its count, singular and plural")
    func doneChipWording() {
        #expect(PRBindingPresentation.doneChipCardTitle(count: 5)
                    == "5 merged or closed pull requests")
        #expect(PRBindingPresentation.doneChipCardTitle(count: 1)
                    == "1 merged or closed pull request")
        #expect(PRBindingPresentation.doneChipAccessibilityLabel(count: 5)
                    == "Show 5 merged or closed pull requests")
        #expect(PRBindingPresentation.doneChipAccessibilityLabel(count: 1)
                    == "Show 1 merged or closed pull request")
    }

    // MARK: - The done chip's menu rows

    private func finished(_ n: Int, _ state: PRMergeableState = .merged,
                          title: String? = nil, headBranch: String? = nil,
                          url: String? = nil) -> PRBinding {
        let url = url ?? "https://github.com/acme/acme-prod/pull/\(n)"
        return PRBinding(worktreeID: UUID(), owner: "acme", repo: "acme-prod",
                         number: n, url: url, headBranch: headBranch, title: title,
                         status: PRStatus(number: n, url: url, state: state),
                         source: .hook)
    }

    @Test("done menu rows lead with the title, then the reference and state, in bind order")
    func doneMenuRowsLeadWithTitle() {
        let bindings = [
            finished(930, title: "Fix the login timeout", headBranch: "fix-login"),
            finished(912, .closed, title: " Trim the relay "),
        ]
        let rows = PRBindingPresentation.doneMenuRows(bindings)
        #expect(rows.map(\.number) == [930, 912])
        #expect(rows.map(\.title) == [
            "Fix the login timeout  PR #930 · Merged",
            "Trim the relay  PR #912 · Closed",
        ])
        #expect(rows.map(\.id) == bindings.map(\.id))
        #expect(rows[0].url == URL(string: bindings[0].url))
        #expect(rows[0].state == .merged)
    }

    @Test("an untitled done menu row falls back to the branch, then to the reference alone")
    func doneMenuRowsFallBack() {
        let gitlab = "https://git.acme.example/acme/platform/api-gateway/-/merge_requests/7"
        let rows = PRBindingPresentation.doneMenuRows([
            finished(5, title: "  ", headBranch: "fix-login"),
            finished(6),
            finished(7, url: gitlab),
        ])
        #expect(rows.map(\.title) == [
            "fix-login  PR #5 · Merged",
            "PR #6 · Merged",
            "MR !7 · Merged",
        ])
    }

    @Test("a blank status reason leaves no dangling separator on a done row")
    func doneMenuRowsBlankReason() {
        let url = "https://github.com/acme/acme-prod/pull/8"
        let b = PRBinding(worktreeID: UUID(), owner: "acme", repo: "acme-prod",
                          number: 8, url: url, title: "Fix it",
                          status: PRStatus(number: 8, url: url, state: .merged, reason: "  "),
                          source: .hook)
        #expect(PRBindingPresentation.doneReference(b) == "PR #8")
        #expect(PRBindingPresentation.doneMenuRows([b])[0].title == "Fix it  PR #8")
    }

    @Test("a long title is cut short in the done menu, never the reference")
    func doneMenuRowsTruncateLongTitles() {
        let limit = PRBindingPresentation.doneMenuLeadLimit
        let exact = String(repeating: "a", count: limit)
        let long = String(repeating: "b", count: limit + 40)
        let rows = PRBindingPresentation.doneMenuRows([
            finished(1, title: exact),
            finished(2, title: long),
        ])
        #expect(rows[0].title == "\(exact)  PR #1 · Merged")
        #expect(rows[1].title
                == "\(String(repeating: "b", count: limit - 1))\u{2026}  PR #2 · Merged")
    }

    @Test("the done menu's rows do not change the shared +N / toolbar rows")
    func doneMenuRowsLeaveMenuRowsAlone() {
        let b = finished(930, title: "Fix the login timeout", headBranch: "fix-login")
        #expect(PRBindingPresentation.menuRows([b])[0].title == "PR #930  Merged  fix-login")
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
}
