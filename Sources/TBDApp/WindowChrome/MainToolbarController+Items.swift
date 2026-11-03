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

/// The view of the toolbar's leading item: a plain view holding the sidebar
/// toggle, Back and Forward, three `ToolbarIconButton`s side by side, each
/// `MainToolbarMetrics.iconButtonPitch` wide, so their centres sit one pitch
/// apart. They share one item because AppKit gives each separate unbordered
/// view item a fixed 44 pt slot, centred on its view, whatever the view's
/// width (measured: hosts 8, 20 and 32 pt wide all sat 44 pt apart), so three
/// items could never sit 28 pt apart.
///
/// No button is the item's view because `NSToolbarItem` forwards
/// `isBordered`, `isEnabled`, `target`, `action` and `image` to a view that
/// answers them. A bordered button as an item's view makes the item bordered,
/// which gives it a Liquid Glass background. A plain view answers none of
/// them, so the item keeps its own `isBordered = false` and shows no glass,
/// while the buttons one level down draw their own hover square. That is why
/// this class must not gain any of those properties. The item stays enabled;
/// `updateContent(_:)` enables Back and Forward on their buttons.
///
/// AppKit measures the host, which holds the item's size by required
/// constraints, three pitches by one button's height. Each button holds one
/// pitch by a required width constraint, and required constraints chain them
/// leading to trailing, make each square and centre it vertically in the
/// host, so they tile the host (`ToolbarButtonTiling`). The host is not an accessibility
/// element, so VoiceOver lands on each button.
///
/// The host keeps no stored property: its buttons are its subviews, found by
/// their identifiers. It decodes, where views here usually leave
/// `init(coder:)` unavailable, because AppKit copies a view item by archiving
/// its view and unarchiving the copy, and an unavailable decoder would crash
/// that copy. The buttons come back from the archive as subviews, and the
/// constraints with them because they are marked `shouldBeArchived`: AppKit
/// archives no constraint made in code otherwise. Accessibility is not
/// archived, so the decoder sets it again.
final class LeadingToolbarButtonsHost: NSView {
    static let toggleID = NSUserInterfaceItemIdentifier("tbd.toolbar.leadingButtons.toggle")
    static let backID = NSUserInterfaceItemIdentifier("tbd.toolbar.leadingButtons.back")
    static let forwardID = NSUserInterfaceItemIdentifier("tbd.toolbar.leadingButtons.forward")

    /// The identifiers of the host's size constraints and of each button's
    /// width constraint, which name them in a layout log and let a test find
    /// them among the others.
    static let widthID = "tbd.toolbar.leadingButtons.width"
    static let heightID = "tbd.toolbar.leadingButtons.height"
    static let buttonWidthID = "tbd.toolbar.leadingButtons.buttonWidth"

    var toggleButton: NSButton? { ToolbarButtonTiling.button(Self.toggleID, in: self) }
    var backButton: NSButton? { ToolbarButtonTiling.button(Self.backID, in: self) }
    var forwardButton: NSButton? { ToolbarButtonTiling.button(Self.forwardID, in: self) }

    /// Lays out `toggle`, `back` and `forward` in that order, leading to
    /// trailing, and gives each its identifier.
    init(toggle: NSButton, back: NSButton, forward: NSButton) {
        let size = NSSize(width: MainToolbarMetrics.leadingButtonsWidth, height: MainToolbarMetrics.iconButtonHeight)
        super.init(frame: NSRect(origin: .zero, size: size))
        ToolbarButtonTiling.tile(
            [(toggle, Self.toggleID), (back, Self.backID), (forward, Self.forwardID)], in: self,
            widthID: Self.widthID, heightID: Self.heightID, buttonWidthID: Self.buttonWidthID)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
    }
}

