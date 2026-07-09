import AppKit
import SwiftUI
import Testing

@testable import TBDApp
@testable import TBDShared

@Suite("PRButtonLabel")
@MainActor
struct PRButtonLabelTests {
    private static func makeStatus(
        number: Int = 42,
        url: String? = nil,
        state: PRMergeableState = .mergeable,
        reason: String? = nil,
        mergeQueuePosition: Int? = nil
    ) -> PRStatus {
        PRStatus(number: number, url: url ?? "https://example.com/\(number)", state: state,
                 reason: reason, mergeQueuePosition: mergeQueuePosition)
    }

    private static func makeKey(
        worktreeID: UUID,
        worktreeFound: Bool = true,
        armed: Bool = false,
        hibernateArmed: Bool = false,
        blocked: Bool = false,
        prStatus: PRStatus,
        colorScheme: ColorScheme = .light
    ) -> String {
        PRButtonLabel.prSplitButtonID(
            worktreeID: worktreeID,
            worktreeFound: worktreeFound,
            armed: armed,
            hibernateArmed: hibernateArmed,
            blocked: blocked,
            prStatus: prStatus,
            colorScheme: colorScheme
        )
    }

    private static func makeLabel(
        prStatus: PRStatus? = nil,
        isAutoArchiveArmed: Bool = false,
        isAutoHibernateArmed: Bool = false
    ) -> PRButtonLabel {
        PRButtonLabel(
            prStatus: prStatus ?? makeStatus(),
            isAutoArchiveArmed: isAutoArchiveArmed,
            isAutoHibernateArmed: isAutoHibernateArmed
        )
    }

    // MARK: - bakedWidth (three-state: 0, 1, or 2 badges)

    @Test("bakedWidth is the bare icon side when neither flag is armed")
    func bakedWidthUnarmed() {
        let label = Self.makeLabel()
        // 12 (iconSide) with no badges.
        #expect(label.bakedWidth == PRButtonLabel.iconSide)
        #expect(label.bakedWidth == 12)
        #expect(label.badgeCount == 0)
    }

    @Test("bakedWidth widens by one gap + badge when only auto-archive is armed")
    func bakedWidthArchiveArmed() {
        let label = Self.makeLabel(isAutoArchiveArmed: true)
        // 12 + 1*(3 + 12) = 27
        let expected = PRButtonLabel.iconSide + (PRButtonLabel.badgeGap + PRButtonLabel.iconSide)
        #expect(label.bakedWidth == expected)
        #expect(label.bakedWidth == 27)
        #expect(label.badgeCount == 1)
    }

    @Test("bakedWidth widens by one gap + badge when only auto-hibernate is armed")
    func bakedWidthHibernateArmed() {
        let label = Self.makeLabel(isAutoHibernateArmed: true)
        // 12 + 1*(3 + 12) = 27 — same single-badge width as archive-only.
        let expected = PRButtonLabel.iconSide + (PRButtonLabel.badgeGap + PRButtonLabel.iconSide)
        #expect(label.bakedWidth == expected)
        #expect(label.bakedWidth == 27)
        #expect(label.badgeCount == 1)
    }

    @Test("bakedWidth widens by two gaps + badges when both flags are armed")
    func bakedWidthBothArmed() {
        let label = Self.makeLabel(isAutoArchiveArmed: true, isAutoHibernateArmed: true)
        // 12 + 2*(3 + 12) = 42
        let expected = PRButtonLabel.iconSide + 2 * (PRButtonLabel.badgeGap + PRButtonLabel.iconSide)
        #expect(label.bakedWidth == expected)
        #expect(label.bakedWidth == 42)
        #expect(label.badgeCount == 2)
    }

    @Test("bakedWidth stays a single square for a queued PR for every armed combination")
    func bakedWidthQueuedSuppressesBothBadges() {
        // Queue mode supersedes BOTH armed badges: the bus is one full-color
        // square with its position baked in, so the label must not reserve any
        // extra gap+badge width regardless of which flags are armed.
        for archive in [false, true] {
            for hibernate in [false, true] {
                let label = Self.makeLabel(
                    prStatus: Self.makeStatus(state: .pending, mergeQueuePosition: 2),
                    isAutoArchiveArmed: archive,
                    isAutoHibernateArmed: hibernate
                )
                #expect(label.isMergeQueued)
                #expect(label.badgeCount == 0)
                #expect(label.bakedWidth == PRButtonLabel.iconSide)
            }
        }
    }

    @Test("coloredIcon bakes a single square for a queued PR (bus, untinted)")
    func coloredIconQueuedIsSquare() throws {
        let label = Self.makeLabel(
            prStatus: Self.makeStatus(state: .pending, mergeQueuePosition: 3),
            isAutoArchiveArmed: true,
            isAutoHibernateArmed: true
        )
        let presentation = try #require(PRStatusPresentation.make(for: label.prStatus))
        let icon = try #require(label.coloredIcon(presentation, colorScheme: .light))
        #expect(icon.size == NSSize(width: PRButtonLabel.iconSide, height: PRButtonLabel.iconSide))
        #expect(icon.isTemplate == false)
    }

