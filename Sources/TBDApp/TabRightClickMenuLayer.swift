import AppKit
import SwiftUI

/// A clear AppKit layer over a workspace tab that opens its right-click menu
/// (`TabContextMenu`), which AppKit builds so the account rows can draw usage
/// bars (`docs/specs/2026-11-23-usage-bars-in-account-menus-design.md`).
///
/// The layer takes only a right-click or a Control-click. Every other event
/// passes through to the tab below, so dragging, double-click rename, hover,
/// the close button and the hover card work as before.
struct TabRightClickMenuLayer: NSViewRepresentable {
    /// Builds the menu at the click, so it shows the tab as it is then. nil
    /// shows no menu.
    let makeMenu: @MainActor () -> NSMenu?

    func makeNSView(context: Context) -> TabRightClickMenuView {
        let view = TabRightClickMenuView(frame: .zero)
        view.makeMenu = makeMenu
        return view
    }

    func updateNSView(_ view: TabRightClickMenuView, context: Context) {
        view.makeMenu = makeMenu
    }
}

/// The view behind `TabRightClickMenuLayer`.
final class TabRightClickMenuView: NSView {
    var makeMenu: @MainActor () -> NSMenu? = { nil }

    /// Whether `event` opens the menu: a right mouse down, or a left mouse
    /// down with Control held.
    static func opensMenu(for event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .rightMouseDown:
            return true
        case .leftMouseDown:
            return event.modifierFlags.contains(.control)
        default:
            return false
        }
    }

    /// The hit test for `event`: this view for an event that opens the menu,
    /// nil for any other, so it reaches the tab below.
    func hitTest(_ point: NSPoint, event: NSEvent?) -> NSView? {
        guard Self.opensMenu(for: event) else { return nil }
        return super.hitTest(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTest(point, event: NSApplication.shared.currentEvent)
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        showMenu(with: event)
    }

    private func showMenu(with event: NSEvent) {
        guard let menu = makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
