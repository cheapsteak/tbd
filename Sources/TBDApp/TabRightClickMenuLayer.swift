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
    /// Where VoiceOver's Show Menu opens the menu: this layer's view.
    let anchor: TabMenuAnchor
    /// False while the tab is being renamed, so every click, a right-click
    /// included, reaches the rename field.
    let isEnabled: Bool
    /// Builds the menu at the click, so it shows the tab as it is then. nil
    /// shows no menu.
    let makeMenu: @MainActor () -> NSMenu?

    func makeNSView(context: Context) -> TabRightClickMenuView {
        let view = TabRightClickMenuView(frame: .zero)
        view.isEnabled = isEnabled
        view.makeMenu = makeMenu
        anchor.view = view
        return view
    }

    func updateNSView(_ view: TabRightClickMenuView, context: Context) {
        view.isEnabled = isEnabled
        view.makeMenu = makeMenu
        anchor.view = view
    }
}

/// Opens the tab's menu at the tab rather than at the pointer, for
/// VoiceOver's Show Menu action. The tab's right-click layer sets `view`.
@MainActor
final class TabMenuAnchor {
    /// Weak, so the anchor never keeps the layer's view alive.
    weak var view: NSView?

    /// Pops `menu` at the bottom-left of `view`. Does nothing without a view.
    func show(_ menu: NSMenu) {
        guard let view else { return }
        let origin = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY : 0)
        menu.popUp(positioning: nil, at: origin, in: view)
    }
}

/// The view behind `TabRightClickMenuLayer`.
final class TabRightClickMenuView: NSView {
    /// When false, the view takes no event at all.
    var isEnabled = true
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
    /// nil for any other, or for every event while disabled, so it reaches
    /// the tab below. It claims only the point the event is at, in this
    /// view's window: after a menu closes, the right-click stays the current
    /// event while AppKit hit-tests other points for cursor and tooltip
    /// updates.
    func hitTest(_ point: NSPoint, event: NSEvent?) -> NSView? {
        guard isEnabled, let event, Self.opensMenu(for: event),
              let window, event.window === window,
              let location = superview?.convert(event.locationInWindow, from: nil),
              abs(location.x - point.x) <= 1, abs(location.y - point.y) <= 1
        else { return nil }
        return super.hitTest(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTest(point, event: NSApplication.shared.currentEvent)
    }

    /// A Control-click in an inactive window opens the menu at once, rather
    /// than only bringing the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        Self.opensMenu(for: event)
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
