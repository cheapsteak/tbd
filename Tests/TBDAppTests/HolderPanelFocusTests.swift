import AppKit
import Darwin
import Foundation
import TBDShared
import Testing

@testable import TBDApp
import TestSupport

/// Keyboard focus at the moment a holder-backed panel goes live.
///
/// **What makes this worth a suite of its own:** a panel that renders
/// perfectly is still useless if the first keystroke goes nowhere. The holder
/// transport shipped that way — its attach painted the session, claimed the
/// wheel, and then stopped, leaving the view reachable only through the key
/// view loop, so the user had to press Tab before typing reached the session.
/// The tmux path had always claimed first responder and installed its click
/// routing after its viewer started; the fix hoists both into
/// `claimKeyboardFocusAndClickRouting` and calls it from the holder path too.
///
/// The view is mounted in a real — but offscreen, never key — `NSWindow`,
/// because `window.firstResponder` is the only honest observable for the
/// claim: without a window `makeFirstResponder` is an optional-chained no-op
/// and the bug is invisible. The window being non-key costs nothing here.
/// `makeFirstResponder` does not depend on key status; *event delivery* does,
/// which is why the click half is driven through the view's click-routing
/// hooks rather than by synthesizing a click that nothing in this process
/// would dispatch.
///
/// Tier 2: a real `TBDTerminalView` in a real window, the real reader thread —
/// no daemon, no tmux, no pty. The suite limit is a hang guard only, and takes
/// the shared dial.
@Suite("A holder panel takes keyboard focus when its attach goes live", .fastPassBounded)
struct HolderPanelFocusTests {

    private static let generation: UInt64 = 7

    /// The daemon's holder RPCs, reduced to what an attach needs to succeed.
    private final class StubHolderAttach: HolderAttaching, @unchecked Sendable {
        private let attachment: HolderAttachment

        init(attachment: HolderAttachment) { self.attachment = attachment }

        func attach(
            worktreeID: UUID, paneID: String, terminalID: UUID
        ) async throws -> HolderAttachment { attachment }

        func ready(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
        ) async throws {}

        func detach(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
            snapshotPreamble: Data
        ) async throws {}
    }

    /// A coordinator wired the way `makeNSView` wires one, with its terminal
    /// view mounted in an offscreen window and one end of a `socketpair`
    /// standing in for the vended pty.
    @MainActor
    private final class Fixture {
        let state: AppState
        let coordinator: TerminalPanelRepresentable.Coordinator
        let view: TBDTerminalView
        let window: NSWindow
        let tabCloseContext: TabCloseContext
        private let sessionEnd: Int32
        let defaults: UserDefaults
        private let suiteName: String

        init() throws {
            // Enough of an application for AppKit to have an app object;
            // `NSWindow` reaches for one. Same reason `OffscreenHost` does it.
            _ = NSApplication.shared

            var pair: [Int32] = [-1, -1]
            #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            let vended = pair[0]
            sessionEnd = pair[1]
            // Close-on-exec at creation, never left to the attach: every test
            // target links into one process and sibling suites keep children
            // alive, so an inheritable descriptor here would be held open by
            // somebody else's spawn for the rest of the run. The reason is
            // spelled out at length in `HolderDetachHandbackTests.Fixture`.
            _ = fcntl(vended, F_SETFD, FD_CLOEXEC)
            _ = fcntl(sessionEnd, F_SETFD, FD_CLOEXEC)
            // The real vend is a `dup` of a pty the daemon opened `O_NONBLOCK`,
            // and the flag rides the dup; a reader that blocks would spin.
            _ = fcntl(vended, F_SETFL, fcntl(vended, F_GETFL, 0) | O_NONBLOCK)
            _ = fcntl(sessionEnd, F_SETFL, fcntl(sessionEnd, F_GETFL, 0) | O_NONBLOCK)

            let worktreeID = UUID()
            let terminalID = UUID()
            tabCloseContext = TabCloseContext(worktreeID: worktreeID, tabID: terminalID)

            suiteName = "TBDAppTests.HolderPanelFocus.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            state = AppState(userDefaults: defaults)
            state.terminals[worktreeID] = [Terminal(
                id: terminalID, worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "",
                label: "Shell", kind: .shell, transport: .holder)]

            view = TBDTerminalView(
                frame: CGRect(x: 0, y: 0, width: 600, height: 300),
                font: TBDTerminalView.defaultMonospaceFont,
                appearance: AppearanceSettings(defaults: defaults))

            // Borderless, far off every plausible display, never ordered front
            // and never made key: the window exists so the view has one, not so
            // anything is seen. A ground view under the terminal mirrors how
            // production mounts it — a subview, not the content view itself.
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let ground = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            ground.addSubview(view)
            window.contentView = ground

            coordinator = TerminalPanelRepresentable.Coordinator()
            coordinator.appState = state
            coordinator.panelID = terminalID
            coordinator.tabCloseContext = tabCloseContext
            coordinator.holderAttachClient = StubHolderAttach(
                attachment: HolderAttachment(
                    ptyFD: vended,
                    generation: HolderPanelFocusTests.generation,
                    snapshotPreamble: Data()))
            coordinator.terminalView = view
            view.terminalDelegate = coordinator
        }

