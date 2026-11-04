import AppKit
import Foundation
import SwiftUI
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

/// The status bar's Servers chip (`ServersStatusChip`): what it shows as
/// values, and where its menu opens. Spec:
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

    /// No list, or a list with no server, shows no chip.
    @Test func hiddenWithNoServers() {
        let noList = ServersChipPresentation.make(list: nil)
        let emptyList = ServersChipPresentation.make(list: list([]))
        #expect(noList == nil)
        #expect(emptyList == nil)
    }

    /// With servers but none running, the chip is the muted glyph and
    /// "Servers".
    @Test func mutedWithNoneRunning() {
        let chip = ServersChipPresentation.make(list: list([server("web", .stopped), server("api", .exited)]))
        let expected = ServersChipPresentation(style: .idle, title: "Servers", accessibilityLabel: "Dev servers")
        #expect(chip == expected)
    }

    /// With servers running, the chip is green with the count of running
    /// servers only, and says it aloud.
    @Test func greenWithACount() {
        let chip = ServersChipPresentation.make(
            list: list([server("web", .running), server("api", .running), server("db", .stopped)]))
        let expected = ServersChipPresentation(
            style: .running, title: "2 running", accessibilityLabel: "Dev servers, 2 running")
        #expect(chip == expected)
    }

    /// The chip's words come from `ServersButtonLabel`.
    @Test func theWordsAreTheServersLabels() throws {
        let running = list([server("web", .running)])
        let chip = try #require(ServersChipPresentation.make(list: running))
        let count = ServersButtonLabel.runningCount(running)
        #expect(chip.title == ServersButtonLabel.title(runningCount: count))
        #expect(chip.accessibilityLabel == ServersButtonLabel.accessibilityLabel(runningCount: count))
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

    // MARK: The view

    /// Hosted for a worktree whose list has a server, the chip draws; for a
    /// worktree with no list, or for no worktree, it draws nothing.
    @MainActor
    @Test func theChipDrawsOnlyForAWorktreeWithServers() {
        let suite = TestDefaultsSuite("StatusBarServersChip.view")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let id = UUID()
        state.devServerLists[id] = list([server("web", .running)], id: id)

        let withServersWidth = Self.fittingWidth(worktreeID: id, state: state)
        let withoutListWidth = Self.fittingWidth(worktreeID: UUID(), state: state)
        let noWorktreeWidth = Self.fittingWidth(worktreeID: nil, state: state)

        #expect(withServersWidth > 0)
        #expect(withoutListWidth == 0)
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
