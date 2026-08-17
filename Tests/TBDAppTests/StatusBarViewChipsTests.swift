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

    @Test("the overlay names the PR, its title, its state and the age of that reading")
    func overlayWithTitle() {
        let now = Date(timeIntervalSince1970: 1_700_007_200)
        let card = StatusBarView.chipHoverCard(
            chip(state: .checksFailed,
                 title: "Fix the login timeout",
                 observedAt: now.addingTimeInterval(-7200)),
            now: now)
        #expect(card.title == "Fix the login timeout")
        #expect(card.rows.contains { $0.label == "PR" && $0.value == "#412" })
        let state = card.rows.first { $0.label == "State" }
        #expect(state?.value == PRMergeableState.checksFailed.displayReason)
        // The age rides with the state — a display-tier cache is never rendered
        // as current truth. Shared wording with the toolbar and sidebar.
        #expect(state?.caption == "checked 2h ago")
        #expect(state?.caption == PRFreshness.checkedLabel(
            observedAt: now.addingTimeInterval(-7200), now: now))
    }

    @Test("a chip with no observed title renders no title line, not a placeholder")
    func overlayWithoutTitle() {
        let card = StatusBarView.chipHoverCard(chip(title: nil))
        #expect(card.title == nil)
        // The number and state are still worth showing.
        #expect(card.rows.contains { $0.label == "PR" && $0.value == "#412" })
        #expect(card.rows.contains { $0.label == "State" })
    }

    @Test("a whitespace-only title counts as absent")
    func overlayBlankTitle() {
        #expect(StatusBarView.chipHoverCard(chip(title: "   \n")).title == nil)
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

        let value = StatusBarView.chipHoverCard(chip).rows.first { $0.label == "State" }?.value
        #expect(value == "Changes requested by reviewer")
        #expect(value != PRMergeableState.blocked.displayReason)
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
        #expect(card.rows.contains { $0.label == "PR" && $0.value == "#412" })
        let state = card.rows.first { $0.label == "State" }
        #expect(state?.value == StatusBarView.unobservedStateValue)
        #expect(state?.caption == PRFreshness.checkedLabel(observedAt: nil, now: Date()))
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

        let caption = StatusBarView.chipHoverCard(model.chips[0], now: now)
            .rows.first { $0.label == "State" }?.caption
        #expect(caption == "checked 2h ago · last check did not resolve (gh unauthenticated)")

        // A settled attempt adds nothing — the clause is a caveat, not a field.
        let settled = StatusBarView.prChips(
            [binding(412, .mergeable, observedAt: observed)],
            observation: PRObservation(outcome: .none, observedAt: observed))
        #expect(StatusBarView.chipHoverCard(settled.chips[0], now: now)
            .rows.first { $0.label == "State" }?.caption == "checked 2h ago")
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
}
