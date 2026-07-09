import AppKit
import Testing
@testable import TBDApp
@testable import TBDShared

@Suite("PR status presentation")
struct PRStatusPresentationTests {
    @Test("conflict-only worktrees do not get a PR icon")
    func conflictOnlyWorktreeHasNoPRPresentation() {
        let presentation = PRStatusPresentation.make(for: nil)

        #expect(presentation == nil)
    }

    @Test("merged PRs use purple merge icon")
    func mergedPresentation() {
        let presentation = PRStatusPresentation.make(for: PRStatus(number: 1, url: "https://example.com/1", state: .merged))

        #expect(presentation?.glyph == .asset("git-merge"))
        #expect(presentation?.colorSemantic == .merged)
    }

    @Test("mergeable PRs use green pull request icon")
    func mergeablePresentation() {
        let presentation = PRStatusPresentation.make(for: PRStatus(number: 2, url: "https://example.com/2", state: .mergeable))

        #expect(presentation?.glyph == .asset("git-pull-request"))
        #expect(presentation?.colorSemantic == .mergeable)
    }

    @Test("draft PRs use grey pull request icon")
    func draftPresentation() {
        let presentation = PRStatusPresentation.make(for: PRStatus(number: 3, url: "https://example.com/3", state: .draft))

        #expect(presentation?.glyph == .asset("git-pull-request"))
        #expect(presentation?.colorSemantic == .draft)
    }

    @Test("PRs with failing checks use red pull request icon")
    func checksFailedPresentation() {
        let presentation = PRStatusPresentation.make(for: PRStatus(number: 4, url: "https://example.com/4", state: .checksFailed))

        #expect(presentation?.glyph == .asset("git-pull-request"))
        #expect(presentation?.colorSemantic == .nonMergeable)
    }

    @Test("changes-requested PRs are known non-mergeable")
    func changesRequestedPresentation() {
        let presentation = PRStatusPresentation.make(for: PRStatus(number: 5, url: "https://example.com/5", state: .changesRequested))

        #expect(presentation?.glyph == .asset("git-pull-request"))
        #expect(presentation?.colorSemantic == .nonMergeable)
    }

    @Test("pending PRs use yellow pull request icon")
    func pendingPresentation() {
        let presentation = PRStatusPresentation.make(for: PRStatus(number: 6, url: "https://example.com/6", state: .pending))

        #expect(presentation?.glyph == .asset("git-pull-request"))
        #expect(presentation?.colorSemantic == .pending)
    }

    @Test("blocked PRs use red pull request icon")
    func blockedPresentation() {
        let presentation = PRStatusPresentation.make(for: PRStatus(number: 7, url: "https://example.com/7", state: .blocked))

        #expect(presentation?.glyph == .asset("git-pull-request"))
        #expect(presentation?.colorSemantic == .nonMergeable)
    }

    @Test("closed PRs use red closed icon")
    func closedPresentation() {
        let presentation = PRStatusPresentation.make(for: PRStatus(number: 8, url: "https://example.com/8", state: .closed))

        #expect(presentation?.glyph == .asset("git-pull-request-closed"))
        #expect(presentation?.colorSemantic == .nonMergeable)
    }

    // MARK: - Merge-queue bus (the mergeQueuePosition gate)

    /// Branch OFF: with no queue position, every state keeps its ordinary asset
    /// icon and carries no badge. Complements the per-state tests above by
    /// asserting the bus short-circuit did NOT fire.
    @Test("no merge-queue position keeps the ordinary asset icon and no badge", arguments: [
        PRMergeableState.pending, .blocked, .changesRequested, .checksFailed,
        .draft, .mergeable, .merged, .closed
    ])
    func noQueuePositionKeepsAssetIcon(state: PRMergeableState) {
        let presentation = PRStatusPresentation.make(
            for: PRStatus(number: 1, url: "https://github.com/acme/acme-prod/pull/1", state: state)
        )
        if case .asset = presentation?.glyph {} else {
            Issue.record("expected an asset glyph for \(state) with no queue position")
        }
        #expect(presentation?.badge == nil)
    }

    /// Branch ON: any state with a queue position short-circuits to the bus
    /// emoji, and the badge equals the 1-indexed position.
    @Test("a merge-queue position renders the bus glyph with the position as its badge", arguments: [
        (PRMergeableState.pending, 1),
        (.mergeable, 2),
        (.blocked, 3),
        (.checksFailed, 7)
    ])
    func queuePositionRendersBus(state: PRMergeableState, position: Int) {
        let presentation = PRStatusPresentation.make(
            for: PRStatus(number: 1, url: "https://github.com/acme/acme-prod/pull/1",
                          state: state, mergeQueuePosition: position)
        )
        #expect(presentation?.glyph == .emoji(PRStatusPresentation.mergeQueueEmoji))
        #expect(presentation?.badge == position)
    }

    @Test("front-of-queue position is 1-indexed, not 0")
    func frontOfQueueIsOne() {
        let presentation = PRStatusPresentation.make(
            for: PRStatus(number: 5, url: "https://github.com/acme/acme-prod/pull/5",
                          state: .pending, mergeQueuePosition: 1)
        )
        #expect(presentation?.badge == 1)
    }

    // MARK: - Queue badge rendering (double-digit positions must not clip)

    /// The badge chip must stay fully inside the icon square for 1-, 2-, and
    /// 3-digit positions — the old fixed-square chip truncated anything past a
    /// single digit, and a real merge queue routinely has 10+ entries.
    @MainActor
    @Test("queue badge chip stays within the icon bounds for 1-, 2-, and 3-digit positions",
          arguments: [1, 10, 99, 100])
    func queueBadgeStaysInBounds(position: Int) {
        let iconRect = NSRect(x: 0, y: 0, width: 12, height: 12)
        let layout = PRStatusPresentation.queueBadgeLayout(position: position, in: iconRect)
        #expect(iconRect.contains(layout.chipRect),
                "chip \(layout.chipRect) escaped icon \(iconRect) for position \(position)")
        // The text also fits inside its own chip (no glyph clipping).
        #expect(layout.textSize.width <= layout.chipRect.width + 0.01)
    }

    /// Clamp boundary: 99 renders literally, 100 collapses to "99+".
    @MainActor
    @Test("positions past 99 clamp to \"99+\"")
    func queueBadgeClampsPast99() {
        let iconRect = NSRect(x: 0, y: 0, width: 12, height: 12)
        #expect(PRStatusPresentation.queueBadgeLayout(position: 99, in: iconRect).text == "99")
        #expect(PRStatusPresentation.queueBadgeLayout(position: 100, in: iconRect).text == "99+")
        #expect(PRStatusPresentation.queueBadgeLayout(position: 1234, in: iconRect).text == "99+")
    }

    /// The rendered bitmap must actually differ between positions, proving the
    /// cache key varies and the badge is redrawn per position (single vs double
    /// digit produce visibly different chips).
    @MainActor
    @Test("busImage differs between single- and double-digit positions")
    func busImageDiffersByPosition() throws {
        let side: CGFloat = 12
        let one = try #require(PRStatusPresentation.busImage(position: 1, side: side).tiffRepresentation)
        let ten = try #require(PRStatusPresentation.busImage(position: 10, side: side).tiffRepresentation)
        let ninetyNine = try #require(PRStatusPresentation.busImage(position: 99, side: side).tiffRepresentation)
        #expect(one != ten)
        #expect(ten != ninetyNine)
        #expect(one != ninetyNine)
    }
}