/// The view of the toolbar's repo filter item: a plain view holding one
/// `ToolbarIconButton`, one pitch by one button's height, which pops up the
/// filter menu. A plain host for the reason `LeadingToolbarButtonsHost`
/// gives: it answers none of the properties an item forwards to its view, so
/// the item stays unbordered and shows no Liquid Glass. It must not gain any
/// of them either.
///
/// The host holds its size by required constraints and the button tiles it
/// (`ToolbarButtonTiling`). Like the leading host it keeps no stored
/// property, decodes for AppKit's copy of the item with its constraints
/// archived, and is not an accessibility element, so VoiceOver lands on the
/// button.
final class FilterToolbarButtonHost: NSView {
    static let buttonID = NSUserInterfaceItemIdentifier("tbd.toolbar.repoFilter.button")

    /// The identifiers of the host's size constraints and of the button's
    /// width constraint.
    static let widthID = "tbd.toolbar.repoFilter.width"
    static let heightID = "tbd.toolbar.repoFilter.height"
    static let buttonWidthID = "tbd.toolbar.repoFilter.buttonWidth"

    var button: NSButton? { ToolbarButtonTiling.button(Self.buttonID, in: self) }

    init(button: NSButton) {
        let size = NSSize(width: MainToolbarMetrics.iconButtonPitch, height: MainToolbarMetrics.iconButtonHeight)
        super.init(frame: NSRect(origin: .zero, size: size))
        ToolbarButtonTiling.tile(
            [(button, Self.buttonID)], in: self,
            widthID: Self.widthID, heightID: Self.heightID, buttonWidthID: Self.buttonWidthID)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
    }
}

/// The layout the toolbar's button hosts share: buttons side by side, one
/// pitch each, tiling their host.
@MainActor
enum ToolbarButtonTiling {
    /// Holds `host` at the buttons' pitches by one button's height, adds each
    /// button with its identifier, one pitch wide, chained leading to
    /// trailing, square (height equal to width) and centred vertically in the
    /// host, so the buttons tile the host over their own intrinsic size. Every constraint is required,
    /// carries `widthID`, `heightID` or `buttonWidthID` where it holds a
    /// size, and is archived with the host, so a copied item keeps its size
    /// and layout.
    static func tile(
        _ buttons: [(NSButton, NSUserInterfaceItemIdentifier)], in host: NSView,
        widthID: String, heightID: String, buttonWidthID: String
    ) {
        host.translatesAutoresizingMaskIntoConstraints = false
        let width = host.widthAnchor.constraint(
            equalToConstant: CGFloat(buttons.count) * MainToolbarMetrics.iconButtonPitch)
        width.identifier = widthID
        let height = host.heightAnchor.constraint(equalToConstant: MainToolbarMetrics.iconButtonHeight)
        height.identifier = heightID
        var layout = [width, height]
        var previousEdge = host.leadingAnchor
        for (button, identifier) in buttons {
            button.identifier = identifier
            button.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(button)
            let buttonWidth = button.widthAnchor.constraint(equalToConstant: MainToolbarMetrics.iconButtonPitch)
            buttonWidth.identifier = buttonWidthID
            layout += [
                button.leadingAnchor.constraint(equalTo: previousEdge),
                button.heightAnchor.constraint(equalTo: button.widthAnchor),
                button.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                buttonWidth,
            ]
            previousEdge = button.trailingAnchor
        }
        layout.append(previousEdge.constraint(equalTo: host.trailingAnchor))
        for constraint in layout {
            constraint.shouldBeArchived = true
        }
        NSLayoutConstraint.activate(layout)
    }

    /// The subview button of `host` carrying `identifier`.
    static func button(_ identifier: NSUserInterfaceItemIdentifier, in host: NSView) -> NSButton? {
        host.subviews.lazy.compactMap { $0 as? NSButton }.first { $0.identifier == identifier }
    }
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
        case MainToolbarItemID.leadingButtons:
            return makeLeadingButtonsItem()
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

