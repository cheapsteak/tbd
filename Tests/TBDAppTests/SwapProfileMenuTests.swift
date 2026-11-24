import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("SwapProfileMenu — busy-session warning")
struct SwapProfileMenuTests {
    @Test func inPlaceSwapOfBusySessionWarnsAboutInterrupt() {
        let caption = SwapProfileMenu.busyCaption(mode: .inPlace, activityState: .working)
        #expect(caption == SwapProfileMenu.interruptsRunCaption)
        #expect(caption?.contains("interrupts current run") == true)
    }

    @Test func inPlaceSwapOfNonBusySessionHasNoWarning() {
        #expect(SwapProfileMenu.busyCaption(mode: .inPlace, activityState: .idle) == nil)
        #expect(SwapProfileMenu.busyCaption(mode: .inPlace, activityState: .unknown) == nil)
        #expect(SwapProfileMenu.busyCaption(mode: .inPlace, activityState: nil) == nil)
    }

    @Test func forkNeverWarnsEvenWhenBusy() {
        // Forking duplicates the conversation into a new tab and leaves the
        // source session untouched — no interruption to warn about.
        #expect(SwapProfileMenu.busyCaption(mode: .fork, activityState: .working) == nil)
        #expect(SwapProfileMenu.busyCaption(mode: .fork, activityState: .idle) == nil)
    }
}

/// Which rows are offered an in-place account switch. The tab's menu and the
/// limit banner both read this, and a fork stays on offer for every row.
@Suite("SwapProfileMenu — in-place switch")
struct SwapProfileMenuInPlaceTests {
    private func row(transport: TerminalTransport, parked: Bool) -> TBDShared.Terminal {
        TBDShared.Terminal(
            worktreeID: UUID(),
            tmuxWindowID: transport == .holder ? "" : "@1",
            tmuxPaneID: transport == .holder ? "" : "%1",
            label: "claude", claudeSessionID: "acme-session", kind: .claude,
            hibernatedAt: parked ? Date() : nil,
            transport: transport)
    }

    /// The daemon refuses an in-place switch of a running tmux row, so the
    /// menu does not offer one.
    @Test func aRunningTmuxRowIsNotOfferedAnInPlaceSwitch() {
        #expect(!SwapProfileMenu.offersInPlaceSwitch(for: row(transport: .tmux, parked: false)))
    }

    /// A parked tmux row's switch re-homes it and starts nothing, so it stays.
    @Test func aParkedTmuxRowKeepsTheInPlaceSwitch() {
        #expect(SwapProfileMenu.offersInPlaceSwitch(for: row(transport: .tmux, parked: true)))
    }

    @Test func aHolderRowKeepsTheInPlaceSwitchRunningOrParked() {
        #expect(SwapProfileMenu.offersInPlaceSwitch(for: row(transport: .holder, parked: false)))
        #expect(SwapProfileMenu.offersInPlaceSwitch(for: row(transport: .holder, parked: true)))
    }

    /// With no row to judge, the switch is offered and the daemon decides.
    @Test func noRowKeepsTheInPlaceSwitch() {
        #expect(SwapProfileMenu.offersInPlaceSwitch(for: nil))
    }
}
