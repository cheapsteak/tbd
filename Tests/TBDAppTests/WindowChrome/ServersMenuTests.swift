import AppKit
import Foundation
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

/// The Servers menu, `ServersMenu`, that the status bar's Servers chip
/// opens: the rows it builds from `ServersToolbarMenu.entries`, the target
/// and action each row sends, and what a chosen row runs. Tier 1, except the
/// two tests that wait for a chosen row's command to reach the injected
/// daemon seam, which run real main-actor scheduling.
@MainActor
@Suite("Servers menu")
struct ServersMenuTests {
    private func server(_ name: String, _ state: DevServerStateKind, url: String? = nil) -> DevServerInfo {
        DevServerInfo(name: name, label: name, source: "tbd.toml", state: state, exitCode: nil,
                      endpoints: url.map { [DevServerEndpoint(name: "app", url: $0)] } ?? [],
                      terminalID: nil, pid: nil, hasStopCommand: false)
    }

    private func list(_ servers: [DevServerInfo], id: UUID) -> DevServerListResult {
        DevServerListResult(worktreeID: id, servers: servers, parseErrors: [], runningFileDiagnostics: [])
    }

    /// A worktree with a running server and a stopped one, and a failure
    /// message from its last action, as the menu tests need.
    private func populate(_ state: AppState, id: UUID) -> (list: DevServerListResult, messages: [String]) {
        let shown = list([server("web", .running, url: "http://localhost:3000"), server("api", .stopped)], id: id)
        let messages = ["web: failed to stop"]
        state.devServerLists[id] = shown
        state.devServerActionMessages[id] = messages
        return (shown, messages)
    }

    /// Fakes every daemon seam a chosen row's command reaches, recording the
    /// start and stop requests, so no test talks to a daemon.
    private func fakeDaemon(_ state: AppState, shown: DevServerListResult, recorder: ActionRecorder) {
        state.devServerActionSender = { action, worktreeID, names in
            recorder.calls.append("\(action):\(worktreeID):\(names)")
            return DevServerActionResult(outcomes: [])
        }
        state.devServerListFetcher = { _, _ in shown }
        state.devServerSummaryFetcher = { DevServerSummaryResult(runningWorktreeIDs: []) }
    }

    @Test func rebuildListsTheEntriesForTheWorktree() throws {
        let suite = TestDefaultsSuite("ServersMenu.rebuild")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let id = UUID()
        let (shown, messages) = populate(state, id: id)
        let target = RowTarget()
        let action = #selector(RowTarget.chosen(_:))
        let menu = NSMenu()

        ServersMenu.rebuild(menu, worktreeID: id, appState: state, target: target, action: action)

        let rows = menu.items.map { Self.describeRow($0) }
        let expected = ServersToolbarMenu.entries(list: shown, messages: messages).map { Self.describeEntry($0) }
        #expect(rows == expected)
        let commandRows = menu.items.filter { $0.representedObject is ServersMenuCommandBox }
        try #require(!commandRows.isEmpty)
        let allTargetTheCaller = commandRows.allSatisfy { $0.target === target && $0.action == action }
        #expect(allTargetTheCaller)
        let worktreeIDs = Set(commandRows.compactMap { ($0.representedObject as? ServersMenuCommandBox)?.worktreeID })
        let expectedIDs: Set<UUID> = [id]
        #expect(worktreeIDs == expectedIDs)
        let note = menu.items.first { $0.title == "web: failed to stop" }
        #expect(note?.isEnabled == false)
        #expect(note?.action == nil)
    }

    /// A rebuild replaces what the menu held, and leaves it empty with no
    /// worktree or with a worktree that has no list.
    @Test func rebuildEmptiesTheMenuWithoutAList() throws {
        let suite = TestDefaultsSuite("ServersMenu.empty")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let id = UUID()
        _ = populate(state, id: id)
        let target = RowTarget()
        let action = #selector(RowTarget.chosen(_:))
        let menu = NSMenu()

        ServersMenu.rebuild(menu, worktreeID: id, appState: state, target: target, action: action)
        try #require(menu.numberOfItems > 0)
        ServersMenu.rebuild(menu, worktreeID: nil, appState: state, target: target, action: action)
        #expect(menu.numberOfItems == 0)

        ServersMenu.rebuild(menu, worktreeID: id, appState: state, target: target, action: action)
        ServersMenu.rebuild(menu, worktreeID: UUID(), appState: state, target: target, action: action)
        #expect(menu.numberOfItems == 0)
    }

    /// The menu is for the one selected worktree, and for none while none or
    /// several are selected.
    @Test func theMenuIsForTheSingleSelection() {
        let suite = TestDefaultsSuite("ServersMenu.selection")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let first = UUID()
        let second = UUID()
        #expect(ServersMenu.selectedWorktreeID(in: state) == nil)
        state.selectedWorktreeIDs = [first]
        #expect(ServersMenu.selectedWorktreeID(in: state) == first)
        state.selectedWorktreeIDs = [first, second]
        #expect(ServersMenu.selectedWorktreeID(in: state) == nil)
    }

