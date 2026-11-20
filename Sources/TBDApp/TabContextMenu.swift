import AppKit
import SwiftUI
import TBDShared
import os

private let tabMenuLogger = Logger(subsystem: "com.tbd.app", category: "tab-context-menu")

// MARK: - SwapProfileMenu.Item

extension SwapProfileMenu {
    /// One row of a swap-profile submenu, as plain values: what the SwiftUI
    /// lowering (`TabBarItem.swapProfileMenuItems`) and the AppKit menu below
    /// both draw. `profileID` nil is "Default (logged in)".
    enum Item: Equatable {
        case profile(id: UUID?, title: String, isCurrent: Bool)
        case separator
        case caption(String)
    }

    /// The rows of the swap-profile submenu: "Default (logged in)", a
    /// separator, one row per account with its usage beside the name, and the
    /// busy-session caption when it applies. The current account carries `isCurrent`.
    static func items(
        profiles: [ModelProfileWithUsage],
        currentProfileID: UUID?,
        mode: TerminalSwapMode,
        activityState: TerminalActivityState?
    ) -> [Item] {
        var items: [Item] = [
            .profile(id: nil, title: "Default (logged in)", isCurrent: currentProfileID == nil),
            .separator,
        ]
        for entry in profiles {
            items.append(.profile(
                id: entry.profile.id,
                title: menuLabel(for: entry.profile, usage: entry.usageSnapshot),
                isCurrent: currentProfileID == entry.profile.id))
        }
        if let caption = busyCaption(mode: mode, activityState: activityState) {
            items.append(.separator)
            items.append(.caption(caption))
        }
        return items
    }
}

// MARK: - TabContextMenuHitTest

/// Pure decision behind the toolbar-row right-click: which registered tab, if
/// any, a window point lands on.
enum TabContextMenuHitTest {
    /// Whether the event is one that opens a context menu: a right-click, or a
    /// control-click.
    static func opensContextMenu(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch type {
        case .rightMouseDown: return true
        case .leftMouseDown: return modifiers.contains(.control)
        default: return false
        }
    }

    /// The id of the first tab whose frame holds `point`, or nil. Frames never
    /// overlap, so order does not matter; sorting by id keeps it deterministic.
    static func tabID(at point: CGPoint, frames: [UUID: CGRect]) -> UUID? {
        frames.sorted { $0.key.uuidString < $1.key.uuidString }
            .first { $0.value.contains(point) }?.key
    }
}

// MARK: - TabContextMenuRegistry

/// The window-level right-click path for Claude tabs.
///
/// A tab's SwiftUI `.contextMenu` does not open from the toolbar row, where the
/// tabs draw: the window's toolbar takes the right-click first. A local event
/// monitor sees the click before the window dispatches it, so each Claude tab
/// registers an anchor view and the monitor pops an `NSMenu` when a click
/// lands on one, then consumes the event so nothing else answers it.
@MainActor
final class TabContextMenuRegistry {
    static let shared = TabContextMenuRegistry()

    struct Registration {
        weak var view: NSView?
        let buildMenu: () -> NSMenu?
    }

    private var registrations: [UUID: Registration] = [:]
    private var monitor: Any?

    func register(tabID: UUID, view: NSView, buildMenu: @escaping () -> NSMenu?) {
        registrations[tabID] = Registration(view: view, buildMenu: buildMenu)
        installMonitorIfNeeded()
    }

    func unregister(tabID: UUID, view: NSView) {
        // A re-created anchor may already have registered; only drop our own.
        if registrations[tabID]?.view === view { registrations[tabID] = nil }
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .leftMouseDown]
        ) { [weak self] event in
            // NSEvent is not Sendable; the monitor runs on the main thread.
            let boxed = MainThreadEvent(event: event)
            let result: MainThreadEvent? = MainActor.assumeIsolated {
                // handle returns nil when it consumed the click; a released
                // registry passes the click through.
                guard let self else { return boxed }
                return self.handle(boxed.event).map(MainThreadEvent.init(event:))
            }
            return result?.event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard TabContextMenuHitTest.opensContextMenu(type: event.type, modifiers: event.modifierFlags),
              let window = event.window else { return event }
        var frames: [UUID: CGRect] = [:]
        for (id, registration) in registrations {
            guard let view = registration.view, view.window === window else { continue }
            frames[id] = view.convert(view.bounds, to: nil)
        }
        guard let id = TabContextMenuHitTest.tabID(at: event.locationInWindow, frames: frames),
              let registration = registrations[id], let view = registration.view,
              let menu = registration.buildMenu() else { return event }
        tabMenuLogger.debug("tab menu for \(id.uuidString, privacy: .public)")
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        return nil
    }
}

/// Carries an `NSEvent` into `MainActor.assumeIsolated`. Safe because local
/// event monitors only run on the main thread.
private struct MainThreadEvent: @unchecked Sendable {
    let event: NSEvent
}

// MARK: - Anchor view

/// A transparent view behind a tab that tells the registry where the tab is.
/// It takes no clicks.
struct TabContextMenuAnchor: NSViewRepresentable {
    let tabID: UUID
    let buildMenu: () -> NSMenu?

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.tabID = tabID
        view.buildMenu = buildMenu
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.buildMenu = buildMenu
        view.register()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        TabContextMenuRegistry.shared.unregister(tabID: view.tabID, view: view)
    }

    final class AnchorView: NSView {
        var tabID = UUID()
        var buildMenu: () -> NSMenu? = { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            register()
        }

        func register() {
            guard window != nil else { return }
            let build = buildMenu
            TabContextMenuRegistry.shared.register(tabID: tabID, view: self) { build() }
        }
    }
}

// MARK: - Menu builder

/// A closure-backed menu item target. NSMenuItem holds its target weakly, so
/// the item keeps this alive through `representedObject`.
private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: NSMenuItem) { run() }
}

enum TabContextMenu {
    /// Builds the Claude tab's menu: the current profile, "Swap profile" and
    /// "Fork Session", each listing the accounts from `SwapProfileMenu.items`.
    /// `swap` runs when an account is picked.
    @MainActor
    static func build(
        header: String,
        profiles: [ModelProfileWithUsage],
        currentProfileID: UUID?,
        activityState: TerminalActivityState?,
        copyLink: @escaping () -> Void,
        swap: @escaping (_ profileID: UUID?, _ mode: TerminalSwapMode) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        add(to: menu, title: "Copy Link", action: copyLink)
        menu.addItem(.separator())

        let headerItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        for (title, mode, symbol) in [
            ("Swap profile", TerminalSwapMode.inPlace, nil),
            ("Fork Session", TerminalSwapMode.fork, "arrow.triangle.branch"),
        ] as [(String, TerminalSwapMode, String?)] {
            if mode == .fork { menu.addItem(.separator()) }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let symbol {
                parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            let submenu = NSMenu(title: title)
            submenu.autoenablesItems = false
            let rows = SwapProfileMenu.items(
                profiles: profiles, currentProfileID: currentProfileID,
                mode: mode, activityState: activityState)
            for row in rows {
                switch row {
                case .separator:
                    submenu.addItem(.separator())
                case .caption(let text):
                    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    submenu.addItem(item)
                case .profile(let id, let title, let isCurrent):
                    let item = add(to: submenu, title: title) { swap(id, mode) }
                    item.state = isCurrent ? .on : .off
                }
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
        return menu
    }

    @discardableResult
    @MainActor
    private static func add(to menu: NSMenu, title: String, action: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        menu.addItem(item)
        return item
    }
}
