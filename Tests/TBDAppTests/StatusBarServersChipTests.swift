import AppKit
import Foundation
import SwiftUI
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

/// The status bar's Servers chip (`ServersStatusChip`), shown while Tabs in
/// the toolbar is on: what it shows as values, with the setting on and off,
/// and where its menu opens. Spec:
/// `docs/specs/2026-11-02-tabs-in-toolbar-design.md`, "Servers in the status
/// bar". Tier 1.
@Suite("Status bar Servers chip")
struct StatusBarServersChipTests {
    private func server(_ name: String, _ state: DevServerStateKind) -> DevServerInfo {
        DevServerInfo(name: name, label: name, source: "tbd.toml", state: state, exitCode: nil,
                      endpoints: [], terminalID: nil, pid: nil, hasStopCommand: false)
    }

    private func list(_ servers: [DevServerInfo], id: UUID = UUID()) -> DevServerListResult {
        DevServerListResult(worktreeID: id, servers: servers, parseErrors: [], runningFileDiagnostics: [])
    }

    // MARK: Presentation

    /// No list, or a list with no server, shows no chip, as the toolbar shows
    /// no Servers item.
    @Test func hiddenWithNoServers() {
        let noList = ServersChipPresentation.make(tabsInToolbar: true, list: nil)
        let emptyList = ServersChipPresentation.make(tabsInToolbar: true, list: list([]))
        #expect(noList == nil)
        #expect(emptyList == nil)
    }

    /// With servers but none running, the chip is the muted glyph and
    /// "Servers".
    @Test func mutedWithNoneRunning() {
        let chip = ServersChipPresentation.make(
            tabsInToolbar: true, list: list([server("web", .stopped), server("api", .exited)]))
        let expected = ServersChipPresentation(style: .idle, title: "Servers", accessibilityLabel: "Dev servers")
        #expect(chip == expected)
    }

    /// With servers running, the chip is green with the count of running
    /// servers only, and says it aloud.
    @Test func greenWithACount() {
        let chip = ServersChipPresentation.make(
            tabsInToolbar: true,
            list: list([server("web", .running), server("api", .running), server("db", .stopped)]))
        let expected = ServersChipPresentation(
            style: .running, title: "2 running", accessibilityLabel: "Dev servers, 2 running")
        #expect(chip == expected)
    }

    /// The chip's words are the toolbar item's, from `ServersButtonLabel`.
    @Test func theWordsAreTheToolbarItems() throws {
        let running = list([server("web", .running)])
        let chip = try #require(ServersChipPresentation.make(tabsInToolbar: true, list: running))
        let count = ServersButtonLabel.runningCount(running)
        #expect(chip.title == ServersButtonLabel.title(runningCount: count))
        #expect(chip.accessibilityLabel == ServersButtonLabel.accessibilityLabel(runningCount: count))
    }

    /// With the setting off, no list shows a chip: the toolbar's Servers item
    /// shows them instead.
    @Test func settingOffShowsNoChip() {
        let lists: [DevServerListResult?] = [
            nil, list([]), list([server("web", .stopped)]), list([server("web", .running)]),
        ]
        let chips = lists.map { ServersChipPresentation.make(tabsInToolbar: false, list: $0) }
        let shown = chips.compactMap { $0 }
        #expect(shown.isEmpty)
    }

    // MARK: The menu's position

    /// The menu opens upward: its top leading corner sits a menu's height
    /// beyond the chip's top, so its bottom edge lies on the chip's top edge,
    /// and its leading edge on the chip's. In a view that is not flipped the
    /// top is the larger y; in a flipped one, the smaller.
    @Test func theMenuOpensUpwardFromTheChip() {
        let chip = NSRect(x: 10, y: 4, width: 80, height: 18)
        let height: CGFloat = 120

        let unflipped = ServersStatusChip.menuOrigin(
            chipBounds: chip, menuHeight: height, flipped: false, rightToLeft: false)
        let flipped = ServersStatusChip.menuOrigin(
            chipBounds: chip, menuHeight: height, flipped: true, rightToLeft: false)
        let rightToLeft = ServersStatusChip.menuOrigin(
            chipBounds: chip, menuHeight: height, flipped: false, rightToLeft: true)

        let expectedUnflipped = NSPoint(x: 10, y: 142)
        let expectedFlipped = NSPoint(x: 10, y: -116)
        let expectedRightToLeft = NSPoint(x: 90, y: 142)
        #expect(unflipped == expectedUnflipped)
        #expect(flipped == expectedFlipped)
        #expect(rightToLeft == expectedRightToLeft)

        // The menu's bottom edge, its top less its height in a view that is
        // not flipped and plus it in a flipped one, is the chip's top edge.
        let unflippedBottom = unflipped.y - height
        let flippedBottom = flipped.y + height
        #expect(unflippedBottom == chip.maxY)
        #expect(flippedBottom == chip.minY)
    }

    // MARK: The setting, read by the view

    /// The chip reads the setting from `appState.windowChrome`, which follows
    /// the store the state was made with: hosted with the setting stored off
    /// it draws nothing, and stored on it draws, for the same worktree and
    /// list. With no worktree it draws nothing either way. Each write goes to
    /// the store and is then followed directly (`followDefaults()`), so the
    /// test does not wait on the store's change notification.
    @MainActor
    @Test func theChipFollowsTheStoredSetting() throws {
        let suite = TestDefaultsSuite("StatusBarServersChip.setting")
        defer { suite.tearDown() }
        let defaults = suite.defaults
        let state = AppState(userDefaults: defaults)
        let id = UUID()
        state.devServerLists[id] = list([server("web", .running)], id: id)

        defaults.set(false, forKey: AppState.tabsInToolbarKey)
        state.windowChrome.followDefaults()
        try #require(state.windowChrome.tabsInToolbar == false)
        let offWidth = Self.fittingWidth(worktreeID: id, state: state)

        defaults.set(true, forKey: AppState.tabsInToolbarKey)
        state.windowChrome.followDefaults()
        try #require(state.windowChrome.tabsInToolbar == true)
        let onWidth = Self.fittingWidth(worktreeID: id, state: state)
        let noWorktreeWidth = Self.fittingWidth(worktreeID: nil, state: state)

        #expect(offWidth == 0)
        #expect(onWidth > 0)
        #expect(noWorktreeWidth == 0)
    }

    /// The fitting width of a fresh chip for `worktreeID`, hosted in the
    /// environment the status bar gives it.
    @MainActor
    private static func fittingWidth(worktreeID: UUID?, state: AppState) -> CGFloat {
        let chip = ServersStatusChip(worktreeID: worktreeID)
            .environment(state)
        return NSHostingView(rootView: chip).fittingSize.width
    }
}
