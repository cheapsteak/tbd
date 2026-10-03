import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: the pure chip model behind the status bar's PR cluster, and the pure
// content of the hover overlay a chip carries. Rendering is not exercised here —
// only the value transforms the row and the card are built from.
//
// Deliberately a `@Suite` struct rather than the free `@Test` functions the two
// sibling StatusBarView files use: `swift test --filter` matches the test ID,
// which carries the SUITE name, so free functions named `locationLabel_…` are
// invisible to `--filter StatusBarView`.
@Suite("StatusBarView PR chips")
struct StatusBarViewChipsTests {

    private func binding(
        _ number: Int,
        _ state: PRMergeableState?,
        worktreeID: UUID = UUID(),
        title: String? = nil,
        observedAt: Date? = nil,
        mergeQueuePosition: Int? = nil
    ) -> PRBinding {
        let url = "https://github.com/acme/acme-prod/pull/\(number)"
        return PRBinding(
            worktreeID: worktreeID, owner: "acme", repo: "acme-prod",
            number: number, url: url,
            title: title,
            status: state.map {
                PRStatus(number: number, url: url, state: $0,
                         mergeQueuePosition: mergeQueuePosition, observedAt: observedAt)
            },
            source: .hook
        )
    }

    // MARK: - The cap

    @Test("seven bound PRs all get a chip, with nothing pushed into the overflow")
    func sevenChipsFitWithoutOverflow() {
        let bindings = (1...7).map { binding($0, .mergeable) }
        let model = StatusBarView.prChips(bindings)
        #expect(model.chips.count == 7)
        #expect(model.overflow == 0)
        #expect(model.chips.map(\.label) == ["#1", "#2", "#3", "#4", "#5", "#6", "#7"])
    }

