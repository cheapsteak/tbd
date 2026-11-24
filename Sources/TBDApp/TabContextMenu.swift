import AppKit
import TBDShared

/// A workspace tab's right-click menu, built in AppKit because a SwiftUI
/// `.contextMenu` item has no place after its title for the usage bars the
/// Swap profile and Fork Session rows draw
/// (`docs/specs/2026-11-23-usage-bars-in-account-menus-design.md`).
///
/// `build` reads only its `Model`. The tab fills the model from the helpers
/// that decide each item (`TabPinMenu`, `SwapProfileMenu`, `TabParkMenuModel`
/// and the rest) and maps each `Action` back to an `AppState` call, so those
/// rules stay in one place and the menu's shape is testable without showing it.
enum TabContextMenu {
    /// What one click asks the tab to do.
    enum Action: Equatable {
        case copyPath(String)
        case revealInFinder(String)
        case openWith(path: String, app: URL)
        case copyLink
        case copySessionID(String)
        case setPinned(Bool)
        case moveToHolder
        /// nil is the default login.
        case swapProfile(UUID?)
        /// nil is the default login.
        case forkSession(UUID?)
        case continueInCodex
        case hibernate
        case wake
        case cancelScheduledResume
        case rename
        case close
    }

    /// A model profile as the Swap profile and Fork Session submenus list it.
    struct Account: Equatable {
        let profileID: UUID
        let name: String
        let usage: ProfileUsagePresentation.MenuUsage
    }

    /// What the menu shows for one tab. Every field defaults to absent, so a
    /// tab, or a test, names only what it has.
    struct Model {
        var fileTarget: HeaderMenuTarget?
        var openWithApps: [OpenWithApp] = []
        var sessionID: String?
        var pinTitle: String?
        var isPinned: Bool = false
        var offersMoveToHolder: Bool = false
        var isClaude: Bool = false
        var profileHeader: String = ""
        var offersInPlaceSwap: Bool = false
        /// nil is the default login.
        var currentProfileID: UUID?
        var accounts: [Account] = []
        /// The warning that ends Swap profile while the session is running.
        var busyCaption: String?
        var showsContinueInCodex: Bool = false
        var parkAction: TabParkMenuModel.ParkAction?
        var hasScheduledResume: Bool = false
        var isRenameable: Bool = false
    }

    static let defaultAccountTitle = "Default (logged in)"

    /// The key the menu holds its target under. `NSMenuItem.target` is weak,
    /// so without the menu's reference the target dies when `build` returns.
    /// A static string's bytes never move, so every read finds the same key.
    static let targetKey: StaticString = "TabContextMenu.target"

