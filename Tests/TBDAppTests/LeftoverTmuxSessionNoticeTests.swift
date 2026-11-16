import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The decision behind `LeftoverTmuxSessionNotice`, and the words it shows.
///
/// A row still live on tmux is one whose server outlived the update: the app
/// shows the notice in its place and never a terminal. Every other row keeps
/// what it had — a parked tmux row its parked pane, a holder row its terminal.
/// The pinned dock follows the main pane: a parked tmux row there gets its
/// snapshot and notice too.
@Suite("Leftover tmux session notice")
struct LeftoverTmuxSessionNoticeTests {
    private static func row(transport: TerminalTransport, parked: Bool) -> Terminal {
        let isHolder = transport == .holder
        return Terminal(
            id: UUID(), worktreeID: UUID(),
            tmuxWindowID: isHolder ? "" : "@3", tmuxPaneID: isHolder ? "" : "%3",
            claudeSessionID: "session-1", kind: .claude, activityState: .idle,
            hibernatedAt: parked ? Date() : nil, transport: transport)
    }

    @Test("a live row on tmux shows the notice")
    func liveTmuxRowShowsTheNotice() {
        #expect(TerminalPanePresentation.showsLeftoverTmuxNotice(
            for: Self.row(transport: .tmux, parked: false)))
    }

    @Test("a parked row on tmux keeps its parked pane")
    func parkedTmuxRowKeepsItsParkedPane() {
        #expect(!TerminalPanePresentation.showsLeftoverTmuxNotice(
            for: Self.row(transport: .tmux, parked: true)))
    }

    @Test("a holder row, live or parked, keeps its terminal", arguments: [false, true])
    func holderRowKeepsItsTerminal(parked: Bool) {
        #expect(!TerminalPanePresentation.showsLeftoverTmuxNotice(
            for: Self.row(transport: .holder, parked: parked)))
    }

    /// A legacy row parked through `suspendedAt` alone reads as parked too, so
    /// it keeps the parked pane rather than the notice.
    @Test("a tmux row parked by the legacy column keeps its parked pane")
    func legacySuspendedTmuxRowKeepsItsParkedPane() {
        let row = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@3", tmuxPaneID: "%3",
            suspendedAt: Date(), kind: .claude, transport: .tmux)
        #expect(!TerminalPanePresentation.showsLeftoverTmuxNotice(for: row))
    }

    // MARK: - The pinned dock

    /// The dock draws no parked placeholder for a holder row, but a row parked
    /// on tmux has no live frame to keep, so the dock draws its snapshot and
    /// the notice that says how to move it — the main pane's parked pane.
    @Test("the dock draws a parked tmux row's snapshot and its move advice")
    func dockDrawsAParkedTmuxRowsSnapshot() {
        let row = Self.row(transport: .tmux, parked: true)
        #expect(TerminalPanePresentation.dockShowsParkedSnapshot(for: row))
        #expect(TerminalPanePresentation.parkedNoticeMessage(for: row, switching: nil)
            == HibernatedBannerModel.parkedOnTmuxMessage)
    }

    @Test("the dock draws a tmux row parked by the legacy column the same way")
    func dockDrawsALegacySuspendedTmuxRowsSnapshot() {
        let row = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@3", tmuxPaneID: "%3",
            suspendedAt: Date(), kind: .claude, transport: .tmux)
        #expect(TerminalPanePresentation.dockShowsParkedSnapshot(for: row))
    }

    @Test("the dock draws no snapshot for a live tmux row, which gets the notice")
    func dockDrawsNoSnapshotForALiveTmuxRow() {
        let row = Self.row(transport: .tmux, parked: false)
        #expect(!TerminalPanePresentation.dockShowsParkedSnapshot(for: row))
        #expect(TerminalPanePresentation.showsLeftoverTmuxNotice(for: row))
    }

    @Test("the dock draws no snapshot for a holder row, live or parked", arguments: [false, true])
    func dockDrawsNoSnapshotForAHolderRow(parked: Bool) {
        #expect(!TerminalPanePresentation.dockShowsParkedSnapshot(
            for: Self.row(transport: .holder, parked: parked)))
    }

    @Test("the notice names the server's kill-server command and Check Again")
    func noticeNamesTheKillServerCommand() {
        let notice = LeftoverTmuxSession.notice(server: "tbd-acme")
        #expect(notice.contains("tmux -L tbd-acme kill-server"))
        #expect(notice.contains(LeftoverTmuxSession.checkAgainTitle))
    }
}