    /// The chip's menu lists the rows the builder gives, each sending
    /// `itemChosen(_:)` to the chip's host, with
    /// autoenabling off so a row's own enablement stands.
    @Test func theChipsMenuListsTheSameRows() throws {
        let suite = TestDefaultsSuite("ServersMenu.chip")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let id = UUID()
        let (shown, messages) = populate(state, id: id)
        let host = ServersChipMenuHost()

        let menu = host.makeMenu(worktreeID: id, appState: state)

        #expect(menu.autoenablesItems == false)
        let rows = menu.items.map { Self.describeRow($0) }
        let expected = ServersToolbarMenu.entries(list: shown, messages: messages).map { Self.describeEntry($0) }
        #expect(rows == expected)
        let commandRows = menu.items.filter { $0.representedObject is ServersMenuCommandBox }
        try #require(!commandRows.isEmpty)
        let action = #selector(ServersChipMenuHost.itemChosen(_:))
        let allTargetTheHost = commandRows.allSatisfy { $0.target === host && $0.action == action }
        #expect(allTargetTheHost)
    }

    /// `ServersMenu.runChosen` runs only a row that carries a command: no
    /// sender, a bare menu item and another control run nothing, and a Stop
    /// row asks the daemon to stop its server. The command runs in a main
    /// actor task, so a sender that had wrongly run something would have
    /// queued its request ahead of the Stop row's, and the recorder would
    /// hold more than the one call.
    @Test func runChosenRunsOnlyARowWithACommand() async throws {
        let suite = TestDefaultsSuite("ServersMenu.runChosen")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let id = UUID()
        let (shown, _) = populate(state, id: id)
        let recorder = ActionRecorder()
        fakeDaemon(state, shown: shown, recorder: recorder)

        ServersMenu.runChosen(nil, appState: state)
        ServersMenu.runChosen(NSMenuItem(title: "Stop", action: nil, keyEquivalent: ""), appState: state)
        ServersMenu.runChosen(NSButton(), appState: state)
        let stop = ServersMenu.item(
            for: .item(title: "Stop", isEnabled: true, command: .stop(names: ["web"])), worktreeID: id,
            target: RowTarget(), action: #selector(RowTarget.chosen(_:)))
        ServersMenu.runChosen(stop, appState: state)

        let arrived = try await waitForMainActorCondition("the Stop row's request to reach the daemon") {
            !recorder.calls.isEmpty
        }
        try #require(arrived)
        let expected = ["stop:\(id):[\"web\"]"]
        #expect(recorder.calls == expected)
    }

    /// The chip host's action runs the chosen row's command against the state
    /// its menu was built from, and runs nothing for any other sender.
    @Test func theChipHostRunsTheChosenRow() async throws {
        let suite = TestDefaultsSuite("ServersMenu.chipRun")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let id = UUID()
        let (shown, _) = populate(state, id: id)
        let recorder = ActionRecorder()
        fakeDaemon(state, shown: shown, recorder: recorder)
        let host = ServersChipMenuHost()
        let menu = host.makeMenu(worktreeID: id, appState: state)
        let startAllRow = menu.items.first { $0.title == "Start all" }
        let startAll = try #require(startAllRow)

        host.itemChosen(nil)
        host.itemChosen(NSButton())
        host.itemChosen(startAll)

        let arrived = try await waitForMainActorCondition("the Start all row's request to reach the daemon") {
            !recorder.calls.isEmpty
        }
        try #require(arrived)
        let expected = ["start:\(id):[]"]
        #expect(recorder.calls == expected)
    }

    // MARK: Helpers

    /// A Servers menu row as text: kind, title, enablement and command.
    private static func describeRow(_ row: NSMenuItem) -> String {
        if row.isSeparatorItem { return "separator" }
        if row.isSectionHeader { return "header:\(row.title)" }
        let command = (row.representedObject as? ServersMenuCommandBox).map { "\($0.command)" } ?? "none"
        return "item:\(row.title):\(row.isEnabled):\(command)"
    }

    /// The row `entry` should become, in `describeRow`'s terms: a note is a
    /// disabled row with no command.
    private static func describeEntry(_ entry: ServersMenuEntry) -> String {
        switch entry {
        case .separator:
            return "separator"
        case .header(let title):
            return "header:\(title)"
        case .note(let text):
            return "item:\(text):false:none"
        case .item(let title, let isEnabled, let command):
            return "item:\(title):\(isEnabled):\(command)"
        }
    }
}

/// A target for rows built in a test; nothing sends to it.
@MainActor
private final class RowTarget: NSObject {
    @objc func chosen(_ sender: Any?) {}
}

/// The start and stop requests a fake daemon received, in order.
@MainActor
private final class ActionRecorder {
    var calls: [String] = []
}
