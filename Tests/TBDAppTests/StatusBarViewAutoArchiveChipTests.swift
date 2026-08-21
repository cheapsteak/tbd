import Foundation
import Testing
@testable import TBDApp

// Tier 1: the pure value behind the status bar's auto-archive chip. Only the
// transform is exercised — the view, the cancel gesture and the purple are not.
//
// A `@Suite` struct for the same reason `StatusBarViewChipsTests` is one:
// `--filter` matches the test ID, which carries the SUITE name, so free
// functions would be invisible to `--filter StatusBarView`.
@Suite("StatusBarView auto-archive chip")
struct StatusBarViewAutoArchiveChipTests {

    @Test("an unarmed worktree gets no chip at all")
    func notArmed() {
        #expect(StatusBarView.autoArchiveChip(
            armed: false, blocked: false, displayName: "invisible-armadillo") == nil)
        // Children do not conjure a chip for a worktree that never armed.
        #expect(StatusBarView.autoArchiveChip(
            armed: false, blocked: true, displayName: "invisible-armadillo") == nil)
    }

    @Test("an armed worktree says it archives itself on merge")
    func armed() throws {
        let chip = try #require(StatusBarView.autoArchiveChip(
            armed: true, blocked: false, displayName: "invisible-armadillo"))
        #expect(chip.label == "Archive on merge")
        #expect(chip.tooltip
                == "This worktree archives itself when its PR merges. Click to cancel.")
        #expect(chip.accessibilityLabel == "Archive on merge armed for invisible-armadillo")
    }

    // "skipped", not "paused" — nothing re-attempts the archive once the
    // children are gone (`AllResolvedMergeTrigger` is edge-triggered), so the
    // wording must not have the operator waiting for a resume.
    @Test("child worktrees skip the archiving, and the tooltip says so")
    func blocked() throws {
        let chip = try #require(StatusBarView.autoArchiveChip(
            armed: true, blocked: true, displayName: "invisible-armadillo"))
        #expect(chip.tooltip
                == "Auto-archive is armed, but archiving is skipped while child worktrees exist. Click to cancel.")
        #expect(!chip.tooltip.contains("paused"))
    }

    // The whole capsule takes the click, so no tooltip may send the operator
    // aiming at the ✕ — the glyph is where the cancel is announced, not the
    // only place it can be hit.
    @Test("no tooltip names the ✕ as the thing to click")
    func tooltipsDoNotNameTheGlyph() throws {
        for blocked in [false, true] {
            let chip = try #require(StatusBarView.autoArchiveChip(
                armed: true, blocked: blocked, displayName: "invisible-armadillo"))
            #expect(!chip.tooltip.contains("✕"))
            #expect(chip.tooltip.hasSuffix("Click to cancel."))
        }
    }

    // Being blocked is not a disarming: the worktree stays armed, so the chip
    // must not soften its claim. The qualification lives in the tooltip alone.
    @Test("the label is the same whether or not children block the archiving")
    func labelStableAcrossBlocking() throws {
        let unblocked = try #require(StatusBarView.autoArchiveChip(
            armed: true, blocked: false, displayName: "invisible-armadillo"))
        let blocked = try #require(StatusBarView.autoArchiveChip(
            armed: true, blocked: true, displayName: "invisible-armadillo"))
        #expect(unblocked.label == blocked.label)
        #expect(unblocked.accessibilityLabel == blocked.accessibilityLabel)
        #expect(unblocked.tooltip != blocked.tooltip)
    }
}
