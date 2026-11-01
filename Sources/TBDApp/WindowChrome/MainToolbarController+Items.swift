import AppKit
import os
import SwiftUI
import TBDShared

private let itemsLogger = Logger(subsystem: "com.tbd.app", category: "window-chrome")

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

/// The key a toolbar item's image was last derived from, such as its symbol
/// name, and the item it was set on: an item rebuilt since then gets its image
/// whatever the key says.
struct ToolbarImageKey {
    weak var item: NSToolbarItem?
    var key: String
}

extension MainToolbarController {
    // MARK: Item construction

    /// A fresh item for `identifier`, as the delegate hands out. Content that
    /// follows `AppState` is filled in by `updateContent(_:)`, which looks the
    /// current item up by identifier. `nil` leaves the standard spaces to the
    /// toolbar, and refuses the tracking separator once its split is gone.
    ///
    /// - Parameter willBeInserted: false when AppKit asks for an item it will
    ///   not put in the toolbar. The title item then goes without the shared
    ///   title view, which one view can only be in once.
    func makeItem(_ identifier: NSToolbarItem.Identifier, willBeInserted: Bool) -> NSToolbarItem? {
        switch identifier {
        case MainToolbarItemID.toggleSidebar:
            return makeToggleItem()
        case MainToolbarItemID.back:
            return makeHistoryItem(identifier, symbol: "chevron.left", tip: "Back",
                                   action: #selector(navigateBack(_:)))
        case MainToolbarItemID.forward:
            return makeHistoryItem(identifier, symbol: "chevron.right", tip: "Forward",
                                   action: #selector(navigateForward(_:)))
        case MainToolbarItemID.repoFilter:
            return makeFilterItem()
        case MainToolbarItemID.sidebarSeparator:
            return makeTrackingSeparator()
        case MainToolbarItemID.title:
            return makeTitleItem(withView: willBeInserted)
        case MainToolbarItemID.servers:
            return makeServersItem()
        case MainToolbarItemID.remoteTranscript:
            return makeRemoteItem(identifier, symbol: "text.bubble", tip: "Show transcript",
                                  label: "Transcript", action: #selector(remoteTranscriptClicked(_:)))
        case MainToolbarItemID.remoteReconnect:
            return makeRemoteItem(identifier, symbol: "arrow.clockwise",
                                  tip: "Reconnect — restart this session's attach connection",
                                  label: "Reconnect", action: #selector(remoteReconnectClicked(_:)))
        case MainToolbarItemID.remoteStop:
            return makeRemoteItem(identifier, symbol: "stop.circle", tip: "Stop this remote session",
                                  label: "Stop", action: #selector(remoteStopClicked(_:)))
        default:
            return nil
        }
    }

    private func makeToggleItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: MainToolbarItemID.toggleSidebar)
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
        item.label = "Toggle Sidebar"
        item.toolTip = "Toggle Sidebar"
        item.isBordered = false
        item.target = split
        item.action = #selector(NSSplitViewController.toggleSidebar(_:))
        return item
    }

    /// The tracking separator, bound to the split's first divider as it is
    /// made and never changed afterwards: the window watches the item's split
    /// view through private KVO registrations, and re-binding an item whose
    /// earlier split view has gone raises. Once the split is gone there is
    /// nothing to bind it to, so the insert is refused and `ToolbarLayoutSync`
    /// lays out the rest without it.
    private func makeTrackingSeparator() -> NSToolbarItem? {
        guard let split else {
            itemsLogger.error("Main toolbar asked for the tracking separator after its split was gone")
            return nil
        }
        return NSTrackingSeparatorToolbarItem(
            identifier: MainToolbarItemID.sidebarSeparator, splitView: split.splitView, dividerIndex: 0)
    }

    /// Back or Forward. Not `isNavigational`, which would move it after the
    /// tracking separator. `autovalidates` is off because validation would
    /// enable it whenever its target answers the action; `canGoBack` and
    /// `canGoForward` decide instead.
    private func makeHistoryItem(
        _ identifier: NSToolbarItem.Identifier, symbol: String, tip: String, action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        item.label = tip
        item.toolTip = tip
        item.isBordered = false
        item.autovalidates = false
        item.isEnabled = false
        item.target = self
        item.action = action
        return item
    }

    /// The repo filter: a popup whose width is capped and whose compression
    /// resistance is low, so a long repo name truncates the title rather than
    /// widening the item past the sidebar's section, where AppKit would drop
    /// it without a trace.
    private func makeFilterItem() -> NSToolbarItem {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.bezelStyle = .toolbar
        popup.cell?.lineBreakMode = .byTruncatingTail
        // Items stay enabled whatever validation would say; every row is a
        // valid choice.
        popup.autoenablesItems = false
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(lessThanOrEqualToConstant: MainToolbarMetrics.filterMaxWidth).isActive = true
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        popup.toolTip = "Filter sidebar by repository"
        popup.target = self
        popup.action = #selector(filterChosen(_:))
        popup.menu?.delegate = filterMenuTracker

        let item = NSToolbarItem(itemIdentifier: MainToolbarItemID.repoFilter)
        item.view = popup
        item.label = "Filter"
        item.toolTip = "Filter sidebar by repository"
        return item
    }

    /// The title cluster. Its compression resistance sits below the
    /// right-hand items', so a long title truncates before they are dropped.
    private func makeTitleItem(withView: Bool) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: MainToolbarItemID.title)
        item.isBordered = false
        guard withView else { return item }
        titleView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        item.view = titleView
        return item
    }

    private func makeServersItem() -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: MainToolbarItemID.servers)
        item.label = "Servers"
        item.showsIndicator = true
        item.visibilityPriority = .high
        // Without a main URL the item has no action and a click opens the
        // menu; validation must not read the missing action as disabled.
        item.autovalidates = false
        item.isEnabled = true
        let menu = NSMenu(title: "Servers")
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        return item
    }

    private func makeRemoteItem(
        _ identifier: NSToolbarItem.Identifier, symbol: String, tip: String, label: String, action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        item.label = label
        item.toolTip = tip
        item.visibilityPriority = .high
        item.target = self
        item.action = action
        return item
    }

    // MARK: Content

    /// Updates the present items to `snapshot` without replacing any. Each
    /// value is set only when it differs from what the item holds, so an
    /// apply that changes nothing sets nothing.
    func updateContent(_ snapshot: MainToolbarSnapshot) {
        if let back = item(MainToolbarItemID.back), back.isEnabled != snapshot.canGoBack {
            back.isEnabled = snapshot.canGoBack
        }
        if let forward = item(MainToolbarItemID.forward), forward.isEnabled != snapshot.canGoForward {
            forward.isEnabled = snapshot.canGoForward
        }
        if let popup = item(MainToolbarItemID.repoFilter)?.view as? NSPopUpButton {
            updateFilter(popup, snapshot.filter)
        }
        if let servers = snapshot.servers,
           let serversItem = item(MainToolbarItemID.servers) as? NSMenuToolbarItem {
            updateServers(serversItem, servers)
        }
        if let remote = snapshot.remote, let transcript = item(MainToolbarItemID.remoteTranscript) {
            updateTranscript(transcript, remote)
        }
    }

    /// Sets `item`'s image from `make` when `key`, what the image is derived
    /// from, differs from the key it was last set from, or the item is not
    /// the one it was set on. Compared by key rather than by image, since an
    /// image made afresh is a new object for the same picture.
    private func setImage(_ item: NSToolbarItem, key: String, _ make: () -> NSImage?) {
        if let shown = shownImageKeys[item.itemIdentifier], shown.item === item, shown.key == key { return }
        item.image = make()
        shownImageKeys[item.itemIdentifier] = ToolbarImageKey(item: item, key: key)
    }

    private func updateTranscript(_ item: NSToolbarItem, _ remote: RemotePresentation) {
        let symbol = remote.transcriptSymbolName
        let help = remote.transcriptHelp
        setImage(item, key: "\(symbol)|\(help)") {
            NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        }
        if item.toolTip != help {
            item.toolTip = help
        }
    }

    private func updateFilter(_ popup: NSPopUpButton, _ filter: RepoFilterPresentation) {
        // Never under the pointer: the menu's close schedules an apply that
        // catches up.
        guard !filterMenuTracker.isOpen else { return }
        if popup !== builtFilterPopup || filter.options != builtFilterOptions {
            rebuildFilterItems(popup, options: filter.options)
        }
        selectFilter(popup, filter)
    }

    /// "All Repos", a separator, then each repo. Rows are added to the menu
    /// directly: `addItem(withTitle:)` drops a row whose title repeats, and two
    /// repos can share a display name.
    private func rebuildFilterItems(_ popup: NSPopUpButton, options: [RepoFilterPresentation.Option]) {
        popup.removeAllItems()
        guard let menu = popup.menu else { return }
        for (index, option) in options.enumerated() {
            let row = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            row.representedObject = option.id
            menu.addItem(row)
            if index == 0 { menu.addItem(.separator()) }
        }
        builtFilterPopup = popup
        builtFilterOptions = options
    }

    /// Checks the row the filter names, or none when it names a repo that is
    /// gone, as the SwiftUI `Picker` shows it, rather than a false "All Repos".
    /// Only when that differs from the popup's selection: an apply that finds
    /// the popup already showing the filter sets nothing.
    private func selectFilter(_ popup: NSPopUpButton, _ filter: RepoFilterPresentation) {
        let target = Self.filterRow(in: popup, for: filter)
        guard popup.indexOfSelectedItem != target else { return }
        if target < 0 {
            popup.select(nil)
        } else {
            popup.selectItem(at: target)
        }
        filterSelectionCount += 1
        itemsLogger.debug("Main toolbar filter selection \(self.filterSelectionCount, privacy: .public): row \(target, privacy: .public)")
    }

    /// The index of the row `filter` names, or -1, the popup's "no
    /// selection", when it names a repo that is gone.
    private static func filterRow(in popup: NSPopUpButton, for filter: RepoFilterPresentation) -> Int {
        guard filter.selectedIsKnown else { return -1 }
        let index = popup.itemArray.firstIndex { row in
            !row.isSeparatorItem && (row.representedObject as? UUID) == filter.selected
        }
        return index ?? -1
    }

    private func updateServers(_ item: NSMenuToolbarItem, _ servers: ServersPresentation) {
        if item.title != servers.title {
            item.title = servers.title
        }
        let colorScheme = currentColorScheme
        setImage(item, key: Self.serversImageKey(servers, colorScheme: colorScheme)) {
            serversImage(servers, colorScheme: colorScheme)
        }
        if item.toolTip != servers.help {
            item.toolTip = servers.help
        }
        // With a main URL a click opens it; without one the item has no
        // action, and a click opens the menu.
        let action: Selector? = servers.primaryURL == nil ? nil : #selector(openPrimaryServerURL(_:))
        let target: AnyObject? = action == nil ? nil : self
        if item.action != action {
            item.action = action
        }
        if item.target !== target {
            item.target = target
        }
        // An empty menu is seeded once; every open rebuilds it anyway.
        if item.menu.numberOfItems == 0 {
            rebuildServersMenu(item.menu)
        }
    }

    /// What a Servers icon is baked from: the running state, the appearance
    /// and the accessibility label.
    private static func serversImageKey(_ servers: ServersPresentation, colorScheme: ColorScheme) -> String {
        "\(servers.isRunning)-\(colorScheme)-\(servers.accessibilityLabel)"
    }

    /// The baked Servers icon for the appearance, copied so the copy can carry
    /// the accessibility label (`NSToolbarItem` has none of its own) without
    /// touching the image the SwiftUI label shares.
    private func serversImage(_ servers: ServersPresentation, colorScheme: ColorScheme) -> NSImage {
        let key = Self.serversImageKey(servers, colorScheme: colorScheme)
        if let cached = serversImages[key] { return cached }
        let baked = ServersButtonLabel.bakedIcon(running: servers.isRunning, colorScheme: colorScheme)
        guard let image = baked.copy() as? NSImage else { return baked }
        image.isTemplate = false
        image.accessibilityDescription = servers.accessibilityLabel
        serversImages[key] = image
        return image
    }

    // MARK: The Servers menu

    /// Rebuilds `menu` from `ServersToolbarMenu.entries` for the one selected
    /// worktree's current list. Empty when there is no single selection.
    func rebuildServersMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard appState.selectedWorktreeIDs.count == 1,
              let worktreeID = appState.selectedWorktreeIDs.first,
              let list = appState.devServerLists[worktreeID] else { return }
        let messages = appState.devServerActionMessages[worktreeID] ?? []
        for entry in ServersToolbarMenu.entries(list: list, messages: messages) {
            menu.addItem(menuItem(for: entry, worktreeID: worktreeID))
        }
    }

    private func menuItem(for entry: ServersMenuEntry, worktreeID: UUID) -> NSMenuItem {
        switch entry {
        case .item(let title, let isEnabled, let command):
            let row = NSMenuItem(title: title, action: #selector(serversMenuItemChosen(_:)), keyEquivalent: "")
            row.target = self
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

    /// Runs `command` through the `AppState` call the SwiftUI menu makes.
    func runServersCommand(_ command: ServersMenuCommand, worktreeID: UUID) {
        let appState = self.appState
        switch command {
        case .open(let url):
            appState.openDevServerURL(url)
        case .showLastOutput(let serverName):
            guard let server = appState.devServerLists[worktreeID]?.servers.first(where: { $0.name == serverName }) else {
                itemsLogger.debug("Show last output: \(serverName, privacy: .public) is no longer listed")
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

    // MARK: Actions

    @objc func navigateBack(_ sender: Any?) {
        appState.navigateBack()
    }

    @objc func navigateForward(_ sender: Any?) {
        appState.navigateForward()
    }

    @objc func filterChosen(_ sender: NSPopUpButton) {
        let chosen = sender.selectedItem?.representedObject as? UUID
        guard appState.repoFilter != chosen else { return }
        appState.repoFilter = chosen
    }

    @objc func openPrimaryServerURL(_ sender: Any?) {
        guard let url = appliedSnapshot?.servers?.primaryURL else { return }
        appState.openDevServerURL(url)
    }

    @objc func serversMenuItemChosen(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ServersMenuCommandBox else { return }
        runServersCommand(box.command, worktreeID: box.worktreeID)
    }

    // Each remote action reads the selection when it is clicked, so it acts
    // on the session selected now, not the one the item was built for.

    @objc func remoteTranscriptClicked(_ sender: Any?) {
        guard let selection = appState.selectedRemoteSession else { return }
        appState.toggleRemoteTranscript(selection)
    }

    @objc func remoteReconnectClicked(_ sender: Any?) {
        guard let selection = appState.selectedRemoteSession else { return }
        appState.reconnectRemoteSession(selection)
    }

    @objc func remoteStopClicked(_ sender: Any?) {
        guard let selection = appState.selectedRemoteSession else { return }
        requestRemoteStop(selection)
    }
}