    @MainActor
    static func build(model: Model, perform: @escaping @MainActor (Action) -> Void) -> NSMenu {
        let target = TabContextMenuTarget(perform: perform)
        let menu = makeMenu()

        if let file = model.fileTarget {
            menu.addItem(item(file.copyLabel, action: .copyPath(file.path), target: target))
            menu.addItem(item("Reveal in Finder", action: .revealInFinder(file.path), target: target))
            if !model.openWithApps.isEmpty {
                var apps: [NSMenuItem] = []
                for app in model.openWithApps {
                    let appItem = item(
                        app.displayName,
                        action: .openWith(path: file.path, app: app.url),
                        target: target)
                    let icon = NSWorkspace.shared.icon(forFile: app.url.path)
                    icon.size = NSSize(width: 16, height: 16)
                    appItem.image = icon
                    apps.append(appItem)
                }
                menu.addItem(parent("Open With", items: apps))
            }
        }

        menu.addItem(item("Copy Link", action: .copyLink, target: target))
        if let sessionID = model.sessionID {
            menu.addItem(item(CopyClaudeSessionIDMenu.title, action: .copySessionID(sessionID), target: target))
        }
        menu.addItem(.separator())

        if let pinTitle = model.pinTitle {
            menu.addItem(item(
                pinTitle,
                symbol: model.isPinned ? "pin.slash" : "pin",
                action: .setPinned(!model.isPinned),
                target: target))
            menu.addItem(.separator())
        }

        // Shells move too, so this sits outside the Claude-only block.
        if model.offersMoveToHolder {
            menu.addItem(item(
                TransportMigrationVocabulary.menuTitle,
                symbol: "arrow.right.square",
                action: .moveToHolder,
                target: target))
            menu.addItem(.separator())
        }

        if model.isClaude {
            let header = NSMenuItem(title: model.profileHeader, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            if model.offersInPlaceSwap {
                menu.addItem(parent(
                    "Swap profile",
                    items: accountItems(
                        model, action: Action.swapProfile, caption: model.busyCaption, target: target)))
            }
            menu.addItem(.separator())

            // A fork leaves the running session alone, so it never warns.
            menu.addItem(parent(
                "Fork Session",
                symbol: "arrow.triangle.branch",
                items: accountItems(model, action: Action.forkSession, caption: nil, target: target)))

            if model.showsContinueInCodex {
                menu.addItem(item(
                    "Continue in Codex", symbol: "arrow.right.circle", action: .continueInCodex, target: target))
            }
            switch model.parkAction {
            case .hibernate:
                menu.addItem(item("Hibernate", symbol: "moon", action: .hibernate, target: target))
            case .wake:
                menu.addItem(item("Wake", symbol: "sun.max", action: .wake, target: target))
            case nil:
                break
            }
            if model.hasScheduledResume {
                menu.addItem(item(
                    "Cancel Scheduled Resume",
                    symbol: "clock.badge.xmark",
                    action: .cancelScheduledResume,
                    target: target))
            }
            menu.addItem(.separator())
        }

        if model.isRenameable {
            menu.addItem(item("Rename Tab", action: .rename, target: target))
            menu.addItem(.separator())
        }

        menu.addItem(item("Close Tab", symbol: "xmark", action: .close, target: target))

        objc_setAssociatedObject(menu, targetKey.utf8Start, target, .OBJC_ASSOCIATION_RETAIN)
        return menu
    }

    /// The rows Swap profile and Fork Session share: the default login, then
    /// each profile with its usage. One name column width serves every row,
    /// so the bars line up down the submenu.
    @MainActor
    private static func accountItems(
        _ model: Model,
        action: (UUID?) -> Action,
        caption: String?,
        target: TabContextMenuTarget
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let defaultItem = item(defaultAccountTitle, action: action(nil), target: target)
        defaultItem.state = model.currentProfileID == nil ? .on : .off
        items.append(defaultItem)
        items.append(.separator())

        let rows: [(name: String, usage: ProfileUsagePresentation.MenuUsage)] =
            model.accounts.map { (name: $0.name, usage: $0.usage) }
        let nameColumnWidth = AccountMenuRow.nameColumnWidth(rows)
        for account in model.accounts {
            let row = item(account.name, action: action(account.profileID), target: target)
            AccountMenuRow.apply(
                to: row, name: account.name, usage: account.usage, nameColumnWidth: nameColumnWidth)
            row.state = account.profileID == model.currentProfileID ? .on : .off
            items.append(row)
        }

        if let caption {
            items.append(.separator())
            let captionItem = NSMenuItem(title: caption, action: nil, keyEquivalent: "")
            captionItem.isEnabled = false
            items.append(captionItem)
        }
        return items
    }

    @MainActor
    private static func item(
        _ title: String,
        symbol: String? = nil,
        action: Action,
        target: TabContextMenuTarget
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title, action: #selector(TabContextMenuTarget.fire(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = TabContextMenuActionBox(action)
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    @MainActor
    private static func parent(_ title: String, symbol: String? = nil, items: [NSMenuItem]) -> NSMenuItem {
        let submenu = makeMenu(title: title)
        for item in items {
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol {
            parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        parent.submenu = submenu
        return parent
    }

    /// Enabled state is set item by item, so AppKit must not recompute it from
    /// each item's target and action.
    private static func makeMenu(title: String = "") -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        return menu
    }
}

/// Receives every click in a `TabContextMenu` and hands its action to the tab.
@MainActor
final class TabContextMenuTarget: NSObject {
    private let perform: @MainActor (TabContextMenu.Action) -> Void

    init(perform: @escaping @MainActor (TabContextMenu.Action) -> Void) {
        self.perform = perform
        super.init()
    }

    @objc func fire(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? TabContextMenuActionBox else { return }
        perform(box.action)
    }
}

/// An `Action` in the object form `NSMenuItem.representedObject` holds.
final class TabContextMenuActionBox: NSObject {
    let action: TabContextMenu.Action

    init(_ action: TabContextMenu.Action) {
        self.action = action
        super.init()
    }
}
