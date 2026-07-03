import AppKit
import SwiftUI
import Testing

@testable import TBDApp
@testable import TBDShared

@Suite("PRButtonLabel")
struct PRButtonLabelTests {
    private static func makeStatus(
        number: Int = 42,
        state: PRMergeableState = .mergeable
    ) -> PRStatus {
        PRStatus(number: number, url: "https://example.com/\(number)", state: state)
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
    func coloredIconSizeMatchesArmedState() {
        let unarmed = PRButtonLabel(prStatus: Self.makeStatus(), isAutoArchiveArmed: false)
        let armed = PRButtonLabel(prStatus: Self.makeStatus(), isAutoArchiveArmed: true)

        // Bundle.module SVG resources should resolve under `swift test`; if
        // they ever don't in some environment, skip the size assertions
        // rather than fail on missing resources (per repo test guidance).
        guard let unarmedIcon = unarmed.coloredIcon("git-merge", nsColor: .systemPurple),
              let armedIcon = armed.coloredIcon("git-merge", nsColor: .systemPurple) else {
            // Icon SVG resources unavailable in this test environment — skip
            // the size checks rather than fail on missing bundle resources.
            return
        }

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
        let armed = PRButtonLabel.prSplitButtonID(
            worktreeID: worktreeID, armed: true, blocked: false, prStatus: status, colorScheme: .light)
        let unarmed = PRButtonLabel.prSplitButtonID(
            worktreeID: worktreeID, armed: false, blocked: false, prStatus: status, colorScheme: .light)
        #expect(armed != unarmed)
    }

    @Test("id key differs between PR states and PR numbers")
    func idKeyDiffersByPRStatus() {
        let worktreeID = UUID()
        let open = PRButtonLabel.prSplitButtonID(
            worktreeID: worktreeID, armed: false, blocked: false,
            prStatus: Self.makeStatus(state: .mergeable), colorScheme: .light)
        let merged = PRButtonLabel.prSplitButtonID(
            worktreeID: worktreeID, armed: false, blocked: false,
            prStatus: Self.makeStatus(state: .merged), colorScheme: .light)
        #expect(open != merged)

        let otherNumber = PRButtonLabel.prSplitButtonID(
            worktreeID: worktreeID, armed: false, blocked: false,
            prStatus: Self.makeStatus(number: 43), colorScheme: .light)
        #expect(open != otherNumber)
    }

    @Test("id key differs between blocked states, color schemes, and worktrees")
    func idKeyDiffersByBlockedSchemeAndWorktree() {
        let worktreeID = UUID()
        let status = Self.makeStatus()
        let base = PRButtonLabel.prSplitButtonID(
            worktreeID: worktreeID, armed: false, blocked: false, prStatus: status, colorScheme: .light)

        let blocked = PRButtonLabel.prSplitButtonID(
            worktreeID: worktreeID, armed: false, blocked: true, prStatus: status, colorScheme: .light)
        #expect(base != blocked)

        let dark = PRButtonLabel.prSplitButtonID(
            worktreeID: worktreeID, armed: false, blocked: false, prStatus: status, colorScheme: .dark)
        #expect(base != dark)

        let otherWorktree = PRButtonLabel.prSplitButtonID(
            worktreeID: UUID(), armed: false, blocked: false, prStatus: status, colorScheme: .light)
        #expect(base != otherWorktree)
    }

    @Test("id key is stable for identical inputs")
    func idKeyStable() {
        let worktreeID = UUID()
        let status = Self.makeStatus()
        let first = PRButtonLabel.prSplitButtonID(
            worktreeID: worktreeID, armed: true, blocked: true, prStatus: status, colorScheme: .dark)
        let second = PRButtonLabel.prSplitButtonID(
            worktreeID: worktreeID, armed: true, blocked: true, prStatus: status, colorScheme: .dark)
        #expect(first == second)
    }
}