    // MARK: - coloredIcon baked image size (0, 1, 2 badges)

    @Test("coloredIcon baked image width matches the armed-badge count")
    func coloredIconSizeMatchesArmedState() throws {
        let presentation = PRStatusPresentation(glyph: .asset("git-merge"), colorSemantic: .merged)

        let none = try #require(Self.makeLabel().coloredIcon(presentation, colorScheme: .light))
        let archive = try #require(
            Self.makeLabel(isAutoArchiveArmed: true).coloredIcon(presentation, colorScheme: .light))
        let hibernate = try #require(
            Self.makeLabel(isAutoHibernateArmed: true).coloredIcon(presentation, colorScheme: .light))
        let both = try #require(
            Self.makeLabel(isAutoArchiveArmed: true, isAutoHibernateArmed: true)
                .coloredIcon(presentation, colorScheme: .light))

        let side = PRButtonLabel.iconSide
        let step = PRButtonLabel.badgeGap + PRButtonLabel.iconSide
        #expect(none.size == NSSize(width: side, height: side))
        #expect(archive.size == NSSize(width: side + step, height: side))
        #expect(hibernate.size == NSSize(width: side + step, height: side))
        #expect(both.size == NSSize(width: side + 2 * step, height: side))
        for icon in [none, archive, hibernate, both] {
            #expect(icon.isTemplate == false)
        }
    }

    // The baked-icon cache is keyed on BOTH armed flags. If hibernateArmed were
    // omitted from the key, an armed/unarmed pair sharing the same asset name,
    // colorSemantic, and colorScheme would render from the same cached bitmap
    // and the moon.zzz badge would silently never appear. The cache key isn't
    // reachable from tests, so assert the observable consequence: differing
    // hibernateArmed yields differently-sized baked images.
    @Test("coloredIcon width reflects hibernateArmed independently (cache-key guard)")
    func coloredIconWidthDistinguishesHibernateArmed() throws {
        let presentation = PRStatusPresentation(glyph: .asset("git-merge"), colorSemantic: .merged)

        // archive fixed off: hibernate off → 1 square, hibernate on → 1 badge.
        let hOff = try #require(Self.makeLabel().coloredIcon(presentation, colorScheme: .light))
        let hOn = try #require(
            Self.makeLabel(isAutoHibernateArmed: true).coloredIcon(presentation, colorScheme: .light))
        #expect(hOff.size.width != hOn.size.width)

        // archive fixed on: hibernate off → 1 badge, hibernate on → 2 badges.
        let aOnly = try #require(
            Self.makeLabel(isAutoArchiveArmed: true).coloredIcon(presentation, colorScheme: .light))
        let aAndH = try #require(
            Self.makeLabel(isAutoArchiveArmed: true, isAutoHibernateArmed: true)
                .coloredIcon(presentation, colorScheme: .light))
        #expect(aOnly.size.width != aAndH.size.width)
    }

    // MARK: - aspectFitRect (badge distortion fix)

    @Test("aspectFitRect preserves aspect ratio and centers within the slot")
    func aspectFitRectPreservesAspect() {
        let slot = NSRect(x: 15, y: 0, width: 12, height: 12)
        // archivebox-like non-square intrinsic size
        let fitted = PRButtonLabel.aspectFitRect(for: NSSize(width: 16, height: 14), in: slot)

        // Aspect ratio preserved (16:14 == 8:7)
        #expect(abs(fitted.width / fitted.height - 16.0 / 14.0) < 0.0001)
        // Fits within the slot
        #expect(fitted.width <= slot.width + 0.0001)
        #expect(fitted.height <= slot.height + 0.0001)
        // Wider dimension fills the slot
        #expect(abs(fitted.width - slot.width) < 0.0001)
        // Centered
        #expect(abs(fitted.midX - slot.midX) < 0.0001)
        #expect(abs(fitted.midY - slot.midY) < 0.0001)
    }

    @Test("aspectFitRect returns the slot unchanged for degenerate sizes")
    func aspectFitRectDegenerate() {
        let slot = NSRect(x: 0, y: 0, width: 12, height: 12)
        #expect(PRButtonLabel.aspectFitRect(for: .zero, in: slot) == slot)
    }

    // MARK: - prSplitButtonID (.id key must cover everything the label/menu render)

    @Test("id key differs between armed and unarmed")
    func idKeyDiffersByArmed() {
        let worktreeID = UUID()
        let status = Self.makeStatus()
        let armed = Self.makeKey(worktreeID: worktreeID, armed: true, prStatus: status)
        let unarmed = Self.makeKey(worktreeID: worktreeID, armed: false, prStatus: status)
        #expect(armed != unarmed)
    }

    // Stale-checkmark regression guard: AppKit materializes the split-button
    // NSMenu once, so the hibernate Toggle's checkmark would freeze at its
    // first-render value unless hibernateArmed is part of the .id key.
    @Test("id key differs between hibernate-armed and not, all else equal")
    func idKeyDiffersByHibernateArmed() {
        let worktreeID = UUID()
        let status = Self.makeStatus()
        let hibernateArmed = Self.makeKey(worktreeID: worktreeID, hibernateArmed: true, prStatus: status)
        let notArmed = Self.makeKey(worktreeID: worktreeID, hibernateArmed: false, prStatus: status)
        #expect(hibernateArmed != notArmed)
    }

    @Test("id key differs between PR states, PR numbers, and PR urls")
    func idKeyDiffersByPRStatus() {
        let worktreeID = UUID()
        let open = Self.makeKey(worktreeID: worktreeID, prStatus: Self.makeStatus(state: .mergeable))
        let merged = Self.makeKey(worktreeID: worktreeID, prStatus: Self.makeStatus(state: .merged))
        #expect(open != merged)

        let otherNumber = Self.makeKey(worktreeID: worktreeID, prStatus: Self.makeStatus(number: 43))
        #expect(open != otherNumber)

        // url is captured by the split button's primaryAction, so a re-pointed
        // PR (same number, new url) must recreate the toolbar item too.
        let otherURL = Self.makeKey(
            worktreeID: worktreeID,
            prStatus: Self.makeStatus(url: "https://example.com/elsewhere/42")
        )
        #expect(open != otherURL)

        // reason is deliberately NOT keyed: nothing the split button renders
        // reads it (PRStatusPresentation.make switches only on state), so a
        // reason-only change must NOT force a spurious toolbar-item rebuild.
        let withReason = Self.makeKey(
            worktreeID: worktreeID,
            prStatus: Self.makeStatus(reason: "review required")
        )
        #expect(open == withReason)
    }

    @Test("PRStatus field-count tripwire for prSplitButtonID")
    func prStatusFieldCountTripwire() {
        // If this fails, a PRStatus field was added. prSplitButtonID
        // hand-enumerates the fields the split button renders (number, state,
        // url — reason deliberately excluded), so a new field is otherwise
        // silently unkeyed: decide whether the split button renders it and
        // update prSplitButtonID (and this count) accordingly.
        // 8 = number, state, url, reason + the nightwatch gate metadata
        // (files, commits, authorWorktreeID), which the split button does NOT
        // render — deliberately excluded like reason, else every metadata
        // fetch would force a spurious toolbar-item rebuild — plus
        // mergeQueuePosition, which the split button DOES render (bus glyph +
        // baked position badge) and which IS keyed.
        let status = Self.makeStatus()
        #expect(Mirror(reflecting: status).children.count == 8)
    }

    @Test("id key differs by merge-queue position so a queue move rebuilds the item")
    func idKeyDiffersByMergeQueuePosition() {
        let worktreeID = UUID()
        // A queued PR keeps state UNKNOWN→.pending as it advances, so state
        // alone can't distinguish position 2 from 1; the baked position badge
        // would go stale unless mergeQueuePosition is part of the key.
        let notQueued = Self.makeKey(worktreeID: worktreeID, prStatus: Self.makeStatus(state: .pending))
        let atTwo = Self.makeKey(worktreeID: worktreeID, prStatus: Self.makeStatus(state: .pending, mergeQueuePosition: 2))
        let atOne = Self.makeKey(worktreeID: worktreeID, prStatus: Self.makeStatus(state: .pending, mergeQueuePosition: 1))
        #expect(notQueued != atTwo)
        #expect(atOne != atTwo)
    }

    @Test("id key differs between blocked states, color schemes, and worktrees")
    func idKeyDiffersByBlockedSchemeAndWorktree() {
        let worktreeID = UUID()
        let status = Self.makeStatus()
        let base = Self.makeKey(worktreeID: worktreeID, prStatus: status)

        let blocked = Self.makeKey(worktreeID: worktreeID, blocked: true, prStatus: status)
        #expect(base != blocked)

        let dark = Self.makeKey(worktreeID: worktreeID, prStatus: status, colorScheme: .dark)
        #expect(base != dark)

        let otherWorktree = Self.makeKey(worktreeID: UUID(), prStatus: status)
        #expect(base != otherWorktree)
    }

    @Test("id key differs when the worktree row appears")
    func idKeyDiffersByWorktreeFound() {
        let worktreeID = UUID()
        let status = Self.makeStatus()
        // The menu's only item (the auto-archive Toggle) is gated on the
        // worktree row having loaded; a menu materialized before it appears
        // must be recreated once it does, or it stays permanently empty.
        let beforeRowLoads = Self.makeKey(worktreeID: worktreeID, worktreeFound: false, prStatus: status)
        let afterRowLoads = Self.makeKey(worktreeID: worktreeID, worktreeFound: true, prStatus: status)
        #expect(beforeRowLoads != afterRowLoads)
    }

    @Test("id key is stable for identical inputs")
    func idKeyStable() {
        let worktreeID = UUID()
        let status = Self.makeStatus()
        let first = Self.makeKey(
            worktreeID: worktreeID, worktreeFound: true, armed: true, blocked: true,
            prStatus: status, colorScheme: .dark)
        let second = Self.makeKey(
            worktreeID: worktreeID, worktreeFound: true, armed: true, blocked: true,
            prStatus: status, colorScheme: .dark)
        #expect(first == second)
    }
}
