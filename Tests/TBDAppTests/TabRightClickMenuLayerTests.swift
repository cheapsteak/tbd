import AppKit
import Foundation
import Testing
@testable import TBDApp

/// The clear layer over a workspace tab takes only the clicks that open the
/// tab's menu. Every other event must reach the tab below it, or dragging,
/// double-click rename and the close button stop working.
@MainActor
@Suite("TabRightClickMenuLayer — which events it takes")
struct TabRightClickMenuLayerTests {
    private let point = NSPoint(x: 10, y: 10)

    private func makeView() -> TabRightClickMenuView {
        TabRightClickMenuView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    }

    /// A mouse event of `type` for no window.
    private func mouseEvent(
        _ type: NSEvent.EventType, modifierFlags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifierFlags, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func rightClickOpensMenu() throws {
        let view = makeView()
        let event = try mouseEvent(.rightMouseDown)
        #expect(TabRightClickMenuView.opensMenu(for: event))
        let hit = view.hitTest(point, event: event)
        #expect(hit === view)
    }

    @Test func controlClickOpensMenu() throws {
        let view = makeView()
        let event = try mouseEvent(.leftMouseDown, modifierFlags: .control)
        #expect(TabRightClickMenuView.opensMenu(for: event))
        let hit = view.hitTest(point, event: event)
        #expect(hit === view)
    }

    @Test func plainLeftClickPassesThrough() throws {
        let view = makeView()
        let events: [NSEvent?] = try [
            mouseEvent(.leftMouseDown),
            mouseEvent(.leftMouseDragged),
            nil,
        ]
        for event in events {
            let label = String(describing: event?.type)
            #expect(TabRightClickMenuView.opensMenu(for: event) == false, "\(label)")
            let hit = view.hitTest(point, event: event)
            #expect(hit == nil, "\(label)")
        }
    }

    /// While the tab is renamed the layer is disabled, so a right-click or a
    /// Control-click reaches the rename field's own menu.
    @Test func disabledLayerTakesNoEvent() throws {
        let view = makeView()
        let events = try [
            mouseEvent(.rightMouseDown),
            mouseEvent(.leftMouseDown, modifierFlags: .control),
        ]
        view.isEnabled = false
        for event in events {
            let hit = view.hitTest(point, event: event)
            #expect(hit == nil, "\(event.type)")
        }
        view.isEnabled = true
        for event in events {
            let hit = view.hitTest(point, event: event)
            #expect(hit === view, "\(event.type)")
        }
    }
}
