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
    /// A holder-backed row unless `transport` says otherwise: every session TBD
    /// starts is on the holder, and a row parked on tmux gets a notice of its
    /// own (`parkedOnTmuxRowGetsTheMoveNotice`).
    private func terminal(hibernatedAt: Date? = nil,
                          hibernateReason: HibernateReason? = nil,
                          suspendedAt: Date? = nil,
                          pendingResumeAt: Date? = nil,
                          transport: TerminalTransport = .holder) -> TBDShared.Terminal {
        TBDShared.Terminal(id: UUID(), worktreeID: UUID(),
                 tmuxWindowID: transport == .holder ? "" : "@1",
                 tmuxPaneID: transport == .holder ? "" : "%1",
                 suspendedAt: suspendedAt,
                 hibernatedAt: hibernatedAt,
                 hibernateReason: hibernateReason,
                 pendingResumeAt: pendingResumeAt,
                 transport: transport)
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

    /// Session-exit park → names the process that left, not a TBD gesture.
    @Test func exitedParkMessage() {
        let banner = HibernatedBannerModel.banner(
            for: terminal(hibernatedAt: Date(), hibernateReason: .exited)
        )
        #expect(banner == .hibernatedOverlay(
            message: "Claude exited — click anywhere in the pane to resume"
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
        let row = terminal(pendingResumeAt: resumeAt)
        let banner = HibernatedBannerModel.banner(for: row)
        #expect(banner == .scheduledResume(at: resumeAt, cancelTerminalID: row.id))
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

    // MARK: - Inline Cancel affordance
    //
    // The footer's "Cancel" button is driven off `Banner.cancelTerminalID`:
    // non-nil only for the scheduled-resume footer, so the parked variants
    // can't sprout a cancel control.

    /// Scheduled resume → the footer exposes a cancel target, and it is THIS
    /// terminal (what `AppState.cancelScheduledResume` gets handed).
    @Test func scheduledResumeExposesCancelTarget() {
        let row = terminal(pendingResumeAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(HibernatedBannerModel.banner(for: row)?.cancelTerminalID == row.id)
    }

    /// Parked → no cancel affordance (there is no footer to hang it on, and
    /// parking already cancelled the resume daemon-side).
    @Test func parkedBannerExposesNoCancelTarget() {
        let banner = HibernatedBannerModel.banner(
            for: terminal(hibernatedAt: Date(), hibernateReason: .manual)
        )
        #expect(banner?.cancelTerminalID == nil)
    }

    /// Parked AND a stale `pendingResumeAt` → still no cancel affordance,
    /// same precedence as `parkedBeatsScheduledResume`.
    @Test func parkedWithStalePendingResumeExposesNoCancelTarget() {
        let banner = HibernatedBannerModel.banner(
            for: terminal(hibernatedAt: Date(), hibernateReason: .auto,
                          pendingResumeAt: Date(timeIntervalSince1970: 1_800_000_000))
        )
        #expect(banner?.cancelTerminalID == nil)
    }

    // MARK: - A row parked on tmux

    /// A row parked on tmux cannot be woken where it is, so its notice says how
    /// to move it instead of promising a click resumes it — whatever the park
    /// reason, including the dead-window re-park, which records none.
    @Test(arguments: [nil, .manual, .auto, .recovery, .merged, .exited] as [HibernateReason?])
    func parkedOnTmuxRowGetsTheMoveNotice(reason: HibernateReason?) {
        let banner = HibernatedBannerModel.banner(
            for: terminal(hibernatedAt: Date(), hibernateReason: reason, transport: .tmux))
        #expect(banner == .hibernatedOverlay(message: HibernatedBannerModel.parkedOnTmuxMessage))
        #expect(HibernatedBannerModel.parkedOnTmuxMessage.contains(TransportMigrationMenu.title))
        #expect(HibernatedBannerModel.parkedOnTmuxMessage.contains("tbd terminal migrate"))
    }

    /// A start-admission hold is not appended to a tmux row's notice: no wake
    /// of it can start anything until it is moved.
    @Test func parkedOnTmuxRowIgnoresAHold() {
        var held = terminal(hibernatedAt: Date(), hibernateReason: .manual, transport: .tmux)
        held.startHeldReason = "camera in use"
        held.startHeldAt = Self.nineTwelveUTC
        #expect(heldMessage(held) == HibernatedBannerModel.parkedOnTmuxMessage)
    }

    /// The other branch: the same row on the holder keeps its reason's
    /// phrasing.
    @Test func parkedOnTheHolderRowKeepsItsReasonPhrasing() {
        let banner = HibernatedBannerModel.banner(
            for: terminal(hibernatedAt: Date(), hibernateReason: .manual, transport: .holder))
        #expect(banner == .hibernatedOverlay(message: HibernatedBannerModel.message(for: .manual)))
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

    // MARK: - Held automatic wake (start admission)

    /// 1970-01-01 09:12 UTC.
    private static let nineTwelveUTC = Date(timeIntervalSince1970: 33_120)

    private func heldMessage(_ terminal: TBDShared.Terminal) -> String {
        HibernatedBannerModel.message(
            for: terminal,
            timeZone: TimeZone(identifier: "UTC") ?? .gmt,
            locale: Locale(identifier: "en_US"))
    }

    @Test func aHeldWakeAppendsTheReasonAndTime() {
        var held = terminal(hibernatedAt: Date(), hibernateReason: .manual)
        held.startHeldReason = "camera in use"
        held.startHeldAt = Self.nineTwelveUTC
        // The clock's own spacing before "AM" varies by OS, so pin the parts
        // around it rather than the whole string.
        let message = heldMessage(held)
        #expect(message.hasPrefix(
            "Hibernated — click anywhere in the pane to resume · Automatic wake held at 9:12"))
        #expect(message.hasSuffix("M: camera in use"))
    }

    @Test func aHoldWithoutATimeStillSaysWhy() {
        var held = terminal(hibernatedAt: Date(), hibernateReason: .auto)
        held.startHeldReason = "camera in use"
        #expect(heldMessage(held)
            == "Hibernated while idle — click anywhere in the pane to resume"
            + " · Automatic wake held: camera in use")
    }

    @Test func noHoldLeavesTheMessageUnchanged() {
        let parked = terminal(hibernatedAt: Date(), hibernateReason: .recovery)
        #expect(heldMessage(parked) == HibernatedBannerModel.message(for: .recovery))
        var empty = parked
        empty.startHeldReason = ""
        #expect(heldMessage(empty) == HibernatedBannerModel.message(for: .recovery))
    }

    @Test func theParkedBannerCarriesTheHold() {
        var held = terminal(hibernatedAt: Date(), hibernateReason: .manual)
        held.startHeldReason = "camera in use"
        held.startHeldAt = Date()
        guard case .hibernatedOverlay(let message)? = HibernatedBannerModel.banner(for: held) else {
            Issue.record("a parked terminal must get the hibernated overlay")
            return
        }
        #expect(message.contains("Automatic wake held at"))
        #expect(message.hasSuffix(": camera in use"))
    }
}
