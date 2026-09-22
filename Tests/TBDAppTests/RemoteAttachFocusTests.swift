import AppKit
import Foundation
import Testing

@testable import TBDApp
import TestSupport

/// Keyboard focus for a remote-session `attach` pane.
///
/// **What makes this worth a suite of its own:** the pane claims first
/// responder once, when its child spawns — and `RemoteAttachPager` keeps panes
/// alive across selection changes, so a revisited session never spawns again.
/// Without a claim on the selection path the user comes back to a hollow
/// cursor and has to press Tab before typing reaches the session.
///
/// The view is mounted in a real — but offscreen, never key — `NSWindow` for
/// the reason `HolderPanelFocusTests` gives: `window.firstResponder` is the
/// only honest observable, and `makeFirstResponder` does not depend on key
/// status. The pane is registered the way `RemoteAttachPager.makeTerminalView`
/// registers it; no provider child is spawned, since the claim under test is
/// the selection's, not the spawn's.
///
/// Tier 2: a real `TBDTerminalView` in a real window. The suite limit is a
/// hang guard only, and takes the shared dial.
@Suite("A remote attach pane takes keyboard focus when it is selected", .fastPassBounded)
struct RemoteAttachFocusTests {

    private static let selected = RemoteSessionSelection(provider: "acme", sessionID: "s-1")
    private static let other = RemoteSessionSelection(provider: "acme", sessionID: "s-2")

    /// Something else in the window that can hold first responder, standing
    /// in for the sidebar a click moves focus to.
    private final class FocusSink: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @MainActor
    private final class Fixture {
        let state: AppState
        let view: TBDTerminalView
        let sink = FocusSink(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let window: NSWindow
        let ground: NSView
        private let defaults: UserDefaults
        private let suiteName: String

        /// - Parameter mounted: whether the pane starts in the window. A
        ///   pane the pager is not showing is out of it (the pager is an
        ///   `NSTabViewController`), so `false` is a hidden kept-alive pane.
        init(mounted: Bool) {
            _ = NSApplication.shared
            suiteName = "TBDAppTests.RemoteAttachFocus.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            state = AppState(userDefaults: defaults)

            view = TBDTerminalView(
                frame: CGRect(x: 0, y: 0, width: 600, height: 300),
                font: TBDTerminalView.defaultMonospaceFont,
                appearance: AppearanceSettings(defaults: defaults))

            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            ground = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            ground.addSubview(sink)
            if mounted { ground.addSubview(view) }
            window.contentView = ground

            state.registerRemoteTerminalView(view, for: RemoteAttachFocusTests.selected)
        }

        func select(_ selection: RemoteSessionSelection) {
            state.selectRemoteSession(provider: selection.provider, sessionID: selection.sessionID)
        }

        /// Moves focus off the pane, as a sidebar click does.
        func focusElsewhere() {
            window.makeFirstResponder(sink)
            #expect(window.firstResponder === sink)
        }

        /// The claim lands on a later main-queue turn, so it is waited for.
        func waitForFirstResponder() async throws {
            try await waitFor(
                "the remote attach pane to become its window's first responder",
                observed: { await MainActor.run { String(describing: self.window.firstResponder) } }
            ) {
                await MainActor.run { self.window.firstResponder === self.view }
            }
        }

        func tearDown() {
            state.unregisterRemoteTerminalView(view, for: RemoteAttachFocusTests.selected)
            window.contentView = nil
            window.close()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// One main-queue turn. Every claim is enqueued with `DispatchQueue.main.async`
    /// before this is, and the queue is serial and FIFO, so a claim that was
    /// going to happen has happened by the time this returns.
    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    @Test("selecting a kept-alive pane again hands it first responder")
    func reselectingAKeptAlivePaneClaimsFocus() async throws {
        let fixture = Fixture(mounted: true)
        defer { fixture.tearDown() }

        fixture.select(Self.selected)
        try await fixture.waitForFirstResponder()

        fixture.focusElsewhere()
        fixture.select(Self.other)
        await drainMainQueue()
        #expect(fixture.window.firstResponder === fixture.sink, """
            selecting a different session pulled focus to this one's pane
            """)

        fixture.select(Self.selected)
        try await fixture.waitForFirstResponder()

        #expect(fixture.window.firstResponder === fixture.view, """
            returning to a kept-alive remote pane left focus where it was: the pane only claims \
            first responder when its attach child spawns, which a revisit never does again
            """)
    }

    @MainActor
    @Test("a selected pane claims focus when the pager puts it back in the window")
    func aSelectedPaneClaimsFocusWhenShown() async throws {
        let fixture = Fixture(mounted: false)
        defer { fixture.tearDown() }

        fixture.focusElsewhere()
        fixture.select(Self.selected)
        await drainMainQueue()
        #expect(fixture.window.firstResponder === fixture.sink)

        fixture.ground.addSubview(fixture.view)
        try await fixture.waitForFirstResponder()
    }

    @MainActor
    @Test("a pane that is not the selected session never takes focus")
    func anUnselectedPaneLeavesFocusAlone() async throws {
        let fixture = Fixture(mounted: false)
        defer { fixture.tearDown() }

        fixture.focusElsewhere()
        fixture.select(Self.other)
        fixture.ground.addSubview(fixture.view)
        await drainMainQueue()
        await drainMainQueue()

        #expect(fixture.window.firstResponder === fixture.sink, """
            a pane for a session the user did not select took first responder
            """)
    }
}