    @Test("an eighth PR is the first to collapse into +1")
    func eighthOverflows() {
        let bindings = (1...8).map { binding($0, .mergeable) }
        let model = StatusBarView.prChips(bindings)
        #expect(model.chips.count == 7)
        #expect(model.overflow == 1)
        // The chip counts what didn't fit; its menu still lists all eight.
        #expect(PRBindingPresentation.overflowChipTooltip(
            total: bindings.count, overflow: model.overflow)
            == "Show all 8 pull requests (1 not shown here)")
        #expect(PRBindingPresentation.overflowChipAccessibilityLabel(
            total: bindings.count, overflow: model.overflow)
            == "Show all 8 pull requests, 1 not shown here")
    }

    @Test("no bindings means no chips at all")
    func noChips() {
        let model = StatusBarView.prChips([])
        #expect(model.chips.isEmpty)
        #expect(model.overflow == 0)
    }

    @Test("chips keep bind order, not severity order")
    func chipsKeepBindOrder() {
        let model = StatusBarView.prChips([
            binding(30, .mergeable), binding(10, .checksFailed), binding(20, .draft)
        ])
        #expect(model.chips.map(\.label) == ["#30", "#10", "#20"])
    }

    @Test("an explicit limit overrides the default cap")
    func explicitLimit() {
        let bindings = (1...9).map { binding($0, .mergeable) }
        let model = StatusBarView.prChips(bindings, limit: 2)
        #expect(model.chips.map(\.label) == ["#1", "#2"])
        #expect(model.overflow == 7)
    }

    @Test("finished PRs past the threshold leave the chip row for the done chip")
    func finishedPRsFoldIntoDone() {
        let bindings = [binding(1, .merged), binding(2, .mergeable),
                        binding(3, .closed), binding(4, nil)]
        let model = StatusBarView.prChips(bindings)
        #expect(model.chips.map(\.label) == ["#2", "#4"])
        #expect(model.overflow == 0)
        #expect(model.overflowMenu.map(\.number) == [2, 4])
        #expect(model.done.map(\.number) == [1, 3])
    }

    @Test("with finished PRs folded, the +N chip's wording counts open PRs")
    func groupedOverflowWordingSaysOpen() {
        let bindings = [binding(1, .merged), binding(2, .mergeable),
                        binding(3, .closed), binding(4, .draft),
                        binding(5, .mergeable)]
        let model = StatusBarView.prChips(bindings, limit: 1)
        #expect(model.overflow == 2)
        // The same composition `PRChipCluster` performs.
        let openOnly = !model.done.isEmpty
        #expect(openOnly)
        #expect(PRBindingPresentation.overflowChipTooltip(
            total: model.overflowMenu.count, overflow: model.overflow, openOnly: openOnly)
            == "Show all 3 open pull requests (2 not shown here)")
        #expect(PRBindingPresentation.overflowChipAccessibilityLabel(
            total: model.overflowMenu.count, overflow: model.overflow, openOnly: openOnly)
            == "Show all 3 open pull requests, 2 not shown here")
    }

    @Test("a lone merged PR keeps its chip and nothing folds")
    func loneMergedKeepsChip() {
        let bindings = [binding(1, .merged), binding(2, .mergeable)]
        let model = StatusBarView.prChips(bindings)
        #expect(model.chips.map(\.label) == ["#1", "#2"])
        #expect(model.done.isEmpty)
        #expect(model.overflowMenu == bindings)
    }

    @Test("a chip id is its binding's id, so the row is stable across refreshes")
    func chipIDMatchesBinding() {
        let one = binding(412, .mergeable)
        #expect(StatusBarView.prChips([one]).chips[0].id == one.id)
    }

    // MARK: - What a chip carries

    @Test("a chip carries everything its click targets and overlay need")
    func chipContent() {
        let worktree = UUID()
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        let model = StatusBarView.prChips([
            binding(412, .checksFailed, worktreeID: worktree,
                    title: "Fix the login timeout", observedAt: observed)
        ])
        let chip = model.chips[0]
        #expect(chip.url?.absoluteString.hasSuffix("/pull/412") == true)
        #expect(chip.state == .checksFailed)
        #expect(chip.number == 412)
        // The untrack gesture detaches from THIS worktree, so the chip has to
        // name it without the view threading it through.
        #expect(chip.worktreeID == worktree)
        #expect(chip.title == "Fix the login timeout")
        #expect(chip.observedAt == observed)
    }

    @Test("a chip tolerates an absent title, state and observation stamp")
    func chipToleratesAbsentFields() {
        // A synthetic chip lifted from a cached status has no title; a binding
        // nothing has polled yet has neither status nor stamp.
        let model = StatusBarView.prChips([binding(412, nil)])
        let chip = model.chips[0]
        #expect(chip.title == nil)
        #expect(chip.state == nil)
        #expect(chip.observedAt == nil)
        #expect(chip.label == "#412")
    }

    // MARK: - The hover overlay

    private func chip(
        number: Int = 412,
        state: PRMergeableState? = .mergeable,
        title: String? = nil,
        observedAt: Date? = nil,
        mergeQueuePosition: Int? = nil
    ) -> StatusBarView.PRChip {
        StatusBarView.prChips([
            binding(number, state, title: title, observedAt: observedAt,
                    mergeQueuePosition: mergeQueuePosition)
        ]).chips[0]
    }

    /// The same chip bound to a GitLab merge request instead — built through
    /// `prChips` like every other fixture here, so the forge is read from the
    /// binding's own URL exactly as production reads it.
    private func gitlabChip(
        number: Int = 412,
        state: PRMergeableState? = .mergeable,
        title: String? = nil
    ) -> StatusBarView.PRChip {
        let url = "https://gitlab.acme.example/acme/group/acme-prod/-/merge_requests/\(number)"
        return StatusBarView.prChips([
            PRBinding(
                worktreeID: UUID(), host: "gitlab.acme.example",
                owner: "acme/group", repo: "acme-prod",
                number: number, url: url,
                title: title,
                status: state.map { PRStatus(number: number, url: url, state: $0) },
                source: .hook
            )
        ]).chips[0]
    }

    /// A fixed clock for the overlay tests, so every age is exact.
    private static let now = Date(timeIntervalSince1970: 1_700_007_200)

    /// A reading taken a minute before `now` — well inside the quiet window.
    private static let freshlyObserved = now.addingTimeInterval(-60)

    @Test("a titled chip leads with its title, with the reference and state beneath it")
    func overlayLeadsWithTheTitle() {
        let card = StatusBarView.chipHoverCard(
            chip(state: .checksFailed,
                 title: "Fix the login timeout",
                 observedAt: Self.freshlyObserved),
            now: Self.now)
        #expect(card.title == "Fix the login timeout")
        #expect(card.titleCaption
                == "PR#412 · \(PRMergeableState.checksFailed.displayReason)")
        // A fresh reading says nothing about its age, and nothing on the card
        // describes the click — the chip's own targets say that.
        #expect(card.rows.isEmpty)
    }

    @Test("an untitled chip's title line is the reference and state, with no line beneath")
    func overlayWithoutTitle() {
        let card = StatusBarView.chipHoverCard(
            chip(state: .merged, title: nil, observedAt: Self.freshlyObserved),
            now: Self.now)
        #expect(card.title == "PR#412 (\(PRMergeableState.merged.displayReason))")
        // The reference is already the title, so it is not repeated under it.
        #expect(card.titleCaption == nil)
        #expect(card.rows.isEmpty)
    }

    @Test("a chip with no observed state names only its number, on either line")
    func overlayWithoutState() {
        let titled = StatusBarView.chipHoverCard(
            chip(state: nil, title: "Relay the GitHub event"), now: Self.now)
        #expect(titled.title == "Relay the GitHub event")
        #expect(titled.titleCaption == "PR#412")

        let bare = StatusBarView.chipHoverCard(chip(state: nil, title: nil), now: Self.now)
        #expect(bare.title == "PR#412")
        #expect(bare.titleCaption == nil)
    }

    /// Every part but the number is optional, and an absent one is *omitted*
    /// rather than filled: no empty `()`, and no dangling ` · `.
    @Test("the title and reference lines degrade to whichever facts were observed")
    func headlineDegradesByOmission() {
        let state = PRMergeableState.merged.displayReason
        #expect(StatusBarView.chipHeadline(chip(state: .merged, title: "Relay the GitHub event"))
                == "Relay the GitHub event")
        #expect(StatusBarView.chipHeadline(chip(state: .merged, title: nil)) == "PR#412 (\(state))")
        #expect(StatusBarView.chipHeadline(chip(state: nil, title: nil)) == "PR#412")
        #expect(StatusBarView.chipReference(chip(state: .merged)) == "PR#412 · \(state)")
        #expect(StatusBarView.chipReference(chip(state: nil)) == "PR#412")
        for line in [StatusBarView.chipHeadline(chip(state: nil, title: nil)),
                     StatusBarView.chipHeadline(chip(state: .merged, title: nil)),
                     StatusBarView.chipReference(chip(state: nil)),
                     StatusBarView.chipReference(chip(state: .merged))] {
            #expect(line.contains("()") == false)
            #expect(line.hasSuffix(" · ") == false)
            #expect(line.hasSuffix(" ·") == false)
        }
    }

    @Test("a whitespace-only title counts as absent")
    func overlayBlankTitle() {
        let card = StatusBarView.chipHoverCard(chip(state: nil, title: "   \n"))
        #expect(card.title == "PR#412")
        #expect(card.titleCaption == nil)
    }

    /// The overflow menu and the toolbar dropdown render `reason ?? state`, so
    /// the overlay has to as well — three surfaces describing one observation
    /// differently is exactly what sharing the presentation exists to prevent.
    @Test("the overlay prefers the status's own words to the generic state label")
    func overlayPrefersTheStatusReason() {
        let url = "https://github.com/acme/acme-prod/pull/412"
        let binding = PRBinding(
            worktreeID: UUID(), owner: "acme", repo: "acme-prod", number: 412, url: url,
            status: PRStatus(number: 412, url: url, state: .blocked,
                             reason: "Changes requested by reviewer"),
            source: .hook)
        let chip = StatusBarView.prChips([binding]).chips[0]

        let headline = StatusBarView.chipHeadline(chip)
        #expect(headline == "PR#412 (Changes requested by reviewer)")
        #expect(headline.contains(PRMergeableState.blocked.displayReason) == false)
        #expect(StatusBarView.chipReference(chip) == "PR#412 · Changes requested by reviewer")
        // …and it is the same string the overflow menu row is built from.
        #expect(PRBindingPresentation.menuRows([binding])[0].title
            .contains("Changes requested by reviewer"))
        // …and the tooltip and VoiceOver hint beside the card agree with it,
        // rather than falling back to the generic state label.
        #expect(StatusBarView.openLabel(chip)
            == "Open PR #412 — Changes requested by reviewer")
    }

    // MARK: - The freshness warning

    @Test("a fresh reading does not show its age")
    func freshReadingHidesItsAge() {
        let justInside = Self.now.addingTimeInterval(-(StatusBarView.chipStaleAfter - 1))
        for observedAt in [Self.freshlyObserved, justInside, Self.now] {
            let one = chip(state: .mergeable, title: "Fix the login timeout", observedAt: observedAt)
            #expect(StatusBarView.chipFreshnessWarning(one, now: Self.now) == nil)
            #expect(StatusBarView.chipHoverCard(one, now: Self.now).rows.isEmpty)
        }
    }

    /// `PRStatus` is a display-tier cache, measured reading "Ready to merge"
    /// days after a merge — so past the threshold the card must not show a
    /// state without its age, and says so in the caution tint.
    @Test("a stale reading shows its age, in the caution tint")
    func staleReadingShowsItsAge() {
        let stale = chip(state: .mergeable, title: "Fix the login timeout",
                         observedAt: Self.now.addingTimeInterval(-7200))
        #expect(StatusBarView.chipHoverCard(stale, now: Self.now).rows
                == [HoverCardRow(value: "checked 2h ago", tint: .caution)])

        // The threshold is inclusive, and its first age is the first bucket
        // `PRFreshness.checkedLabel` stops calling "just now".
        let atThreshold = chip(state: .mergeable,
                               observedAt: Self.now.addingTimeInterval(-StatusBarView.chipStaleAfter))
        #expect(StatusBarView.chipFreshnessWarning(atThreshold, now: Self.now) == "checked 5m ago")
        #expect(StatusBarView.chipStaleAfter == 300)
    }

    @Test("a chip with no observed status says the age is unknown")
    func neverObservedSaysSo() {
        let card = StatusBarView.chipHoverCard(chip(state: nil, observedAt: nil), now: Self.now)
        #expect(card.rows.first?.value == "last checked at an unknown time")
        #expect(card.rows.first?.value
                == PRFreshness.checkedLabel(observedAt: nil, now: Self.now))
        #expect(card.rows.first?.tint == .caution)
    }

    /// The toolbar and sidebar both append "last check did not resolve" after
    /// the age. A chip that dropped it would render the more confident of two
    /// readings of one fact — the exact drift `PRFreshness` exists to prevent.
    /// It shows even over a fresh reading, and always with the age it qualifies.
    @Test("an undetermined last poll is always named, with the reading's age")
    func undeterminedObservationShowsItsClause() {
        let observation = PRObservation(
            outcome: .undetermined(cause: "gh unauthenticated"), observedAt: Self.now)

        let fresh = StatusBarView.prChips(
            [binding(412, .mergeable, observedAt: Self.freshlyObserved)],
            observation: observation).chips[0]
        #expect(StatusBarView.chipHoverCard(fresh, now: Self.now).rows.first?.value
                == "checked just now · last check did not resolve (gh unauthenticated)")

        let stale = StatusBarView.prChips(
            [binding(412, .mergeable, observedAt: Self.now.addingTimeInterval(-7200))],
            observation: observation).chips[0]
        #expect(StatusBarView.chipHoverCard(stale, now: Self.now).rows.first?.value
                == "checked 2h ago · last check did not resolve (gh unauthenticated)")

        // A settled attempt adds nothing — the clause is a caveat, not a field.
        let settled = StatusBarView.prChips(
            [binding(412, .mergeable, observedAt: Self.freshlyObserved)],
            observation: PRObservation(outcome: .none, observedAt: Self.now)).chips[0]
        #expect(StatusBarView.chipHoverCard(settled, now: Self.now).rows.isEmpty)
    }

    // MARK: - The two click targets

    @Test("the untrack target says it removes the PR from THIS worktree")
    func untrackLabelNamesTheWorktreeScope() {
        // Wording matters: the gesture removes an association TBD inferred, not
        // the pull request, so the label must not read as "close PR #412".
        let label = StatusBarView.untrackLabel(chip())
        #expect(label == "Stop tracking PR #412 in this worktree")
        // …and it is a different sentence from the chip's own target, so the
        // two accessibility elements cannot be confused for each other.
        #expect(label != StatusBarView.openLabel(chip()))
    }

    @Test("the open target names the state when there is one, and doesn't invent one when there isn't")
    func openLabelCarriesState() {
        #expect(StatusBarView.openLabel(chip(state: .checksFailed))
                == "Open PR #412 — \(PRMergeableState.checksFailed.displayReason)")
        #expect(StatusBarView.openLabel(chip(state: nil)) == "Open PR #412")
    }

    /// The icon slot draws a status dot at rest and an xmark while hovered, and
    /// `onHover` is not guaranteed to have arrived — a chip can be inserted or
    /// reflowed under a stationary cursor. So the slot's meaning is derived from
    /// the same flag as its glyph: a click can never destroy an association the
    /// slot is not currently offering to remove.
    @Test("the icon slot means untrack only while hovered, and open otherwise")
    func iconSlotMeaningFollowsTheGlyph() {
        let one = chip(state: .checksFailed)
        #expect(StatusBarView.iconSlotLabel(one, isHovering: true)
                == StatusBarView.untrackLabel(one))
        // Not hovering: the slot is a status dot, and clicking a status dot
        // opens the PR exactly as it did before the untrack gesture existed.
        #expect(StatusBarView.iconSlotLabel(one, isHovering: false)
                == StatusBarView.openLabel(one))
        #expect(StatusBarView.iconSlotLabel(one, isHovering: true)
                != StatusBarView.iconSlotLabel(one, isHovering: false))
    }

    // MARK: - The merge queue

    /// The chip cannot derive the queue from `state`: a queued PR reports
    /// UNKNOWN, which decays to the ordinary pending state. So the position has
    /// to ride on the chip, which is what the leading slot swaps its dot for a
    /// bus on.
    @Test("a chip carries the merge-queue position, and nil when the PR is not queued")
    func chipCarriesTheQueuePosition() {
        #expect(StatusBarView.prChips([binding(412, .pending, mergeQueuePosition: 3)])
            .chips[0].mergeQueuePosition == 3)
        #expect(StatusBarView.prChips([binding(412, .pending)])
            .chips[0].mergeQueuePosition == nil)
        // A binding nothing has polled has no status to read a position from.
        #expect(StatusBarView.prChips([binding(412, nil)]).chips[0].mergeQueuePosition == nil)
    }

    /// The queue clause supersedes the state's words for EXACTLY ONE state.
    /// `.pending` on a queued PR is not an observation, it is decay: the forge
    /// reports a queued PR's merge state as UNKNOWN and the daemon maps that to
    /// `(.pending, "Checks pending")`, so a headline carrying both would say
    /// the PR is waiting on its author and sitting in the queue at once.
    @Test("a queued chip's headline drops the pending reason the UNKNOWN state decayed into")
    func headlineSupersedesOnlyThePendingReasonWhenQueued() {
        let queued = chip(state: .pending, mergeQueuePosition: 3)
        #expect(StatusBarView.chipHeadline(queued) == "PR#412 (In merge queue, position 3)")
        // Not appended: neither the generic pending label nor a second clause
        // survives beside the queue sentence.
        #expect(StatusBarView.chipHeadline(queued)
            .contains(PRMergeableState.pending.displayReason) == false)
        // Under a title, the reference line carries the same clause.
        #expect(StatusBarView.chipReference(
            chip(state: .pending, title: "Fix the login timeout", mergeQueuePosition: 3))
            == "PR#412 · In merge queue, position 3")
    }

    /// Every state other than `.pending` is computed independently of queue
    /// membership, so it is live news and rides along. A PR at position 2 whose
    /// required check just went red is about to be evicted from that queue —
    /// the one fact worth acting on, and the one an unconditional supersession
    /// swallowed on every chip surface at once.
    @Test("a queued chip that is also failing keeps the failure beside its position")
    func queuedChipKeepsANonPendingReason() {
        let failing = chip(state: .checksFailed, mergeQueuePosition: 2)
        #expect(StatusBarView.chipHeadline(failing)
            == "PR#412 (In merge queue, position 2 · Checks failing)")
        #expect(StatusBarView.openLabel(failing)
            == "Open PR #412 — In merge queue, position 2 · Checks failing")
        // The queue clause leads, because it is the mode the PR is in; the
        // reason qualifies it rather than replacing it.
        #expect(failing.stateDescription?.hasPrefix("In merge queue, position 2") == true)
        #expect(failing.stateDescription?.contains(PRMergeableState.checksFailed.displayReason)
            == true)
        // A queued PR the forge still calls ready keeps that reading too — the
        // exception is `.pending`, not "any state a queued PR might report".
        #expect(StatusBarView.chipHeadline(chip(state: .mergeable, mergeQueuePosition: 1))
            == "PR#412 (In merge queue, position 1 · Ready to merge)")
        // A status's own words, not just the generic state label, survive.
        let url = "https://github.com/acme/acme-prod/pull/412"
        let reviewed = StatusBarView.prChips([PRBinding(
            worktreeID: UUID(), owner: "acme", repo: "acme-prod", number: 412, url: url,
            status: PRStatus(number: 412, url: url, state: .blocked,
                             reason: "Changes requested by reviewer",
                             mergeQueuePosition: 4),
            source: .hook)]).chips[0]
        #expect(StatusBarView.chipHeadline(reviewed)
            == "PR#412 (In merge queue, position 4 · Changes requested by reviewer)")
    }

    /// The tooltip and the VoiceOver hint read the same sentence the card does.
    /// A chip whose glyph is a bus and whose hint says "Checks pending" would
    /// have the words under the pointer contradict the glyph the pointer is on.
    @Test("the open target says the queue position too")
    func openLabelSpeaksTheQueue() {
        let queued = chip(state: .pending, mergeQueuePosition: 3)
        #expect(StatusBarView.openLabel(queued) == "Open PR #412 — In merge queue, position 3")
        #expect(StatusBarView.openLabel(queued)
            .contains(PRMergeableState.pending.displayReason) == false)
        // The icon slot's resting meaning is that same sentence, since a click
        // on the drawn bus opens the PR exactly as a click on a dot does.
        #expect(StatusBarView.iconSlotLabel(queued, isHovering: false)
            == StatusBarView.openLabel(queued))
    }

    /// The anti-drift claim made in three doc comments, asserted rather than
    /// asserted-about: the chip does not compose its own sentence, it calls the
    /// same `PRStatusPresentation.stateDescription` the sidebar row's tooltip
    /// and the dropdown's menu rows call.
    ///
    /// It is worth being precise about what this can and cannot catch. Both
    /// sides route through the shared helper, so a change to the *wording*
    /// moves both and this stays green — that is the point, not a gap. What it
    /// does catch is a surface that stops calling the helper and starts
    /// composing its own words, and — because the chip carries `reason` while
    /// the `for:` overload derives `reason ?? state.displayReason` — a chip
    /// whose fallback drifts from the overload's. The custom-`reason` case
    /// below exercises exactly that seam: with `reason: nil` on every status,
    /// both paths would agree through `displayReason` alone and a divergence in
    /// how the chip picks its words would never show.
    @Test("the chip's sentence is the one shared with the sidebar and the menu rows")
    func chipSentenceComesFromTheSharedHelper() {
        let states: [PRMergeableState] = [.pending, .checksFailed, .mergeable, .blocked,
                                          .changesRequested, .draft, .merged, .closed]
        let positions: [Int?] = [nil, 1, 150]
        // nil = the state's generic words; the custom string = a status that
        // brought its own, which is the only case where the chip's `reason` and
        // the overload's `reason ?? displayReason` can disagree.
        let reasons: [String?] = [nil, "Changes requested by reviewer"]
        for state in states {
            for position in positions {
                for reason in reasons {
                    let url = "https://github.com/acme/acme-prod/pull/412"
                    let status = PRStatus(number: 412, url: url, state: state,
                                          reason: reason, mergeQueuePosition: position)
                    let binding = PRBinding(
                        worktreeID: UUID(), owner: "acme", repo: "acme-prod",
                        number: 412, url: url, status: status, source: .hook)
                    let shared = PRStatusPresentation.stateDescription(for: status)
                    // The chip surface…
                    #expect(StatusBarView.prChips([binding]).chips[0].stateDescription == shared)
                    // …and the menu-row surface, which the `+N` overflow menu and
                    // the toolbar dropdown both render.
                    #expect(PRBindingPresentation.menuRows([binding])[0].title.contains(shared))
                }
            }
        }
    }

    // MARK: - The icon slot's width

    /// The invariant the hover geometry rests on: the slot's side is a function
    /// of WHICH CHIP it is, never of hover state. A slot that grew under the
    /// pointer would shove every chip to its right and slide the xmark out from
    /// under the cursor that summoned it. It lives on `StatusBarView` rather
    /// than inside `PRChipView` precisely so this can be asserted at all.
    @Test("a queued chip's icon slot is bus-sized, and every other chip's is dot-sized")
    func iconSlotSideDependsOnTheChipNotTheHover() {
        // The slot is sized by the ONE constant both surfaces draw the bus at,
        // so a chip cannot be sized for a bus the sidebar renders at some other
        // side — and `busImage` cannot be asked for a second cached bitmap.
        #expect(StatusBarView.iconSlotSide(for: chip(state: .pending, mergeQueuePosition: 3))
            == PRStatusPresentation.busSide)
        #expect(StatusBarView.iconSlotSide(for: chip(state: .pending)) == 9)
        #expect(StatusBarView.iconSlotSide(for: chip(state: .checksFailed)) == 9)
        // A never-polled binding has no position, so it draws a dot.
        #expect(StatusBarView.iconSlotSide(for: chip(state: nil)) == 9)
        // Pinned as a value too: the bus slot has to stay bigger than the 9pt
        // dot slot, or a queued chip would clip its own glyph.
        #expect(PRStatusPresentation.busSide == 12)
    }

    /// The queue clause is a replacement for one chip's state sentence, not a
    /// change to how every chip describes itself.
    @Test("an unqueued chip's headline and open label are untouched")
    func unqueuedChipIsUnchanged() {
        let plain = chip(state: .checksFailed, title: "Fix the login timeout")
        #expect(StatusBarView.chipReference(plain)
            == "PR#412 · \(PRMergeableState.checksFailed.displayReason)")
        #expect(StatusBarView.openLabel(plain)
            == "Open PR #412 — \(PRMergeableState.checksFailed.displayReason)")
        #expect(StatusBarView.chipReference(plain).contains("merge queue") == false)
        #expect(StatusBarView.openLabel(plain).contains("merge queue") == false)
        // A chip with no status at all still says only what it observed.
        #expect(StatusBarView.chipHeadline(chip(state: nil)) == "PR#412")
        #expect(StatusBarView.openLabel(chip(state: nil)) == "Open PR #412")
    }

    // MARK: - Forge vocabulary

    /// The card names the request in its own forge's vocabulary on whichever
    /// line carries the reference. The noun is glued to the number the chip is
    /// already drawing, which is the bare `#412` on both forges — hence
    /// `refNoun` and not `refLabel`, whose `!412` would disagree with the chip
    /// under the pointer.
    @Test("the title and reference lines name the request in its own forge's vocabulary")
    func headlineSpeaksTheChipsForge() {
        let state = PRMergeableState.mergeable.displayReason
        #expect(StatusBarView.chipHeadline(chip()) == "PR#412 (\(state))")
        #expect(StatusBarView.chipHeadline(gitlabChip()) == "MR#412 (\(state))")
        #expect(StatusBarView.chipReference(chip()) == "PR#412 · \(state)")
        #expect(StatusBarView.chipReference(gitlabChip()) == "MR#412 · \(state)")

        // Every degradation arm carries the noun too: a chip with neither state
        // nor title is the shortest line there is, and still not a "PR".
        #expect(StatusBarView.chipHeadline(gitlabChip(state: nil)) == "MR#412")
        #expect(StatusBarView.chipReference(gitlabChip(state: nil)) == "MR#412")
    }

    @Test("a GitLab chip's card says MR, never PR")
    func gitlabCardSaysMR() {
        let titled = gitlabChip(state: .merged, title: "Trim the relay")
        #expect(titled.forge == .gitlab)
        let card = StatusBarView.chipHoverCard(titled)
        #expect(card.title == "Trim the relay")
        #expect(card.titleCaption == "MR#412 · \(PRMergeableState.merged.displayReason)")

        let untitled = StatusBarView.chipHoverCard(gitlabChip(state: .merged))
        #expect(untitled.title == "MR#412 (\(PRMergeableState.merged.displayReason))")
        #expect(untitled.titleCaption == nil)

        for line in [card.title, card.titleCaption, untitled.title] {
            #expect(line?.contains(Forge.github.refNoun) == false)
        }
    }

    /// The chip itself draws the bare number on both forges, so the number
    /// element's accessibility label — what `PRChipView` passes as
    /// `chip.refLabel` — is where a screen reader learns which forge this is.
    /// It was a hardcoded `PR #412` for every chip.
    @Test("the number element announces the binding in its forge's vocabulary")
    func numberElementAnnouncesItsForge() {
        #expect(chip().refLabel == "PR #412")
        #expect(gitlabChip().refLabel == "MR !412")
        // The hint on the same element composes that value, so the element
        // cannot announce one forge and hint another.
        #expect(StatusBarView.openLabel(gitlabChip()).contains(gitlabChip().refLabel))
    }

    /// Both click targets already composed `refLabel`; this pins that they do,
    /// because every earlier round of this defect fixed one surface and left
    /// the next one asserting only GitHub.
    @Test("both click targets name a merge request the way GitLab does")
    func clickTargetLabelsSpeakGitLab() {
        let mr = gitlabChip(state: .checksFailed)
        let untrack = StatusBarView.untrackLabel(mr)
        let open = StatusBarView.openLabel(mr)
        #expect(untrack == "Stop tracking MR !412 in this worktree")
        #expect(open == "Open MR !412 — \(PRMergeableState.checksFailed.displayReason)")
        #expect(StatusBarView.iconSlotLabel(mr, isHovering: true) == untrack)
        #expect(StatusBarView.iconSlotLabel(mr, isHovering: false) == open)
        for label in [untrack, open] {
            #expect(label.contains(Forge.github.refNoun) == false)
            #expect(label.contains("#412") == false)
        }
    }
}