        func attach() async {
            await coordinator.startHolderClient(terminalView: view)
        }

        /// The claim lands on the next main-queue turn rather than on the
        /// attach's return, so it is waited for rather than read.
        func waitForFirstResponder() async throws {
            try await waitFor(
                "the holder panel to become its window's first responder",
                observed: { await MainActor.run { String(describing: self.window.firstResponder) } }
            ) {
                await MainActor.run { self.window.firstResponder === self.view }
            }
        }

        func tearDown() {
            coordinator.cleanup()
            window.contentView = nil
            window.close()
            if sessionEnd >= 0 { Darwin.close(sessionEnd) }
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @MainActor
    @Test("a live holder attach leaves the terminal as its window's first responder")
    func theHolderPanelTakesFirstResponderOnAttach() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        #expect(fixture.window.firstResponder !== fixture.view, """
            the window handed the terminal first responder before the attach ran, so this test \
            could not tell a panel that claims focus from one that never does
            """)

        await fixture.attach()
        try await fixture.waitForFirstResponder()

        #expect(fixture.window.firstResponder === fixture.view, """
            the holder attach went live without claiming first responder: the session paints and \
            the wheel is claimed, but typing goes nowhere until the user walks the key view loop \
            with Tab
            """)
        #expect(fixture.state.focusedTabCloseContext == fixture.tabCloseContext, """
            the focused tab's close context did not follow the focus claim, so Cmd+W would close \
            some other tab
            """)
    }

    @MainActor
    @Test("a click on a live holder panel claims focus and the close context")
    func aClickClaimsFocus() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        #expect(fixture.view.onMouseDownClaimFocus == nil)

        await fixture.attach()
        try await fixture.waitForFirstResponder()

        // Move focus away by hand, so the click is what has to bring it back.
        fixture.window.makeFirstResponder(nil)
        fixture.state.focusedTabCloseContext = nil

        let claimFocus = try #require(fixture.view.onMouseDownClaimFocus, """
            the holder attach installed no click routing: a click inside the panel never claims \
            first responder, so key equivalents keep routing to whatever had it
            """)
        claimFocus()

        #expect(fixture.window.firstResponder === fixture.view)
        #expect(fixture.state.focusedTabCloseContext == fixture.tabCloseContext, """
            the click focused the terminal without naming its tab, so Cmd+W would close some \
            other tab
            """)
    }

    @MainActor
    @Test("focus leaving a holder panel clears its close context, and only its own")
    func resigningFocusClearsTheCloseContext() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        await fixture.attach()
        try await fixture.waitForFirstResponder()
        #expect(fixture.state.focusedTabCloseContext == fixture.tabCloseContext)

        fixture.window.makeFirstResponder(nil)

        #expect(fixture.window.firstResponder !== fixture.view)
        #expect(fixture.state.focusedTabCloseContext == nil, """
            focus left the terminal but its tab stayed named as the focused one, so the Close Tab \
            menu item kept offering to close it
            """)

        // A resign must not clear a context some other tab has since claimed.
        let other = TabCloseContext(worktreeID: UUID(), tabID: UUID())
        fixture.view.onMouseDownClaimFocus?()
        fixture.state.focusedTabCloseContext = other
        fixture.window.makeFirstResponder(nil)
        #expect(fixture.state.focusedTabCloseContext == other)
    }

    @MainActor
    @Test("a click moving focus between split panes of one tab keeps the tab named")
    func aClickFromASplitSiblingKeepsTheCloseContext() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        await fixture.attach()
        try await fixture.waitForFirstResponder()

        // A split sibling in the same tab: it shares the close context and,
        // like any panel terminal, clears it when it resigns first responder.
        let sibling = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: fixture.defaults))
        fixture.view.superview?.addSubview(sibling)
        defer { sibling.removeFromSuperview() }
        let state = fixture.state
        let context = fixture.tabCloseContext
        sibling.onResignFocus = {
            if state.focusedTabCloseContext == context { state.focusedTabCloseContext = nil }
        }
        fixture.window.makeFirstResponder(sibling)
        fixture.state.focusedTabCloseContext = context

        let claimFocus = try #require(fixture.view.onMouseDownClaimFocus)
        claimFocus()

        #expect(fixture.window.firstResponder === fixture.view)
        #expect(fixture.state.focusedTabCloseContext == context, """
            the sibling's resign cleared the context the click had just named, so the tab \
            the focused terminal belongs to was left unnamed
            """)
    }

    @MainActor
    @Test("tearing a holder panel down uninstalls its click routing")
    func theClickRoutingIsRemovedOnTeardown() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        await fixture.attach()
        #expect(fixture.view.onMouseDownClaimFocus != nil)
        #expect(fixture.view.onResignFocus != nil)

        fixture.coordinator.cleanup()

        #expect(fixture.view.onMouseDownClaimFocus == nil, """
            the click routing outlived the panel: a click on the released view would still write \
            its tab as the focused one
            """)
        #expect(fixture.view.onResignFocus == nil)
    }
}
