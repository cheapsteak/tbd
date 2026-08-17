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
        observedAt: Date? = nil
    ) -> PRBinding {
        let url = "https://github.com/acme/acme-prod/pull/\(number)"
        return PRBinding(
            worktreeID: worktreeID, owner: "acme", repo: "acme-prod",
            number: number, url: url,
            title: title,
            status: state.map {
                PRStatus(number: number, url: url, state: $0, observedAt: observedAt)
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
        observedAt: Date? = nil
    ) -> StatusBarView.PRChip {
        StatusBarView.prChips([
            binding(number, state, title: title, observedAt: observedAt)
        ]).chips[0]
    }

    @Test("the overlay's headline names the PR, its state and its title on one line")
    func overlayWithTitle() {
        let now = Date(timeIntervalSince1970: 1_700_007_200)
        let card = StatusBarView.chipHoverCard(
            chip(state: .checksFailed,
                 title: "Fix the login timeout",
                 observedAt: now.addingTimeInterval(-7200)),
            now: now)
        #expect(card.title == "PR#412 (\(PRMergeableState.checksFailed.displayReason))"
                + " - Fix the login timeout")
        // No labelled grid: the three facts are the headline, and the only row
        // left is the one naming the click.
        #expect(card.rows.count == 1)
        #expect(card.rows.allSatisfy { $0.label == nil })
        // The age rides under the headline — a display-tier cache is never
        // rendered as current truth. Shared wording with the toolbar and sidebar.
        #expect(card.titleCaption == "checked 2h ago")
        #expect(card.titleCaption == PRFreshness.checkedLabel(
            observedAt: now.addingTimeInterval(-7200), now: now))
    }

    /// Every part of the headline but the number is optional, and an absent one
    /// is *omitted* rather than filled: no empty `()`, and no dangling ` - `.
    @Test("the headline degrades to whichever of state and title were observed")
    func headlineDegradesByOmission() {
        let state = PRMergeableState.merged.displayReason
        #expect(StatusBarView.chipHeadline(
            chip(state: .merged, title: "Relay the GitHub event"))
            == "PR#412 (\(state)) - Relay the GitHub event")
        #expect(StatusBarView.chipHeadline(chip(state: .merged, title: nil))
                == "PR#412 (\(state))")
        #expect(StatusBarView.chipHeadline(chip(state: nil, title: "Relay the GitHub event"))
                == "PR#412 - Relay the GitHub event")
        #expect(StatusBarView.chipHeadline(chip(state: nil, title: nil)) == "PR#412")
        // …and no combination leaves a separator with nothing after it.
        for headline in [StatusBarView.chipHeadline(chip(state: .merged, title: nil)),
                         StatusBarView.chipHeadline(chip(state: nil, title: nil)),
                         StatusBarView.chipHeadline(chip(state: nil, title: "x"))] {
            #expect(headline.hasSuffix(" - ") == false)
            #expect(headline.contains("()") == false)
        }
    }

    @Test("a whitespace-only title counts as absent")
    func overlayBlankTitle() {
        let card = StatusBarView.chipHoverCard(chip(state: nil, title: "   \n"))
        #expect(card.title == "PR#412")
        #expect(card.title?.contains("-") == false)
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
        // …and it is the same string the overflow menu row is built from.
        #expect(PRBindingPresentation.menuRows([binding])[0].title
            .contains("Changes requested by reviewer"))
        // …and the tooltip and VoiceOver hint beside the card agree with it,
        // rather than falling back to the generic state label.
        #expect(StatusBarView.openLabel(chip)
            == "Open PR #412 — Changes requested by reviewer")
    }

    @Test("a chip with no observed status still gets a number, and says the age is unknown")
    func overlayWithoutStatus() {
        let card = StatusBarView.chipHoverCard(chip(state: nil, observedAt: nil))
        #expect(card.title == "PR#412")
        // A missing stamp is an unknown check time rather than silence — the
        // card never renders a state, or the absence of one, without its age.
        #expect(card.titleCaption == PRFreshness.checkedLabel(observedAt: nil, now: Date()))
        #expect(card.titleCaption == "last checked at an unknown time")
    }

    /// The toolbar and sidebar both append "last check did not resolve" after
    /// the age. A chip that dropped it would render the more confident of two
    /// readings of one fact — the exact drift `PRFreshness` exists to prevent.
    @Test("the overlay says when the last poll attempt did not resolve")
    func overlayCarriesTheUndeterminedClause() {
        let now = Date(timeIntervalSince1970: 1_700_007_200)
        let observed = now.addingTimeInterval(-7200)
        let observation = PRObservation(
            outcome: .undetermined(cause: "gh unauthenticated"), observedAt: observed)
        let model = StatusBarView.prChips(
            [binding(412, .mergeable, observedAt: observed)], observation: observation)

        let caption = StatusBarView.chipHoverCard(model.chips[0], now: now).titleCaption
        #expect(caption == "checked 2h ago · last check did not resolve (gh unauthenticated)")

        // A settled attempt adds nothing — the clause is a caveat, not a field.
        let settled = StatusBarView.prChips(
            [binding(412, .mergeable, observedAt: observed)],
            observation: PRObservation(outcome: .none, observedAt: observed))
        #expect(StatusBarView.chipHoverCard(settled.chips[0], now: now)
            .titleCaption == "checked 2h ago")
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

    // MARK: - Naming the click under the pointer

    /// The chip packs two click targets into about twenty points, and the
    /// tooltip that would have distinguished them loses a race it cannot win:
    /// the macOS help-tag delay is longer than the card's 0.55s floor, so the
    /// card is already up by the time a tag would appear. The card therefore
    /// has to say it itself.
    @Test("the overlay names the untrack gesture while the pointer is on the xmark")
    func overlayNamesTheUntrackAction() {
        let card = StatusBarView.chipHoverCard(chip(title: "Fix the login timeout"),
                                               untrackTarget: true)
        #expect(card.rows.last?.value == "Click to stop tracking this PR in this worktree")
        // It names the worktree scope for the same reason `untrackLabel` does:
        // the gesture removes an association, not the pull request.
        #expect(card.rows.last?.value.contains("this worktree") == true)
    }

    @Test("the overlay names the open gesture anywhere else on the chip")
    func overlayNamesTheOpenAction() {
        let card = StatusBarView.chipHoverCard(chip(title: "Fix the login timeout"))
        #expect(card.rows.last?.value == "Click to open this PR on GitHub")
        // Default: a chip is an open target until the pointer reaches the slot.
        #expect(card.rows.last?.value
                == StatusBarView.chipHoverCard(chip(title: "Fix the login timeout"),
                                               untrackTarget: false).rows.last?.value)
    }

    /// A row that appeared and disappeared would resize the card under the
    /// pointer — the jitter this line exists to cure. So the row is always
    /// there, in the same place, and only its sentence swaps.
    @Test("only the action row's text differs between the two states")
    func onlyTheActionRowDiffers() {
        let now = Date(timeIntervalSince1970: 1_700_007_200)
        let one = chip(state: .checksFailed,
                       title: "Fix the login timeout",
                       observedAt: now.addingTimeInterval(-7200))
        let open = StatusBarView.chipHoverCard(one, untrackTarget: false, now: now)
        let untrack = StatusBarView.chipHoverCard(one, untrackTarget: true, now: now)

        // The headline and its age are untouched…
        #expect(open.title == untrack.title)
        #expect(open.titleCaption == untrack.titleCaption)
        #expect(open.titleCaption == "checked 2h ago")
        #expect(open.rows.count == untrack.rows.count)
        #expect(open.rows.count == 1)
        // …and only the action row's sentence differs.
        #expect(open.rows[0].value != untrack.rows[0].value)
        // The card is re-rendered on model INEQUALITY, so the swap only reaches
        // the screen because the two models genuinely differ.
        #expect(open != untrack)
    }

    /// The card is sized to fit its content, so two sentences of different
    /// length would resize it as the pointer crossed onto the slot. Each state
    /// carries the other sentence as a laid-out-but-hidden peer, which pins the
    /// row — and therefore the card — to the larger of the two in both axes.
    @Test("each action row reserves room for the sentence it can swap to")
    func actionRowReservesBothSentences() {
        let open = StatusBarView.chipHoverCard(chip()).rows.last
        let untrack = StatusBarView.chipHoverCard(chip(), untrackTarget: true).rows.last
        #expect(open?.alternateValue == untrack?.value)
        #expect(untrack?.alternateValue == open?.value)
        // The reservation is worth having only because the two differ enough to
        // reflow — a peer equal to the value would be decoration.
        #expect(open?.value != untrack?.value)
        // It is the card's only row, so the reservation covers every row that
        // could resize it — the headline and its age do not swap.
        #expect(StatusBarView.chipHoverCard(chip()).rows.count == 1)
    }

    @Test("the action line is a function of which target the pointer is on")
    func chipActionValueFollowsTheTarget() {
        #expect(StatusBarView.chipActionValue(untrackTarget: true)
                == StatusBarView.chipUntrackActionValue)
        #expect(StatusBarView.chipActionValue(untrackTarget: false)
                == StatusBarView.chipOpenActionValue)
        #expect(StatusBarView.chipActionValue(untrackTarget: true)
                != StatusBarView.chipActionValue(untrackTarget: false))
        // Both describe the click rather than restating the PR's number or
        // state, which the rows above them already carry.
        #expect(StatusBarView.chipOpenActionValue.hasPrefix("Click to"))
        #expect(StatusBarView.chipUntrackActionValue.hasPrefix("Click to"))
        #expect(StatusBarView.chipOpenActionValue.contains("#412") == false)
    }

    /// A synthetic chip has no title and a never-polled one has no status, and
    /// both are still clickable — the line that says what the click does cannot
    /// be a passenger of the rows that happen to be missing.
    @Test("a chip with no title and one with no status still say what a click does")
    func actionRowSurvivesAbsentFields() {
        let untitled = StatusBarView.chipHoverCard(chip(title: nil), untrackTarget: true)
        #expect(untitled.title?.contains(" - ") == false)
        #expect(untitled.rows.last?.value == StatusBarView.chipUntrackActionValue)

        let unobserved = StatusBarView.chipHoverCard(chip(state: nil, observedAt: nil))
        #expect(unobserved.title == "PR#412")
        #expect(unobserved.rows.last?.value == StatusBarView.chipOpenActionValue)
        #expect(unobserved.rows.last?.alternateValue == StatusBarView.chipUntrackActionValue)
    }
}
