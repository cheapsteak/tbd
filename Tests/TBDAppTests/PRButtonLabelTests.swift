import AppKit
import SwiftUI
import Testing

@testable import TBDApp
@testable import TBDShared

@Suite("PRButtonLabel")
struct PRButtonLabelTests {
    private static func makeStatus(
        number: Int = 42,
        url: String? = nil,
        state: PRMergeableState = .mergeable,
        reason: String? = nil
    ) -> PRStatus {
        PRStatus(number: number, url: url ?? "https://example.com/\(number)", state: state, reason: reason)
    }

    private static func makeKey(
        worktreeID: UUID,
        worktreeFound: Bool = true,
        armed: Bool = false,
        blocked: Bool = false,
        prStatus: PRStatus,
        colorScheme: ColorScheme = .light
    ) -> String {
        PRButtonLabel.prSplitButtonID(
            worktreeID: worktreeID,
            worktreeFound: worktreeFound,
            armed: armed,
            blocked: blocked,
            prStatus: prStatus,
            colorScheme: colorScheme
        )
    }

    // MARK: - bakedWidth (armed gate, both branches)

    @Test("bakedWidth is the bare icon side when auto-archive is not armed")
    func bakedWidthUnarmed() {
        let label = PRButtonLabel(prStatus: Self.makeStatus(), isAutoArchiveArmed: false)
        #expect(label.bakedWidth == PRButtonLabel.iconSide)
    }

    @Test("bakedWidth widens by gap + badge when auto-archive is armed")
    func bakedWidthArmed() {
        let label = PRButtonLabel(prStatus: Self.makeStatus(), isAutoArchiveArmed: true)
        let expected = PRButtonLabel.iconSide + PRButtonLabel.badgeGap + PRButtonLabel.iconSide
        #expect(label.bakedWidth == expected)
        #expect(label.bakedWidth > PRButtonLabel(prStatus: Self.makeStatus(), isAutoArchiveArmed: false).bakedWidth)
    }

    // MARK: - coloredIcon baked image size (armed gate, both branches)

    @MainActor
    @Test("coloredIcon bakes a square image when not armed and a wide badge composite when armed")
    func coloredIconSizeMatchesArmedState() throws {
        let unarmed = PRButtonLabel(prStatus: Self.makeStatus(), isAutoArchiveArmed: false)
        let armed = PRButtonLabel(prStatus: Self.makeStatus(), isAutoArchiveArmed: true)
        let presentation = PRStatusPresentation(iconName: "git-merge", colorSemantic: .merged)

        let unarmedIcon = try #require(unarmed.coloredIcon(presentation, colorScheme: .light))
        let armedIcon = try #require(armed.coloredIcon(presentation, colorScheme: .light))

        #expect(unarmedIcon.size == NSSize(width: PRButtonLabel.iconSide, height: PRButtonLabel.iconSide))
        #expect(armedIcon.size == NSSize(
            width: PRButtonLabel.iconSide + PRButtonLabel.badgeGap + PRButtonLabel.iconSide,
            height: PRButtonLabel.iconSide
        ))
        #expect(unarmedIcon.isTemplate == false)
        #expect(armedIcon.isTemplate == false)
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

        // reason feeds the blocked-state presentation, so it must be keyed too.
        let withReason = Self.makeKey(
            worktreeID: worktreeID,
            prStatus: Self.makeStatus(reason: "review required")
        )
        #expect(open != withReason)
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
