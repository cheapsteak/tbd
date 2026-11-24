import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// The clear layer over a workspace tab takes only the clicks that open the
/// tab's menu. Every other event must reach the tab below it, or dragging,
/// double-click rename and the close button stop working.
@MainActor
@Suite("TabRightClickMenuLayer — which events it takes")
struct TabRightClickMenuLayerTests {
    /// A point inside the layer, in its superview's coordinates, which is
    /// where `hitTest(_:)` takes its point from.
    private let point = NSPoint(x: 10, y: 10)

    /// The layer in a window of its own: borderless, far off every display
    /// and never key, so the layer and its events have a window. The layer's
    /// superview sits away from the window's origin, so a point in the
    /// superview is not the same point in the window.
    @MainActor
    private final class Fixture {
        let window: NSWindow
        let ground: NSView
        let view: TabRightClickMenuView

        init() {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 80),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
            let ground = NSView(frame: NSRect(x: 30, y: 8, width: 150, height: 50))
            let view = TabRightClickMenuView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            ground.addSubview(view)
            root.addSubview(ground)
            window.contentView = root
            window.orderFrontRegardless()
            self.window = window
            self.ground = ground
            self.view = view
        }

        /// A mouse event at `point`, a point in the layer's superview, for
        /// the window numbered `windowNumber`, the fixture's own by default.
        func event(
            _ type: NSEvent.EventType, at point: NSPoint,
            modifierFlags: NSEvent.ModifierFlags = [], windowNumber: Int? = nil
        ) throws -> NSEvent {
            let location = ground.convert(point, to: nil)
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: modifierFlags, timestamp: 0,
                windowNumber: windowNumber ?? window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            if windowNumber == nil {
                try #require(event.window === window,
                             "The event does not resolve to the window it names")
            }
            return event
        }

        func tearDown() {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }

    @Test func rightClickOpensMenu() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let event = try fixture.event(.rightMouseDown, at: point)
        #expect(TabRightClickMenuView.opensMenu(for: event))
        let hit = fixture.view.hitTest(point, event: event)
        #expect(hit === fixture.view)
    }

    @Test func controlClickOpensMenu() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let event = try fixture.event(.leftMouseDown, at: point, modifierFlags: .control)
        #expect(TabRightClickMenuView.opensMenu(for: event))
        let hit = fixture.view.hitTest(point, event: event)
        #expect(hit === fixture.view)
    }

    /// After a menu closes, the right-click stays `NSApp.currentEvent` until
    /// the next event, while AppKit hit-tests other points over the tab for
    /// cursor and tooltip updates. Only the event's own point is claimed.
    @Test func rightClickClaimsOnlyItsOwnPoint() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let event = try fixture.event(.rightMouseDown, at: point)
        let elsewhere = NSPoint(x: 60, y: 20)
        // Inside the layer, so only the event's point can turn it away.
        #expect(fixture.view.frame.contains(elsewhere))
        let hitElsewhere = fixture.view.hitTest(elsewhere, event: event)
        #expect(hitElsewhere == nil)

        let atElsewhere = try fixture.event(.rightMouseDown, at: elsewhere)
        let hitAtItsPoint = fixture.view.hitTest(elsewhere, event: atElsewhere)
        #expect(hitAtItsPoint === fixture.view)

        // Within a point, for rounding between coordinate spaces.
        let nearby = NSPoint(x: point.x + 0.5, y: point.y - 0.5)
        let hitNearby = fixture.view.hitTest(nearby, event: event)
        #expect(hitNearby === fixture.view)
    }

    /// A right-click in another window, or in none, is never this layer's,
    /// even at the same point.
    @Test func rightClickFromAnotherWindowIsNotClaimed() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let other = Fixture()
        defer { other.tearDown() }

        let inOther = try other.event(.rightMouseDown, at: point)
        let hitFromOther = fixture.view.hitTest(point, event: inOther)
        #expect(hitFromOther == nil)

        let windowless = try fixture.event(.rightMouseDown, at: point, windowNumber: 0)
        #expect(windowless.window == nil)
        let hitWindowless = fixture.view.hitTest(point, event: windowless)
        #expect(hitWindowless == nil)
    }

    @Test func plainLeftClickPassesThrough() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let events: [NSEvent?] = try [
            fixture.event(.leftMouseDown, at: point),
            fixture.event(.leftMouseDragged, at: point),
            nil,
        ]
        for event in events {
            let label = String(describing: event?.type)
            #expect(TabRightClickMenuView.opensMenu(for: event) == false, "\(label)")
            let hit = fixture.view.hitTest(point, event: event)
            #expect(hit == nil, "\(label)")
        }
    }

    /// A click that opens the menu does so in an inactive window too; any
    /// other click only brings the window forward.
    @Test func acceptsFirstMouseOnlyForMenuClicks() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let view = fixture.view
        let rightClick = try fixture.event(.rightMouseDown, at: point)
        let controlClick = try fixture.event(.leftMouseDown, at: point, modifierFlags: .control)
        let plainClick = try fixture.event(.leftMouseDown, at: point)
        #expect(view.acceptsFirstMouse(for: rightClick))
        #expect(view.acceptsFirstMouse(for: controlClick))
        #expect(view.acceptsFirstMouse(for: plainClick) == false)
        #expect(view.acceptsFirstMouse(for: nil) == false)
    }

    /// While the tab is renamed the layer is disabled, so a right-click or a
    /// Control-click reaches the rename field's own menu.
    @Test func disabledLayerTakesNoEvent() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let view = fixture.view
        let events = try [
            fixture.event(.rightMouseDown, at: point),
            fixture.event(.leftMouseDown, at: point, modifierFlags: .control),
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

/// VoiceOver's Show Menu opens the tab's menu through `TabMenuAnchor`.
@MainActor
@Suite("TabMenuAnchor")
struct TabMenuAnchorTests {
    /// Before the layer has set a view there is nowhere to open the menu.
    @Test func showWithoutAViewDoesNothing() {
        let anchor = TabMenuAnchor()
        let menu = NSMenu(title: "")
        menu.addItem(NSMenuItem(title: "Close Tab", action: nil, keyEquivalent: ""))
        anchor.show(menu)
        #expect(anchor.view == nil)
    }

    /// The anchor holds the layer's view weakly, so the view goes when the
    /// tab does.
    @Test func anchorDoesNotKeepItsViewAlive() {
        let anchor = TabMenuAnchor()
        weak var released: TabRightClickMenuView?
        autoreleasepool {
            let view = TabRightClickMenuView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            anchor.view = view
            released = view
            let held = anchor.view === view
            #expect(held)
        }
        #expect(released == nil)
        #expect(anchor.view == nil)
    }
}

/// Pass-through also depends on the view SwiftUI wraps the layer in: its hit
/// test must not take the click either. With no mouse event in progress,
/// `NSApp.currentEvent` is not a right-click, so the layer returns nil and
/// the hit shows what the host does.
@MainActor
@Suite("TabRightClickMenuLayer — hosted in a tab bar")
struct TabRightClickMenuLayerHostedTests {
    @Test func plainClickPassesThroughTheLayerAndItsHost() async throws {
        try await withTestDefaults("TabRightClickMenuLayer.Hosted") { defaults in
            let worktreeID = UUID()
            let tabID = UUID()
            let tab = TBDShared.Tab(id: tabID, content: .terminal(terminalID: tabID), label: "A")
            let appState = AppState(userDefaults: defaults)
            let host = OffscreenHost(
                root: TabBar(
                    tabs: [tab],
                    worktreeID: worktreeID,
                    activeTabIndex: .constant(0),
                    onCloseTab: { _ in }
                )
                .environment(appState),
                size: NSSize(width: 480, height: 52))
            defer { host.tearDown() }

            let laidOut = await host.settle {
                let width = host.firstDescendant(TabRightClickMenuView.self)?.bounds.width ?? 0
                return width > 0
            }
            try #require(laidOut, "The tab's right-click layer was never laid out")
            let found = host.firstDescendant(TabRightClickMenuView.self)
            let layer = try #require(found)
            let wrapper = layer.superview

            let middle = NSPoint(x: layer.bounds.midX, y: layer.bounds.midY)
            let point = layer.convert(middle, to: host.contentView.superview)
            let hit = host.contentView.hitTest(point)
            let hitName = String(describing: hit.map { type(of: $0) })

            #expect(hit !== layer, "The layer took a plain click")
            // A layer placed straight in the hosting view has no wrapper of
            // its own; the hosting view taking the click is then SwiftUI's
            // own dispatch.
            if let wrapper, wrapper !== host.hostingView {
                #expect(hit !== wrapper, "SwiftUI's host for the layer took a plain click: \(hitName)")
            }
            let reachesTabBar = hit?.isDescendant(of: host.hostingView) ?? false
            #expect(reachesTabBar, "The click reached \(hitName), outside the tab bar")
        }
    }
}
