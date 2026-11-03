import AppKit
import os
import TBDShared

private let serversMenuLogger = Logger(subsystem: "com.tbd.app", category: "window-chrome")

/// A Servers menu row's command and the worktree it acts on, carried as the
/// row's `representedObject`.
final class ServersMenuCommandBox: NSObject {
    let worktreeID: UUID
    let command: ServersMenuCommand

    init(worktreeID: UUID, command: ServersMenuCommand) {
        self.worktreeID = worktreeID
        self.command = command
        super.init()
    }
}

/// The Servers menu as AppKit shows it, shared by the toolbar's Servers item
/// and the status bar's Servers chip: the rows `ServersToolbarMenu.entries`
/// lists, built into an `NSMenu`, and the `AppState` call each row's command
/// makes. Each caller names the target and action its rows send, so the
/// toolbar's rows keep targeting its controller and the chip's target its
/// own host; both actions hand the chosen row to `runChosen(_:appState:)`.
@MainActor
enum ServersMenu {
    /// The worktree the Servers menu is for: the one selected worktree, or
    /// nil with none or several selected.
    static func selectedWorktreeID(in appState: AppState) -> UUID? {
        appState.selectedWorktreeIDs.count == 1 ? appState.selectedWorktreeIDs.first : nil
    }

    /// Rebuilds `menu` from `ServersToolbarMenu.entries` for `worktreeID`'s
    /// current list and its last action's messages. Each row with a command
    /// sends `action` to `target`. Empty with no worktree, or one with no
    /// list.
    static func rebuild(
        _ menu: NSMenu, worktreeID: UUID?, appState: AppState, target: AnyObject, action: Selector
    ) {
        menu.removeAllItems()
        guard let worktreeID, let list = appState.devServerLists[worktreeID] else { return }
        let messages = appState.devServerActionMessages[worktreeID] ?? []
        for entry in ServersToolbarMenu.entries(list: list, messages: messages) {
            menu.addItem(item(for: entry, worktreeID: worktreeID, target: target, action: action))
        }
    }

    /// One row: an item sends `action` to `target`, carrying its command in a
    /// `ServersMenuCommandBox`; a header is a section header; a note is a
    /// disabled row with no action.
    static func item(
        for entry: ServersMenuEntry, worktreeID: UUID, target: AnyObject, action: Selector
    ) -> NSMenuItem {
        switch entry {
        case .item(let title, let isEnabled, let command):
            let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
            row.target = target
            row.isEnabled = isEnabled
            row.representedObject = ServersMenuCommandBox(worktreeID: worktreeID, command: command)
            return row
        case .header(let title):
            return NSMenuItem.sectionHeader(title: title)
        case .note(let text):
            let row = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            row.isEnabled = false
            return row
        case .separator:
            return NSMenuItem.separator()
        }
    }

    /// Runs the command a chosen row carries. Any other sender, a bare menu
    /// item, another control or none, runs nothing.
    static func runChosen(_ sender: Any?, appState: AppState) {
        guard let box = (sender as? NSMenuItem)?.representedObject as? ServersMenuCommandBox else { return }
        run(box.command, worktreeID: box.worktreeID, appState: appState)
    }

    /// Runs `command` for `worktreeID` through its `AppState` call.
    private static func run(_ command: ServersMenuCommand, worktreeID: UUID, appState: AppState) {
        switch command {
        case .open(let url):
            appState.openDevServerURL(url)
        case .showLastOutput(let serverName):
            guard let server = appState.devServerLists[worktreeID]?.servers.first(where: { $0.name == serverName }) else {
                serversMenuLogger.debug("Show last output: \(serverName, privacy: .public) is no longer listed")
                return
            }
            Task { await appState.showDevServerLastOutput(worktreeID: worktreeID, server: server) }
        case .stop(let names):
            Task { await appState.performDevServerAction(.stop, worktreeID: worktreeID, names: names) }
        case .restart(let names):
            Task { await appState.restartDevServers(worktreeID: worktreeID, names: names) }
        case .start(let names):
            Task { await appState.performDevServerAction(.start, worktreeID: worktreeID, names: names) }
        case .refreshStatus:
            Task { await appState.refreshDevServerStatus(worktreeID: worktreeID) }
        }
    }
}
