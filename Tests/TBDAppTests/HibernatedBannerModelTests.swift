import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// The parked-pane bottom-edge notice + full-surface click-to-wake gate.
/// Tests the two pure decisions — `HibernatedBannerModel.banner(for:)`
/// (parked → `.hibernatedOverlay`: the footer slot stays empty and the
/// reason-phrased message is composed into the frozen snapshot's last rows
/// via `ParkedSnapshotComposer`;
/// live + scheduled → the `.scheduledResume` footer; parked beats scheduled)
/// and `ParkedPaneWakeModel.showsWakeOverlay(for:)` (parked panes get the
/// click-catching overlay, live panes never do) — without SwiftUI, in the
/// same fixture style as `WakeOnFocusDecisionTests`.
@Suite("Hibernated banner + parked-pane wake gate")
struct HibernatedBannerModelTests {
    private func terminal(hibernatedAt: Date? = nil,
                          hibernateReason: HibernateReason? = nil,
                          suspendedAt: Date? = nil,
                          pendingResumeAt: Date? = nil) -> Terminal {
        Terminal(id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                 suspendedAt: suspendedAt,
                 hibernatedAt: hibernatedAt,
                 hibernateReason: hibernateReason,
                 pendingResumeAt: pendingResumeAt)
    }

    // MARK: - Hibernated overlay message per park reason
    //
    // Parked → `.hibernatedOverlay(message:)`: no footer banner (the notice
    // block composed into the snapshot's last rows carries the message
    // instead).

    /// Manual park ("Hibernate now") → plain "Hibernated" phrasing.
    @Test func manualParkMessage() {
        let banner = HibernatedBannerModel.banner(
            for: terminal(hibernatedAt: Date(), hibernateReason: .manual)
        )
        #expect(banner == .hibernatedOverlay(
            message: "Hibernated — click anywhere in the pane to resume"
        ))
    }

    /// Idle-sweep auto park → "while idle" phrasing.
    @Test func autoParkMessage() {
        let banner = HibernatedBannerModel.banner(
            for: terminal(hibernatedAt: Date(), hibernateReason: .auto)
        )
        #expect(banner == .hibernatedOverlay(
            message: "Hibernated while idle — click anywhere in the pane to resume"
        ))
    }

    /// Crash-recovery park → "after a restart" phrasing.
    @Test func recoveryParkMessage() {
        let banner = HibernatedBannerModel.banner(
            for: terminal(hibernatedAt: Date(), hibernateReason: .recovery)
        )
        #expect(banner == .hibernatedOverlay(
            message: "Parked after a restart — click anywhere in the pane to resume"
        ))
    }

    /// PR-merge park (#404) → "after the PR merged" phrasing.
    @Test func mergedParkMessage() {
        let banner = HibernatedBannerModel.banner(
            for: terminal(hibernatedAt: Date(), hibernateReason: .merged)
        )
        #expect(banner == .hibernatedOverlay(
            message: "Hibernated after the PR merged — click anywhere in the pane to resume"
        ))
    }

    /// Legacy pre-v46 park with no persisted reason → reads like `.auto`.
    @Test func nilReasonParkMessage() {
        let banner = HibernatedBannerModel.banner(
            for: terminal(hibernatedAt: Date(), hibernateReason: nil)
        )
        #expect(banner == .hibernatedOverlay(
            message: "Hibernated while idle — click anywhere in the pane to resume"
        ))
    }

    /// A legacy-suspended row (`suspendedAt` only, never migrated) is parked
    /// too — it gets the hibernated overlay via `isParked`, not nothing.
    @Test func legacySuspendedRowGetsHibernatedBanner() {
        let banner = HibernatedBannerModel.banner(for: terminal(suspendedAt: Date()))
        #expect(banner == .hibernatedOverlay(
            message: "Hibernated while idle — click anywhere in the pane to resume"
        ))
    }

    // MARK: - No banner / scheduled-resume branches

    /// A live terminal with nothing scheduled → no footer banner and no
    /// overlay strip.
    @Test func liveTerminalShowsNoBanner() {
        #expect(HibernatedBannerModel.banner(for: terminal()) == nil)
    }

    /// No terminal resolvable for the active tab → no banner.
    @Test func nilTerminalShowsNoBanner() {
        #expect(HibernatedBannerModel.banner(for: nil) == nil)
    }

    /// A live terminal with a scheduled auto-resume → the scheduled FOOTER
    /// banner (the only banner that still occupies the footer slot),
    /// carrying the exact `resumeAt`.
    @Test func liveTerminalWithPendingResumeShowsScheduledBanner() {
        let resumeAt = Date(timeIntervalSince1970: 1_800_000_000)
        let banner = HibernatedBannerModel.banner(for: terminal(pendingResumeAt: resumeAt))
        #expect(banner == .scheduledResume(resumeAt))
    }

    /// Precedence: parked AND `pendingResumeAt` set (parking now cancels the
    /// scheduled resume daemon-side, but the stale mirror is possible in the
    /// delta-to-refetch window) → the PARKED overlay wins and the scheduled
    /// footer is NOT shown; "TBD types continue at..." would be misleading
    /// for a session with nothing running.
    @Test func parkedBeatsScheduledResume() {
        let banner = HibernatedBannerModel.banner(
            for: terminal(hibernatedAt: Date(), hibernateReason: .merged,
                          pendingResumeAt: Date(timeIntervalSince1970: 1_800_000_000))
        )
        #expect(banner == .hibernatedOverlay(
            message: "Hibernated after the PR merged — click anywhere in the pane to resume"
        ))
    }

    // MARK: - Full-pane wake overlay gate

    /// A parked terminal gets the full-surface click-to-wake overlay.
    @Test func parkedTerminalGetsWakeOverlay() {
        #expect(ParkedPaneWakeModel.showsWakeOverlay(for: terminal(hibernatedAt: Date())))
    }

    /// A legacy-suspended terminal is parked → overlay too.
    @Test func legacySuspendedTerminalGetsWakeOverlay() {
        #expect(ParkedPaneWakeModel.showsWakeOverlay(for: terminal(suspendedAt: Date())))
    }

    /// A LIVE terminal must never get a click-catching overlay — it would
    /// eat clicks meant for the terminal itself.
    @Test func liveTerminalGetsNoWakeOverlay() {
        #expect(!ParkedPaneWakeModel.showsWakeOverlay(for: terminal()))
    }

    /// No terminal resolved → no overlay.
    @Test func nilTerminalGetsNoWakeOverlay() {
        #expect(!ParkedPaneWakeModel.showsWakeOverlay(for: nil))
    }
}
