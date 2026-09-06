import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// **Where the completion list lands.** The one thing about the menu that no
/// pure function can state: it is an alignment guide on an overlay, and the
/// difference between opening upward and opening downward over the text field
/// is one edge name.
///
/// So this suite mounts the real `MessageComposerView` in a real window, opens
/// the menu by typing into the real text view, and measures the two frames in
/// window coordinates. The first shipped guide anchored the overlay's top to the
/// composer's bottom — a list that covered the words being typed and ran off the
/// bottom of the pane — and every assertion here fails against it.
@MainActor
@Suite("completion overlay placement")
struct CompletionOverlayPlacementTests {

    // MARK: - Fixtures

    /// Enough commands that the list is taller than its eight-row cap, so the
    /// cap is exercised rather than assumed.
    private static let inventory = TerminalCompletionsResult(
        commands: (0..<20).map {
            CompletionCommand(
                name: "compact\($0)", description: "Compact the conversation, take \($0)")
        },
        agents: [], freshness: .fresh, source: .probe)

    private func makeAppState() -> (AppState, String) {
        let suiteName = "CompletionOverlayPlacementTests-\(UUID().uuidString)"
        let state = AppState(userDefaults: UserDefaults(suiteName: suiteName)!)
        state.composerCompletionsFetcher = { _ in Self.inventory }
        return (state, suiteName)
    }

    private func makeWorktree() -> LocalWorktree {
        LocalWorktree(Worktree(
            id: UUID(), repoID: UUID(), name: "wt", displayName: "WT", branch: "main",
            path: "/tmp/wt", status: .active, tmuxServer: "test-server", location: .local))!
    }

    private func makeTerminal(worktreeID: UUID) -> Terminal {
        Terminal(
            id: UUID(), worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)
    }

    // MARK: - The harness

    /// A mounted composer, pinned to the bottom of an offscreen window with the
    /// transcript's worth of empty space above it — the shape the pane gives it,
    /// and the space the list has to be allowed to grow into.
    private struct Mounted {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let state: AppState
        let suiteName: String
    }

    private func mount() -> Mounted {
        _ = NSApplication.shared
        let (state, suiteName) = makeAppState()
        let worktree = makeWorktree()
        let terminal = makeTerminal(worktreeID: worktree.id)
        // The menu is opened through the DRAFT rather than by typing into the
        // text view afterwards. The composer's own set-up restores the draft as
        // its first act and reports the restored text back through
        // `onTextChange`, which is the production path that opens the list — and
        // it means nothing races the restore. Typing first loses: the restore
        // lands after it, clears an empty draft over the typed text, and
        // dismisses the menu again a turn later.
        state.composerDraft(for: terminal.id).text = "/comp"

        let root = AnyView(
            VStack(spacing: 0) {
                // Stands in for the transcript table: the region the list opens
                // out over.
                Color.clear
                MessageComposerView(
                    terminal: terminal, worktree: worktree, state: .running)
            }
            .environment(state))

        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 720, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Ordered front, never made key: SwiftUI runs `.task` and lays the
        // hierarchy out only for a view in a window that has been shown, and the
        // window sits far off every screen so showing it takes no focus from
        // whoever is running the suite.
        window.orderFront(nil)
        return Mounted(window: window, host: host, state: state, suiteName: suiteName)
    }

    /// One pump of both pumps SwiftUI needs: the main run loop, which drives
    /// AppKit's layout and display, and the cooperative pool, which drives
    /// `.task`. Deliberately no sleep — a bounded poll on an observable is what
    /// each caller waits on.
    private func pump() async {
        spinRunLoop()
        await Task.yield()
    }

