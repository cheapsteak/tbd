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

    /// What stands above the composer in the mounted stack.
    enum Sibling {
        /// `Color.clear`. Enough to give the list a region to grow into, and all
        /// the geometry assertions need.
        case transparent
        /// A real `NSViewRepresentable` that fills itself solid red — the shape
        /// of the composer's actual neighbour, `TableTranscriptView`. Ordering a
        /// SwiftUI overlay against a HOSTED AppKit view is precisely what the
        /// pane's `.zIndex(1)` states, and a SwiftUI-only sibling cannot pose
        /// that question: SwiftUI orders its own layers among themselves either
        /// way.
        case paintedAppKit
    }

    private func mount(sibling: Sibling = .transparent) -> Mounted {
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
                switch sibling {
                case .transparent:
                    Color.clear
                case .paintedAppKit:
                    SolidRedRepresentable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
    private func openMenu(
        sibling: Sibling = .transparent
    ) async throws -> (Mounted, NSVisualEffectView, ComposerTextView) {
        let mounted = mount(sibling: sibling)
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

    // MARK: - Paint order

    /// One rendered frame of the mounted hierarchy, addressed in TOP-LEFT pixel
    /// coordinates so "above" reads as a smaller `y` here too.
    private struct Capture {
        let rep: NSBitmapImageRep
        let host: NSView
        let scale: CGFloat

        /// `view`'s frame in this capture's pixel space.
        func pixelFrame(of view: NSView) -> NSRect {
            let inHost = view.convert(view.bounds, to: host)
            let top = host.isFlipped ? inHost.minY : host.bounds.height - inHost.maxY
            return NSRect(
                x: inHost.minX * scale, y: top * scale,
                width: inHost.width * scale, height: inHost.height * scale)
        }

        func color(x: Int, y: Int) -> NSColor? {
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
            return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        }

        /// The share of pixels in `rect` that match `reference`, sampled on a
        /// coarse grid — a fraction rather than a single probe, so the verdict
        /// does not depend on landing between two glyphs.
        func fraction(in rect: NSRect, matching reference: NSColor) -> Double {
            var total = 0
            var matched = 0
            var y = Int(rect.minY)
            while y < Int(rect.maxY) {
                var x = Int(rect.minX)
                while x < Int(rect.maxX) {
                    if let color = color(x: x, y: y) {
                        total += 1
                        if Self.matches(color, reference) { matched += 1 }
                    }
                    x += 4
                }
                y += 4
            }
            return total == 0 ? 0 : Double(matched) / Double(total)
        }

        /// Same color to within a hair. Compared against a pixel READ BACK from
        /// this same capture rather than against a literal, because what a
        /// deliberate sRGB red comes back as depends on the display's color
        /// space — on a P3 screen pure red reads as roughly (0.91, 0.28, 0.17).
        static func matches(_ color: NSColor, _ reference: NSColor) -> Bool {
            abs(color.redComponent - reference.redComponent) < 0.06
                && abs(color.greenComponent - reference.greenComponent) < 0.06
                && abs(color.blueComponent - reference.blueComponent) < 0.06
        }

        /// Unmistakably the sibling's red rather than an empty capture: a strong
        /// red channel dominating both of the others.
        static func isRed(_ color: NSColor) -> Bool {
            color.redComponent > 0.7
                && color.redComponent > color.greenComponent * 2
                && color.redComponent > color.blueComponent * 2
        }
    }

    private func capture(_ mounted: Mounted) throws -> Capture {
        let host: NSView = mounted.host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = host.bounds.width > 0 ? CGFloat(rep.pixelsWide) / host.bounds.width : 1
        return Capture(rep: rep, host: host, scale: scale)
    }

    /// **The list paints over the AppKit view beside it.** The other tests in
    /// this suite measure frames, and a frame is the same whether the list paints
    /// over its neighbour or under it. This one renders instead: a real
    /// `NSViewRepresentable` sibling — the shape of `TableTranscriptView` — fills
    /// the region the list grows into with solid red, the menu is opened the same
    /// way, and the list's own interior is read back out of a bitmap. Painting
    /// under the AppKit view would leave that interior red.
    ///
    /// The control pixel beside the list is asserted red FIRST, so a capture in
    /// which nothing painted at all fails as the harness problem it is rather
    /// than passing as a clean list.
    ///
    /// **What it does not prove.** It is a guard on the outcome, not a test that
    /// discriminates the pane's `.zIndex(1)`: with that modifier removed, this
    /// capture comes back pixel-for-pixel identical (interior 0.94 grey, the
    /// selected row's accent tint at the top, 0% of it the sibling's red). In an
    /// offscreen `cacheDisplay` of an `NSHostingView`, SwiftUI already orders the
    /// composer's overlay above a representable sibling declared before it, so
    /// the stacking the modifier states is not the stacking this route exercises.
    /// The modifier stays because the live pane's sibling is a layer-backed
    /// scrolling table rather than a solid-color `NSView`, and stating the order
    /// is cheaper than depending on declaration order there; the test stays
    /// because it fails loudly if the list ever stops painting over its
    /// neighbour at all.
    @Test func theListPaintsOverTheAppKitViewBesideIt() async throws {
        let (mounted, overlay, _) = try await openMenu(sibling: .paintedAppKit)
        defer {
            mounted.window.orderOut(nil)
            UserDefaults.standard.removePersistentDomain(forName: mounted.suiteName)
        }
        // A few more turns of both pumps so the sibling has been asked to draw.
        _ = await settle(6) { false }

        let shot = try capture(mounted)
        let list = shot.pixelFrame(of: overlay)

        // The control sits BESIDE the list, at the same height: the list is 460pt
        // of a 720pt-wide pane, so everything to its right is untouched sibling,
        // clear of the list's own shadow.
        let controlX = Int(min(list.maxX + 40 * shot.scale, CGFloat(shot.rep.pixelsWide - 1)))
        let controlY = Int(list.midY)
        let control = try #require(shot.color(x: controlX, y: controlY))
        guard Capture.isRed(control) else {
            Issue.record("""
                the AppKit sibling never painted, so this capture proves nothing: \
                the control pixel at (\(controlX), \(controlY)), beside the list at \
                \(list), is \(Self.describe(control))
                """)
            return
        }

        // Inset past the rounded corners and the hairline stroke; the shadow
        // falls outside the frame already.
        let interior = list.insetBy(dx: 10 * shot.scale, dy: 10 * shot.scale)
        let redFraction = shot.fraction(in: interior, matching: control)
        #expect(
            redFraction < 0.05,
            """
            the completion list is painting UNDER the AppKit view beside it: \
            \(Int(redFraction * 100))% of its interior \(interior) came back the \
            sibling's \(Self.describe(control))
            """)
    }

    private static func describe(_ color: NSColor) -> String {
        String(
            format: "rgba(%.2f, %.2f, %.2f, %.2f)",
            color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
    }
}

/// Fills itself with the one color nothing else in the mounted hierarchy paints.
/// Layer-backed *and* drawing in `draw(_:)`, so it is opaque whichever of the two
/// routes the capture takes.
private final class SolidRedView: NSView {
    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        dirtyRect.fill()
    }
}

private struct SolidRedRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> SolidRedView { SolidRedView() }
    func updateNSView(_ nsView: SolidRedView, context: Context) {}
}