    /// The leading item: a view item whose view is a
    /// `LeadingToolbarButtonsHost` holding the sidebar toggle, Back and
    /// Forward. The item is not bordered, and the host answers none of the
    /// properties an item forwards to its view, so the item has no Liquid
    /// Glass background (see `LeadingToolbarButtonsHost`). The item keeps no
    /// target, action or tool tip: each button carries its own, and so does
    /// each row of the overflow form. `NSToolbarItem` forwards a tool tip to
    /// any view, as every view answers it, so one set on the item would sit
    /// on the host, under buttons that cover it.
    ///
    /// The item stays enabled: Back and Forward are enabled on their buttons
    /// and rows, which start disabled, by `updateContent(_:)`. It does not
    /// autovalidate: `NSToolbarItem.h` documents that `validate` does nothing
    /// for an item with a custom view, and the toggle stays enabled while
    /// Back and Forward follow the snapshot. Not `isNavigational`, which
    /// would move it after the tracking separator.
    private func makeLeadingButtonsItem() -> NSToolbarItem {
        let toggle = Self.makeLeadingButton(
            symbol: "sidebar.left", tip: "Toggle Sidebar",
            target: split, action: #selector(NSSplitViewController.toggleSidebar(_:)))
        let back = Self.makeLeadingButton(
            symbol: "chevron.left", tip: "Back", target: self, action: #selector(navigateBack(_:)))
        let forward = Self.makeLeadingButton(
            symbol: "chevron.right", tip: "Forward", target: self, action: #selector(navigateForward(_:)))
        back.isEnabled = false
        forward.isEnabled = false

        let item = NSToolbarItem(itemIdentifier: MainToolbarItemID.leadingButtons)
        item.view = LeadingToolbarButtonsHost(toggle: toggle, back: back, forward: forward)
        item.isBordered = false
        item.autovalidates = false
        item.label = Self.leadingButtonsLabel
        item.menuFormRepresentation = makeLeadingButtonsForm()
        return item
    }

    /// The leading item's label, which titles its overflow row.
    static let leadingButtonsLabel = "Navigation"

    /// One leading button: a `ToolbarIconButton` showing `symbol` at
    /// `iconGlyphPointSize`, one pitch by `iconButtonHeight`, which draws its
    /// hover square over its whole frame and does not scale its image, which
    /// `iconGlyph` sizes.
    private static func makeLeadingButton(
        symbol: String, tip: String, target: AnyObject?, action: Selector
    ) -> NSButton {
        let button = makeIconButton(symbol: symbol, description: tip)
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.target = target
        button.action = action
        return button
    }

    /// A `ToolbarIconButton`, one pitch by `iconButtonHeight`, showing
    /// `symbol` through `iconGlyph`, carrying `description` for
    /// accessibility.
    private static func makeIconButton(symbol: String, description: String) -> ToolbarIconButton {
        let button = ToolbarIconButton(frame: NSRect(
            x: 0, y: 0, width: MainToolbarMetrics.iconButtonPitch, height: MainToolbarMetrics.iconButtonHeight))
        button.image = iconGlyph(symbol, description: description)
        return button
    }

    /// The leading item's overflow row: "Navigation", with a submenu of
    /// "Toggle Sidebar", "Back" and "Forward", each sending its button's
    /// action to its button's target. The submenu does not autoenable, so
    /// Back and Forward start disabled, as their buttons do, and
    /// `updateContent(_:)` keeps them in step with history;
    /// `validateMenuItem(_:)` answers for them too, should a menu ask.
    private func makeLeadingButtonsForm() -> NSMenuItem {
        let form = NSMenuItem(title: Self.leadingButtonsLabel, action: nil, keyEquivalent: "")
        let rows = NSMenu(title: Self.leadingButtonsLabel)
        rows.autoenablesItems = false
        let toggle = NSMenuItem(
            title: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "")
        toggle.target = split
        let back = NSMenuItem(title: "Back", action: #selector(navigateBack(_:)), keyEquivalent: "")
        back.target = self
        back.isEnabled = false
        let forward = NSMenuItem(title: "Forward", action: #selector(navigateForward(_:)), keyEquivalent: "")
        forward.target = self
        forward.isEnabled = false
        for row in [toggle, back, forward] {
            rows.addItem(row)
        }
        form.submenu = rows
        return form
    }

    /// `symbol` at the toolbar icon buttons' point size, regular weight and
    /// medium scale, carrying `description` for accessibility. The scale is
    /// named because a toolbar draws its buttons at large control size, which
    /// scales up a symbol whose configuration names none: measured in the
    /// running app, the toggle's ink drew 19.5 by 15 pt and each chevron's
    /// 8 by 14 pt, about 1.25 times the size medium gives (15 by 12 and
    /// 6 by 11 pt).
    private static func iconGlyph(_ symbol: String, description: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: MainToolbarMetrics.iconGlyphPointSize, weight: .regular, scale: .medium)
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

    /// The repo filter: a view item whose view is a `FilterToolbarButtonHost`
    /// holding one `ToolbarIconButton`, the same size and glyph size as Back
    /// and Forward, showing `line.3.horizontal.decrease`. A click pops up
    /// `filterMenu` under the button (`filterButtonClicked(_:)`). The item is
    /// not bordered and its host forwards nothing, so it has no Liquid Glass
    /// background; it keeps no target, action or tool tip, which sit on the
    /// button, and does not autovalidate, for the reasons the leading item
    /// gives (`makeLeadingButtonsItem()`).
    ///
    /// The button's tint, tool tip and accessibility value, and the overflow
    /// row, start from what the last apply showed, so an item the toolbar
    /// re-inserts, as after a collapse, shows the filter until it changes.
    private func makeFilterItem() -> NSToolbarItem {
        let button = Self.makeIconButton(symbol: Self.filterSymbol, description: Self.filterLabel)
        button.setAccessibilityLabel(Self.filterLabel)
        button.target = self
        button.action = #selector(filterButtonClicked(_:))
        Self.showFilter(appliedSnapshot?.filter, on: button)

        let item = NSToolbarItem(itemIdentifier: MainToolbarItemID.repoFilter)
        item.view = FilterToolbarButtonHost(button: button)
        item.isBordered = false
        item.autovalidates = false
        item.label = Self.filterLabel
        item.menuFormRepresentation = makeFilterForm(appliedSnapshot?.filter)
        return item
    }

    /// The filter item's label, which titles its overflow row, and its
    /// button's accessibility label and glyph description.
    static let filterLabel = "Filter"

    /// The filter button's glyph.
    static let filterSymbol = "line.3.horizontal.decrease"

    /// The filter button's tint while a repo filter is set.
    static let activeFilterTint = NSColor.systemBlue

    /// How far below the filter button the top of its menu sits.
    static let filterMenuGap: CGFloat = 4

    /// Shows `filter` on the filter button, setting each value only when it
    /// differs: tinted `activeFilterTint` while a repo filter is set and
    /// untinted, the other icons' colour, while none is, whatever the Show
    /// Hidden Repos toggle says; `help` as its tool tip; and
    /// `accessibilityValue` as its accessibility value. `nil`, before any
    /// apply, shows no filter.
    private static func showFilter(_ filter: RepoFilterPresentation?, on button: NSButton) {
        let tint: NSColor? = filter?.isActive == true ? activeFilterTint : nil
        if button.contentTintColor != tint {
            button.contentTintColor = tint
        }
        let help = filter?.help ?? RepoFilterPresentation.inactiveHelp
        if button.toolTip != help {
            button.toolTip = help
        }
        let value = filter?.accessibilityValue ?? RepoFilterPresentation.allReposTitle
        if (button.accessibilityValue() as? String) != value {
            button.setAccessibilityValue(value)
        }
    }

    /// Where `filterMenu`'s top leading corner goes, in the coordinates of a
    /// button with `bounds`: `filterMenuGap` below the button's bottom
    /// leading corner. `NSMenu` puts the menu's top left corner there, or its
    /// top right under a right-to-left layout, so the point is the bottom
    /// left or the bottom right; the bottom is the larger y in a flipped
    /// view and the smaller in one that is not.
    static func filterMenuOrigin(in bounds: NSRect, flipped: Bool, rightToLeft: Bool) -> NSPoint {
        let x = rightToLeft ? bounds.maxX : bounds.minX
        let y = flipped ? bounds.maxY + filterMenuGap : bounds.minY - filterMenuGap
        return NSPoint(x: x, y: y)
    }

    /// The filter's overflow row: "Filter", with a submenu of the same rows
    /// as `filterMenu`, each repo row choosing its repo through
    /// `filterChosen(_:)` and the Show Hidden Repos row flipping the toggle
    /// through `showHiddenReposChosen(_:)`, the row `filter` names checked,
    /// or none when it names a repo that is gone, and the toggle's row
    /// checked while hidden repos show. Empty without a filter. Without it,
    /// AppKit's default row would be an inert "Filter": the item has no
    /// action, as its host answers none. The row carries `filter` as its
    /// represented object, so `updateFilterForm` can tell whether it is
    /// current. The submenu reports its opening to `filterMenuTracker`, so it
    /// is not replaced under the pointer.
    private func makeFilterForm(_ filter: RepoFilterPresentation?) -> NSMenuItem {
        let form = NSMenuItem(title: Self.filterLabel, action: nil, keyEquivalent: "")
        form.representedObject = filter
        let rows = NSMenu(title: Self.filterLabel)
        rows.autoenablesItems = false
        rows.delegate = filterMenuTracker
        if let filter {
            fillFilterRows(rows, for: filter)
            Self.checkFilterRow(in: rows, for: filter)
        }
        form.submenu = rows
        return form
    }

    /// The title cluster, in the shared title view, whose width constraints
    /// `prepareTitleView(_:)` set once. Its visibility priority stays
    /// standard, below the right-hand items' `.high`, so a long title gives
    /// way before they overflow. Its overflow row is inert, showing the
    /// title the last apply showed; `updateContent(_:)` replaces it whenever
    /// the title changes.
    private func makeTitleItem(withView: Bool) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: MainToolbarItemID.title)
        item.isBordered = false
        item.menuFormRepresentation = Self.makeTitleForm(appliedSnapshot?.title)
        if withView {
            item.view = titleView
        }
        return item
    }

    /// An inert overflow row showing `title`, or "No Selection" when there is
    /// none: disabled, with no action, and never hidden. With nothing
    /// selected the title item still holds its minimum width, so it can be
    /// the only item that overflows, and a hidden row would leave the
    /// overflow menu empty. AppKit's default would be a clickable row titled
    /// with the item's label, which is empty.
    private static func makeTitleForm(_ title: String?) -> NSMenuItem {
        let form = NSMenuItem(title: titleRowText(title), action: nil, keyEquivalent: "")
        form.isEnabled = false
        return form
    }

    /// The text the title's overflow row shows: the title, or "No Selection"
    /// when there is none.
    private static func titleRowText(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "No Selection" }
        return title
    }

    /// Makes `view` a flexible toolbar item view whose width never follows
    /// its content. It holds a required minimum and maximum and prefers the
    /// maximum, so when AppKit measures the item's range through its
    /// constraints the item can shrink toward the minimum or grow toward the
    /// maximum, filling the space up to the right-hand items. Its compression
    /// resistance sits just above `.fittingSizeCompression`, so a fitting
    /// measurement gives its intrinsic width, which for the title cluster's
    /// hosting view is the constant `titleIdealWidth`; its hugging sits below
    /// the preference for the maximum, which sits below a fitting
    /// measurement's pull. Called once, from `init`: the view is shared by
    /// every title item.
    static func prepareTitleView(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(titleHuggingPriority, for: .horizontal)
        view.setContentCompressionResistancePriority(titleCompressionResistance, for: .horizontal)
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

    /// The title view's horizontal hugging: the lowest there is, so in
    /// layout the preference for the maximum outweighs it and the item fills.
    static let titleHuggingPriority = NSLayoutConstraint.Priority(rawValue: 1)

    /// The title view's horizontal compression resistance: just above
    /// `.fittingSizeCompression`, so a fitting measurement stops at its
    /// intrinsic width, the constant `titleIdealWidth` for the title
    /// cluster's hosting view, rather than at the minimum. The required
    /// minimum still lets the toolbar shrink it below that.
    static let titleCompressionResistance = NSLayoutConstraint.Priority(
        rawValue: NSLayoutConstraint.Priority.fittingSizeCompression.rawValue + 1)

    /// The title view's preference for `titleMaximumWidth`: above its
    /// hugging, so in layout it fills, and below `.fittingSizeCompression`,
    /// so it does not decide a fitting measurement.
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

    /// A remote session button. Its overflow row is explicit, titled with
    /// its label and carrying its target and action: AppKit documents a
    /// default row with a target and action only for standard items.
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
        let form = NSMenuItem(title: label, action: action, keyEquivalent: "")
        form.target = self
        item.menuFormRepresentation = form
        return item
    }

    // MARK: Content

    /// Updates the present items to `snapshot` without replacing any. Each
    /// value is set only when it differs from what the item holds, so an
    /// apply that changes nothing sets nothing.
    func updateContent(_ snapshot: MainToolbarSnapshot) {
        if let leading = item(MainToolbarItemID.leadingButtons) {
            updateHistory(leading, snapshot)
        }
        if let filterItem = item(MainToolbarItemID.repoFilter) {
            updateFilter(filterItem, snapshot.filter)
        }
        if let titleItem = item(MainToolbarItemID.title) {
            updateTitleForm(titleItem, snapshot.title)
        }
        if let servers = snapshot.servers,
           let serversItem = item(MainToolbarItemID.servers) as? NSMenuToolbarItem {
            updateServers(serversItem, servers)
        }
        if let remote = snapshot.remote, let transcript = item(MainToolbarItemID.remoteTranscript) {
            updateTranscript(transcript, remote)
        }
    }

    /// Enables Back and Forward, button and overflow row, from the
    /// snapshot's `canGoBack` and `canGoForward`. Each flag is set only when
    /// it differs, so an apply that changes nothing sets nothing, and a row
    /// that drifted comes back on the next apply; the row's own flag matters
    /// because the overflow menu may or may not validate its rows. The item
    /// itself stays enabled. An item whose view is not the host, or a host
    /// missing a button, is logged and skipped.
    private func updateHistory(_ item: NSToolbarItem, _ snapshot: MainToolbarSnapshot) {
        guard let host = item.view as? LeadingToolbarButtonsHost,
              let back = host.backButton, let forward = host.forwardButton else {
            let kind = item.view.map { String(describing: type(of: $0)) } ?? "no view"
            itemsLogger.error(
                "Main toolbar's leading item holds \(kind, privacy: .public), not its three buttons; skipped")
            return
        }
        let rows = item.menuFormRepresentation?.submenu?.items ?? []
        let backRow = rows.first { $0.action == #selector(navigateBack(_:)) }
        let forwardRow = rows.first { $0.action == #selector(navigateForward(_:)) }
        Self.updateEnabled(back, backRow, snapshot.canGoBack)
        Self.updateEnabled(forward, forwardRow, snapshot.canGoForward)
    }

    /// Sets `button` and `row` to `enabled`, each only when it differs.
    private static func updateEnabled(_ button: NSButton, _ row: NSMenuItem?, _ enabled: Bool) {
        if button.isEnabled != enabled {
            button.isEnabled = enabled
        }
        if let row, row.isEnabled != enabled {
            row.isEnabled = enabled
        }
    }

    /// Gives the title item a fresh overflow row showing `title`, or "No
    /// Selection" when there is none, when its row shows other text. A fresh
    /// row rather than an edit: AppKit may build the overflow menu from a
    /// copy of the row.
    private func updateTitleForm(_ item: NSToolbarItem, _ title: String?) {
        if let shown = item.menuFormRepresentation, shown.title == Self.titleRowText(title) { return }
        item.menuFormRepresentation = Self.makeTitleForm(title)
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

    /// Brings `filterMenu`, the filter button and the filter item's overflow
    /// row to `filter`. The menu's rows are rebuilt only when the options
    /// change; the repo check and the Show Hidden Repos row's title and check
    /// are set in place, each only when it differs. The menu and the row are
    /// built from the same presentation, so their rows match. Never while
    /// one of the filter's menus is open: its close schedules an apply that
    /// catches up. An item whose view is not the filter's host, or a host
    /// missing its button, is logged and its button skipped.
    private func updateFilter(_ item: NSToolbarItem, _ filter: RepoFilterPresentation) {
        guard !filterMenuTracker.isOpen else { return }
        if filter.options != builtFilterOptions {
            fillFilterRows(filterMenu, for: filter)
            builtFilterOptions = filter.options
        }
        if Self.checkFilterRow(in: filterMenu, for: filter) {
            filterSelectionCount += 1
            itemsLogger.debug("Main toolbar filter selection \(self.filterSelectionCount, privacy: .public)")
        }
        Self.updateShowHiddenReposRow(in: filterMenu, for: filter)
        if let button = (item.view as? FilterToolbarButtonHost)?.button {
            Self.showFilter(filter, on: button)
        } else {
            let kind = item.view.map { String(describing: type(of: $0)) } ?? "no view"
            itemsLogger.error("Main toolbar's filter item holds \(kind, privacy: .public), not its button; skipped")
        }
        updateFilterForm(item, filter)
    }

    /// Gives the filter item a fresh overflow row for `filter` when its row
    /// was built for other options, another choice, another hidden count or
    /// toggle state, or for none. A fresh row rather than an edit: AppKit may
    /// build the overflow menu from a copy of the row.
    private func updateFilterForm(_ item: NSToolbarItem, _ filter: RepoFilterPresentation) {
        let shown = item.menuFormRepresentation?.representedObject as? RepoFilterPresentation
        guard shown != filter else { return }
        item.menuFormRepresentation = makeFilterForm(filter)
    }

    /// Replaces `menu`'s rows with "All Repos", a separator, then each repo,
    /// each row carrying its repo's ID, or none for "All Repos", and choosing
    /// it through `filterChosen(_:)`; then a separator and the Show Hidden
    /// Repos row, titled and checked for `filter`, which flips the toggle
    /// through `showHiddenReposChosen(_:)`. Hidden repos keep their rows,
    /// with no marker: choosing one shows its section, dimmed. Rows are added
    /// to the menu directly: `addItem(withTitle:)` drops a row whose title
    /// repeats, and two repos can share a display name.
    private func fillFilterRows(_ menu: NSMenu, for filter: RepoFilterPresentation) {
        menu.removeAllItems()
        for (index, option) in filter.options.enumerated() {
            let row = NSMenuItem(title: option.title, action: #selector(filterChosen(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = option.id
            menu.addItem(row)
            if index == 0 { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(
            title: filter.showHiddenReposRowTitle, action: #selector(showHiddenReposChosen(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = filter.showsHiddenRepos ? .on : .off
        menu.addItem(toggle)
    }

    /// Checks the repo row `filter` names and no other, or none when it names
    /// a repo that is gone, as the SwiftUI `Picker` shows it, rather than a
    /// false "All Repos". Only the rows choosing a repo are touched, so the
    /// Show Hidden Repos row keeps its own check, and only a row whose check
    /// differs is set, so a menu already showing the filter is left alone.
    ///
    /// - Returns: whether any row's check changed.
    @discardableResult
    private static func checkFilterRow(in menu: NSMenu, for filter: RepoFilterPresentation) -> Bool {
        let target = filterRow(in: menu.items, for: filter)
        var changed = false
        for (index, row) in menu.items.enumerated() where isRepoRow(row) {
            let state: NSControl.StateValue = index == target ? .on : .off
            if row.state != state {
                row.state = state
                changed = true
            }
        }
        return changed
    }

    /// The index among `rows` of the repo row `filter` names, or `nil` when
    /// it names a repo that is gone.
    private static func filterRow(in rows: [NSMenuItem], for filter: RepoFilterPresentation) -> Int? {
        guard filter.selectedIsKnown else { return nil }
        return rows.firstIndex { row in
            isRepoRow(row) && (row.representedObject as? UUID) == filter.selected
        }
    }

    /// Whether `row` is one of a filter menu's rows that choose a repo, "All
    /// Repos" among them.
    private static func isRepoRow(_ row: NSMenuItem) -> Bool {
        !row.isSeparatorItem && row.action == #selector(MainToolbarController.filterChosen(_:))
    }

    /// Sets the Show Hidden Repos row of `menu` to `filter`'s title and
    /// check, each only when it differs. The title changes with the hidden
    /// repos' count, which is not one of the options, so the row is set in
    /// place rather than the menu rebuilt.
    private static func updateShowHiddenReposRow(in menu: NSMenu, for filter: RepoFilterPresentation) {
        let action = #selector(MainToolbarController.showHiddenReposChosen(_:))
        guard let row = menu.items.first(where: { $0.action == action }) else { return }
        let title = filter.showHiddenReposRowTitle
        if row.title != title {
            row.title = title
        }
        let state: NSControl.StateValue = filter.showsHiddenRepos ? .on : .off
        if row.state != state {
            row.state = state
        }
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
    /// touching the image `ServersButtonLabel.bakedIcon` caches.
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

    /// Pops `filterMenu` up under the filter button that sent it, its top
    /// leading corner `filterMenuGap` below the button's bottom leading
    /// corner (`filterMenuOrigin(in:flipped:rightToLeft:)`). The menu is
    /// kept in step by each apply, so it opens as it is. Returns once the
    /// menu closes, then reads the pointer again for the button's hover
    /// square. A sender that is not a button opens nothing.
    @objc func filterButtonClicked(_ sender: Any?) {
        guard let button = sender as? NSButton else { return }
        let origin = Self.filterMenuOrigin(
            in: button.bounds, flipped: button.isFlipped,
            rightToLeft: button.userInterfaceLayoutDirection == .rightToLeft)
        filterMenu.popUp(positioning: nil, at: origin, in: button)
        (button as? ToolbarIconButton)?.refreshHover()
    }

    /// Sets the filter to the row chosen, from `filterMenu` or the overflow
    /// row's submenu. Its repo ID, or none for "All Repos", is the row's
    /// represented object. A hidden repo chosen here shows, whatever the Show
    /// Hidden Repos toggle says (`AppState.sidebarShownRepos(showHiddenRepos:)`).
    /// A sender that is not a menu item changes nothing.
    @objc func filterChosen(_ sender: Any?) {
        guard let row = sender as? NSMenuItem else { return }
        let chosen = row.representedObject as? UUID
        guard appState.repoFilter != chosen else { return }
        appState.repoFilter = chosen
    }

    /// Flips whether hidden repos' sections show, from the Show Hidden Repos
    /// row of `filterMenu` or of the overflow row's submenu. It writes
    /// `SidebarBuildOptions.showHiddenReposKey` to `appState.userDefaults`,
    /// the store the sidebar's outline reads and re-filters from; the
    /// controller's watch on that store then checks the row. It reads nothing
    /// from its sender, so any sender flips it.
    @objc func showHiddenReposChosen(_ sender: Any?) {
        let defaults = appState.userDefaults
        let shown = SidebarBuildOptions.storedShowHiddenRepos(defaults)
        defaults.set(!shown, forKey: SidebarBuildOptions.showHiddenReposKey)
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
