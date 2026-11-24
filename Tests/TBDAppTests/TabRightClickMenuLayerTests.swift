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
