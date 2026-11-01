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
            return makeIconButtonItem(identifier, symbol: "sidebar.left", tip: "Toggle Sidebar",
                                      target: split, action: #selector(NSSplitViewController.toggleSidebar(_:)))
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

    /// A compact leading button: a view item whose view is an accessory-bar
    /// `NSButton`, `iconButtonWidth` by `iconButtonHeight`, with the symbol at
    /// `iconGlyphPointSize`. The button draws its bezel only while the pointer
    /// is over it, so it highlights on hover and shows no border at rest. A
    /// view item's target and action are its view's, and its overflow row is
    /// an explicit menu form carrying the same target and action.
    private func makeIconButtonItem(
        _ identifier: NSToolbarItem.Identifier, symbol: String, tip: String, target: AnyObject?, action: Selector
    ) -> NSToolbarItem {
        let button = NSButton(frame: NSRect(
            x: 0, y: 0, width: MainToolbarMetrics.iconButtonWidth, height: MainToolbarMetrics.iconButtonHeight))
        button.bezelStyle = .accessoryBar
        button.isBordered = true
        button.showsBorderOnlyWhileMouseInside = true
        button.title = ""
        button.image = Self.iconGlyph(symbol, description: tip)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: MainToolbarMetrics.iconButtonWidth),
            button.heightAnchor.constraint(equalToConstant: MainToolbarMetrics.iconButtonHeight),
        ])

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = button
        item.label = tip
        item.toolTip = tip
        let form = NSMenuItem(title: tip, action: action, keyEquivalent: "")
        form.target = target
        item.menuFormRepresentation = form
        return item
    }

    /// `symbol` at the leading buttons' point size and regular weight,
    /// carrying `description` for accessibility.
    private static func iconGlyph(_ symbol: String, description: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: MainToolbarMetrics.iconGlyphPointSize, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        image?.accessibilityDescription = description
        return image
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

    /// Back or Forward, a compact leading button. Not `isNavigational`, which
    /// would move it after the tracking separator. `autovalidates` is off
    /// because validation would enable it whenever its target answers the
    /// action; `canGoBack` and `canGoForward` decide instead, through
    /// `updateContent(_:)`, and `validateMenuItem(_:)` for its overflow row.
    /// It starts disabled, as do its button, which `isEnabled` forwards to,
    /// and its overflow row.
    private func makeHistoryItem(
        _ identifier: NSToolbarItem.Identifier, symbol: String, tip: String, action: Selector
    ) -> NSToolbarItem {
        let item = makeIconButtonItem(identifier, symbol: symbol, tip: tip, target: self, action: action)
        item.autovalidates = false
        item.isEnabled = false
        item.menuFormRepresentation?.isEnabled = false
        return item
    }

    /// The repo filter: a popup whose width is capped and whose compression
    /// resistance is low, so a long repo name truncates the title rather than
    /// widening the item past the sidebar's section, where AppKit would move
    /// it into the overflow menu.
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
        item.menuFormRepresentation = makeFilterForm()
        return item
    }

    /// The filter's overflow row: "Filter", with a submenu of the popup's
    /// rows, each choosing its repo through `filterChosen(_:)`.
    /// `updateFilter` fills and checks the rows alongside the popup's. Without
    /// it, AppKit's default row would send the popup's action from a bare
    /// menu item. The submenu reports its opening to `filterMenuTracker`, so
    /// its rows are not rebuilt under the pointer either.
    private func makeFilterForm() -> NSMenuItem {
        let form = NSMenuItem(title: "Filter", action: nil, keyEquivalent: "")
        let rows = NSMenu(title: "Filter")
        rows.autoenablesItems = false
        rows.delegate = filterMenuTracker
        form.submenu = rows
        return form
    }

    /// The title cluster, in the shared title view, whose width constraints
    /// `prepareTitleView(_:)` set once. Its visibility priority stays
    /// standard, below the right-hand items' `.high`, so a long title gives
    /// way before they overflow. Its overflow row is inert, showing the
    /// title; `updateContent(_:)` fills it in.
    private func makeTitleItem(withView: Bool) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: MainToolbarItemID.title)
        item.isBordered = false
        item.menuFormRepresentation = Self.makeTitleForm()
        if withView {
            item.view = titleView
        }
        return item
    }

    /// An inert overflow row for the title: disabled, with no action, and
    /// hidden until there is a title to show. AppKit's default would be a
    /// clickable row titled with the item's label, which is empty.
    private static func makeTitleForm() -> NSMenuItem {
        let form = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        form.isEnabled = false
        form.isHidden = true
        return form
    }

    /// Makes `view` a flexible toolbar item view whose width never follows
    /// its content. The toolbar measures a view item through its
    /// constraints, so the view holds a required minimum and maximum and
    /// prefers the maximum, which fills the space up to the right-hand items.
    /// Its own hugging and compression resistance sit below
    /// `.fittingSizeCompression`, and the preference for the maximum sits
    /// between the two, so a fitting-size measurement reaches the minimum
    /// and the content's width never decides the item's. Called once, from
    /// `init`: the view is shared by every title item.
    static func prepareTitleView(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(titleContentPriority, for: .horizontal)
        view.setContentCompressionResistancePriority(titleContentPriority, for: .horizontal)
        let minimum = view.widthAnchor.constraint(greaterThanOrEqualToConstant: MainToolbarMetrics.titleMinimumWidth)
        minimum.identifier = titleMinimumWidthID
        let maximum = view.widthAnchor.constraint(lessThanOrEqualToConstant: MainToolbarMetrics.titleMaximumWidth)
        maximum.identifier = titleMaximumWidthID
        let fill = view.widthAnchor.constraint(equalToConstant: MainToolbarMetrics.titleMaximumWidth)
        fill.priority = titleFillPriority
        fill.identifier = titleFillWidthID
        NSLayoutConstraint.activate([minimum, maximum, fill])
    }

    /// The identifiers of the title view's width constraints, which name them
    /// in a layout log and let a test find them among any others.
    static let titleMinimumWidthID = "tbd.toolbar.title.minimumWidth"
    static let titleMaximumWidthID = "tbd.toolbar.title.maximumWidth"
    static let titleFillWidthID = "tbd.toolbar.title.fillWidth"

    /// The title view's horizontal hugging and compression resistance: the
    /// lowest there is, so its content's width never holds the item open or
    /// shut.
    static let titleContentPriority = NSLayoutConstraint.Priority(rawValue: 1)

    /// The title view's preference for `titleMaximumWidth`: above its
    /// hugging, so in layout it fills, and below `.fittingSizeCompression`,
    /// so a fitting-size measurement still compresses it to the minimum.
    static let titleFillPriority = NSLayoutConstraint.Priority(
        rawValue: NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1)

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
        if let back = item(MainToolbarItemID.back) {
            updateEnabled(back, snapshot.canGoBack)
        }
        if let forward = item(MainToolbarItemID.forward) {
            updateEnabled(forward, snapshot.canGoForward)
        }
        if let filterItem = item(MainToolbarItemID.repoFilter), let popup = filterItem.view as? NSPopUpButton {
            updateFilter(popup, form: filterItem.menuFormRepresentation?.submenu, snapshot.filter)
        }
        if let titleForm = item(MainToolbarItemID.title)?.menuFormRepresentation {
            updateTitleForm(titleForm, snapshot.title)
        }
        if let servers = snapshot.servers,
           let serversItem = item(MainToolbarItemID.servers) as? NSMenuToolbarItem {
            updateServers(serversItem, servers)
        }
        if let remote = snapshot.remote, let transcript = item(MainToolbarItemID.remoteTranscript) {
            updateTranscript(transcript, remote)
        }
    }

    /// Enables or disables `item`, and with it its button and its overflow
    /// row, setting each only when it differs. The overflow menu may or may
    /// not validate its rows, so the row's own flag follows too.
    private func updateEnabled(_ item: NSToolbarItem, _ enabled: Bool) {
        if item.isEnabled != enabled {
            item.isEnabled = enabled
        }
        if let form = item.menuFormRepresentation, form.isEnabled != enabled {
            form.isEnabled = enabled
        }
    }

    /// Shows `title` in the title's overflow row, hidden when there is none.
    private func updateTitleForm(_ form: NSMenuItem, _ title: String?) {
        let text = title ?? ""
        if form.title != text {
            form.title = text
        }
        if form.isHidden != text.isEmpty {
            form.isHidden = text.isEmpty
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

    /// Brings the popup and the filter's overflow rows, `form`, to `filter`.
    /// The two are built from one list of options, so their rows match.
    private func updateFilter(_ popup: NSPopUpButton, form: NSMenu?, _ filter: RepoFilterPresentation) {
        // Never under the pointer: the menu's close schedules an apply that
        // catches up.
        guard !filterMenuTracker.isOpen else { return }
        if popup !== builtFilterPopup || filter.options != builtFilterOptions {
            rebuildFilterItems(popup, form: form, options: filter.options)
        }
        selectFilter(popup, filter)
        if let form {
            checkFilterRow(in: form, filter)
        }
    }

    /// Rebuilds the popup's rows and the overflow rows. The popup's rows have
    /// no action, as the popup sends its own; each overflow row sends
    /// `filterChosen(_:)` itself. They are rebuilt together because they are
    /// made together, in `makeFilterItem()`.
    private func rebuildFilterItems(
        _ popup: NSPopUpButton, form: NSMenu?, options: [RepoFilterPresentation.Option]
    ) {
        popup.removeAllItems()
        if let menu = popup.menu {
            fillFilterRows(menu, options: options, action: nil)
        }
        if let form {
            fillFilterRows(form, options: options, action: #selector(filterChosen(_:)))
        }
        builtFilterPopup = popup
        builtFilterOptions = options
    }

    /// "All Repos", a separator, then each repo, each row carrying its repo's
    /// ID, or none for "All Repos", and sending `action` to the controller
    /// when one is given. Rows are added to the menu directly:
    /// `addItem(withTitle:)` drops a row whose title repeats, and two repos
    /// can share a display name.
    private func fillFilterRows(_ menu: NSMenu, options: [RepoFilterPresentation.Option], action: Selector?) {
        menu.removeAllItems()
        for (index, option) in options.enumerated() {
            let row = NSMenuItem(title: option.title, action: action, keyEquivalent: "")
            if action != nil {
                row.target = self
            }
            row.representedObject = option.id
            menu.addItem(row)
            if index == 0 { menu.addItem(.separator()) }
        }
    }

    /// Checks the row the filter names, or none when it names a repo that is
    /// gone, as the SwiftUI `Picker` shows it, rather than a false "All Repos".
    /// Only when that differs from the popup's selection: an apply that finds
    /// the popup already showing the filter sets nothing.
    private func selectFilter(_ popup: NSPopUpButton, _ filter: RepoFilterPresentation) {
        let target = Self.filterRow(in: popup.itemArray, for: filter)
        guard popup.indexOfSelectedItem != target else { return }
        if target < 0 {
            popup.select(nil)
        } else {
            popup.selectItem(at: target)
        }
        filterSelectionCount += 1
        itemsLogger.debug("Main toolbar filter selection \(self.filterSelectionCount, privacy: .public): row \(target, privacy: .public)")
    }

    /// Puts the check on the overflow row the filter names and takes it off
    /// the rest, or checks none when it names a repo that is gone, as
    /// `selectFilter` does for the popup. Sets only the rows whose state
    /// differs.
    private func checkFilterRow(in menu: NSMenu, _ filter: RepoFilterPresentation) {
        let target = Self.filterRow(in: menu.items, for: filter)
        for (index, row) in menu.items.enumerated() where !row.isSeparatorItem {
            let state: NSControl.StateValue = index == target ? .on : .off
            if row.state != state {
                row.state = state
            }
        }
    }

    /// The index among `rows` of the row `filter` names, or -1, the popup's
    /// "no selection", when it names a repo that is gone.
    private static func filterRow(in rows: [NSMenuItem], for filter: RepoFilterPresentation) -> Int {
        guard filter.selectedIsKnown else { return -1 }
        let index = rows.firstIndex { row in
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

    // Every action the toolbar wires takes `Any?` and checks the sender's
    // class itself. A view item's overflow row sends the item's action from
    // an `NSMenuItem`, and Swift does not check the class of an `@objc`
    // argument: a method typed for another sender would message the menu item
    // with a selector it does not answer, which raises.

    @objc func navigateBack(_ sender: Any?) {
        appState.navigateBack()
    }

    @objc func navigateForward(_ sender: Any?) {
        appState.navigateForward()
    }

    /// Sets the filter to the row chosen: the popup's selected row, or the
    /// overflow row that sent it. Its repo ID, or none for "All Repos", is
    /// the row's represented object. A sender that is neither changes
    /// nothing.
    @objc func filterChosen(_ sender: Any?) {
        guard let row = (sender as? NSPopUpButton)?.selectedItem ?? (sender as? NSMenuItem) else { return }
        let chosen = row.representedObject as? UUID
        guard appState.repoFilter != chosen else { return }
        appState.repoFilter = chosen
    }

    @objc func openPrimaryServerURL(_ sender: Any?) {
        guard let url = appliedSnapshot?.servers?.primaryURL else { return }
        appState.openDevServerURL(url)
    }

    @objc func serversMenuItemChosen(_ sender: Any?) {
        guard let box = (sender as? NSMenuItem)?.representedObject as? ServersMenuCommandBox else { return }
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