    /// Synchronous on purpose: `RunLoop.run(_:before:)` is unavailable from an
    /// async context, and one turn of the main run loop is exactly what AppKit
    /// needs to lay out and display what SwiftUI just published.
    private func spinRunLoop() {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.004))
    }

    /// Poll for something to become true, bounded. Returns whether it did, so
    /// callers `#require` it and fail fast with a sentence rather than hanging.
    private func settle(_ maxPumps: Int = 250, until: () -> Bool) async -> Bool {
        for _ in 0..<maxPumps {
            if until() { return true }
            await pump()
        }
        return until()
    }

    private func descendants<V: NSView>(_ type: V.Type, of view: NSView) -> [V] {
        var found: [V] = []
        if let match = view as? V { found.append(match) }
        for subview in view.subviews { found.append(contentsOf: descendants(type, of: subview)) }
        return found
    }

    /// The composer's text view — the only `ComposerTextView` in the tree.
    private func textView(in host: NSView) -> ComposerTextView? {
        descendants(ComposerTextView.self, of: host).first
    }

    /// The completion list. `CompletionOverlayView` backs itself with a
    /// `.menu`-material `VisualEffectView`, which is an `NSViewRepresentable`
    /// and therefore a real `NSView` in the hierarchy — the one piece of the
    /// SwiftUI overlay whose frame AppKit can be asked for.
    private func overlayView(in host: NSView) -> NSVisualEffectView? {
        descendants(NSVisualEffectView.self, of: host).first { $0.material == .menu }
    }

    /// A view's frame in window coordinates, flipped to a top-left origin so
    /// "above" reads as a smaller `y`. AppKit's window space has its origin at
    /// the BOTTOM left, and an assertion written in it says the opposite of what
    /// it looks like it says.
    private func flippedWindowFrame(_ view: NSView, in window: NSWindow) -> NSRect {
        let inWindow = view.convert(view.bounds, to: nil)
        let height = window.contentView?.bounds.height ?? 0
        return NSRect(
            x: inWindow.minX, y: height - inWindow.maxY,
            width: inWindow.width, height: inWindow.height)
    }

    /// Mount a composer whose draft is `/comp`, and wait for its list to reach
    /// full height.
    private func openMenu() async throws -> (Mounted, NSVisualEffectView, ComposerTextView) {
        let mounted = mount()
        // The full-height condition is what proves the INVENTORY landed too: a
        // menu still waiting on it shows one short "Loading commands" row, and
        // stopping there would measure a placement the eight rows never had.
        let settled = await settle {
            guard let overlay = overlayView(in: mounted.host) else { return false }
            return overlay.bounds.height >= CompletionOverlayView.maxHeight
        }
        try #require(settled, .init(rawValue: diagnostics(mounted)))
        let overlay = try #require(overlayView(in: mounted.host))
        let field = try #require(textView(in: mounted.host))
        try #require(field.string == "/comp", "the draft never reached the text view")
        return (mounted, overlay, field)
    }

    /// What the tree actually held when a wait ran out — so a failure names the
    /// state it gave up in rather than only the state it wanted.
    private func diagnostics(_ mounted: Mounted) -> String {
        let effects = descendants(NSVisualEffectView.self, of: mounted.host)
            .map { "material=\($0.material.rawValue) h=\($0.bounds.height)" }
        let text = textView(in: mounted.host)?.string ?? "<no text view>"
        return """
        the completion list never reached its full height.         text=\(text.debugDescription) effects=\(effects)         views=\(descendants(NSView.self, of: mounted.host).count)
        """
    }

    // MARK: - Placement

    /// **The bug.** The list must sit entirely above the text field: its bottom
    /// edge at or above the field's top edge, so not one pixel of what is being
    /// typed is covered.
    @Test func theListOpensAboveTheTextField() async throws {
        let (mounted, overlay, field) = try await openMenu()
        defer {
            mounted.window.orderOut(nil)
            UserDefaults.standard.removePersistentDomain(forName: mounted.suiteName)
        }

        let listFrame = flippedWindowFrame(overlay, in: mounted.window)
        let fieldFrame = flippedWindowFrame(field, in: mounted.window)

        #expect(
            listFrame.maxY <= fieldFrame.minY,
            """
            the list runs to y=\(listFrame.maxY) and the field starts at \
            y=\(fieldFrame.minY) — it is covering the text being typed
            """)
    }

    /// The other half of opening downward: a list anchored below the composer
    /// runs off the bottom of the pane and shows fewer rows than it has. Growing
    /// upward, all eight fit inside the window.
    @Test func theWholeListFitsInsideTheWindow() async throws {
        let (mounted, overlay, _) = try await openMenu()
        defer {
            mounted.window.orderOut(nil)
            UserDefaults.standard.removePersistentDomain(forName: mounted.suiteName)
        }

        let listFrame = flippedWindowFrame(overlay, in: mounted.window)
        let content = try #require(mounted.window.contentView).bounds

        #expect(listFrame.minY >= 0, "the list is clipped at the top of the pane")
        #expect(listFrame.maxY <= content.height, "the list is clipped at the bottom")
        #expect(
            listFrame.height == CompletionOverlayView.maxHeight,
            "eight rows and no more: \(listFrame.height)")
        #expect(listFrame.width == 460)
    }

    // MARK: - The height itself

    /// The arithmetic behind the frame, without a window: as many rows as there
    /// are, up to eight, and never zero — a list showing its one-line "loading"
    /// or "no commands match" message still needs a row's worth of box.
    @Test func theListIsAsTallAsItsRowsUpToEight() {
        #expect(CompletionOverlayView.listHeight(rowCount: 3)
            == CompletionOverlayView.rowHeight * 3)
        #expect(CompletionOverlayView.listHeight(rowCount: 8)
            == CompletionOverlayView.maxHeight)
        #expect(CompletionOverlayView.listHeight(rowCount: 40)
            == CompletionOverlayView.maxHeight)
        #expect(CompletionOverlayView.listHeight(rowCount: 0)
            == CompletionOverlayView.rowHeight)
    }
}
