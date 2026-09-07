import AppKit
import SwiftUI

/// Bounds and step sizes the offscreen host waits and samples with, named
/// rather than spelled at each call site.
///
/// They live on a non-generic type so they can be used as default arguments of
/// `OffscreenHost`'s methods, which a generic type's own statics cannot.
enum OffscreenHostDefaults {
    /// How many pumps a bounded wait spends before giving up.
    ///
    /// Each pump is one turn of the run loop capped at `runLoopSpin`, so this is
    /// a ceiling of roughly a second of real time — long enough for SwiftUI to
    /// run a `.task`, fetch a fixture inventory and lay out, short enough that a
    /// suite that will never settle fails with a sentence instead of hanging.
    static let maxPumps = 250

    /// How long one run-loop spin is allowed to block.
    static let runLoopSpin: TimeInterval = 0.004

    /// Per-channel slack for `OffscreenHost.Capture.matches(_:_:)`, in unit
    /// colour components.
    static let colorTolerance = 0.06

    /// The pixel grid a capture is sampled on: every 4th pixel in both
    /// directions. Coarse on purpose — the questions asked of a capture are
    /// "what colour is this region" and "did anything paint at all", and neither
    /// wants to walk four million pixels.
    static let sampleStride = 4
}

/// A SwiftUI view mounted in a real — but offscreen — AppKit window, for the
/// questions no pure function can answer: where a view actually landed, what an
/// accessibility client can actually reach, and what the thing actually looks
/// like once it is drawn.
///
/// ## What hosting offscreen proves
///
/// - **Real layout.** Frames come from AppKit's own layout pass, in window
///   coordinates, so a test can assert that one view sits above another rather
///   than that a modifier was written.
/// - **Real SwiftUI lifecycle** — but only because the window is *shown*.
///   SwiftUI lays out a hierarchy and runs its `.task` only for a view in a
///   window that has been ordered front, so the window is; it sits at
///   `offscreenOrigin`, far off every display, and is never made key, so
///   showing it takes no focus from whoever is running the suite.
/// - **Both pumps.** `pump()` turns the main run loop, which drives AppKit's
///   layout and display, *and* yields to the cooperative pool, which drives
///   `.task`. Waiting on only one of the two waits forever.
/// - **A real accessibility tree**, inside `withAccessibilityBridge` — see
///   `accessibilityIdentifiers()`, and `AccessibilityBridgeSerialized` for why
///   that switch is scoped rather than simply set.
/// - **A real drawn frame**, via `capture()`.
///
/// ## What it does not prove
///
/// - **AppKit-versus-SwiftUI compositing does not reproduce offscreen.** In an
///   offscreen `cacheDisplay` of an `NSHostingView`, SwiftUI already orders its
///   own overlay above a representable sibling declared before it, whether or
///   not production states that order with `.zIndex`. Measured in
///   `CompletionOverlayPlacementTests.theListPaintsOverTheAppKitViewBesideIt`,
///   which comes back pixel-for-pixel identical with the modifier removed. A
///   capture is a guard on the outcome, never a test that discriminates a
///   stacking modifier.
/// - **Nothing about events.** The window is never key, there is no first
///   responder, and no hit testing happens. A control's *reachability* is an
///   accessibility question, which this host can ask; a control's *response to
///   a click* is not.
/// - **Nothing about elapsed time.** `settle` is bounded by a pump count, never
///   by wall clock, so behavior that genuinely needs real seconds to pass — an
///   animation running to completion, a debounce on a real clock — does not
///   finish here. Inject a clock and test that without a window.
/// - **Nothing about the display.** The window is on no screen: the backing
///   scale is 1 unless `capture(scale:)` asks for another, and vibrancy and font
///   smoothing resolve without a real display's colour space, which is why
///   colour assertions compare against a pixel read back from the same capture
///   rather than against a literal.
@MainActor
final class OffscreenHost<Root: View> {
    /// Far enough off every plausible display arrangement that the window is
    /// never visible, and never steals a click, while still being "shown" as far
    /// as SwiftUI's lifecycle is concerned.
    static var offscreenOrigin: NSPoint { NSPoint(x: -20_000, y: -20_000) }

    /// The window the hierarchy lives in. Borderless, offscreen, never key.
    let window: NSWindow

    /// The hosting view for `Root`, pinned to `contentView` at the requested
    /// size.
    let hostingView: NSHostingView<Root>

    /// The window's content view: an opaque, layer-backed ground under the
    /// hosting view, and the root every measurement and capture is taken
    /// against.
    ///
    /// It exists because a hosting view has no background of its own. A capture
    /// of it alone comes back transparent wherever the SwiftUI tree did not
    /// paint, which turns "this region is empty" into "this region is whatever
    /// the PNG viewer puts behind alpha".
    let contentView: NSView

    /// Mount `root` at `size`.
    ///
    /// - Parameters:
    ///   - root: The view under test.
    ///   - size: The content size in points. This is the pane geometry the test
    ///     is asking about, so it belongs to the caller — there is no default.
    ///   - appearance: Applied to the window, the ground and the hosting view
    ///     *before* anything is built, because `NSAttributedString` colours
    ///     resolve when they are created and do not update afterwards. Aqua by
    ///     default so a capture does not depend on the developer's system
    ///     setting; pass `nil` to inherit it deliberately.
    ///   - background: The ground's colour, resolved inside `appearance`. `nil`
    ///     leaves the ground clear, for a caller that wants alpha.
    init(
        root: Root,
        size: NSSize,
        appearance: NSAppearance? = NSAppearance(named: .aqua),
        background: NSColor? = .controlBackgroundColor
    ) {
        // Enough of an application for AppKit to have an app object at all;
        // `NSHostingView` and `NSWindow` both reach for one.
        _ = NSApplication.shared

        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let ground = NSView(frame: NSRect(origin: .zero, size: size))
        ground.wantsLayer = true
        ground.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            hosting.topAnchor.constraint(equalTo: ground.topAnchor),
            hosting.widthAnchor.constraint(equalToConstant: size.width),
            hosting.heightAnchor.constraint(equalToConstant: size.height),
        ])

        let window = NSWindow(
            contentRect: NSRect(origin: Self.offscreenOrigin, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = ground

        if let appearance {
            window.appearance = appearance
            ground.appearance = appearance
            hosting.appearance = appearance
        }
        if let background {
            // Resolved inside the appearance: a dynamic `NSColor` becomes a
            // fixed `CGColor` the moment it is handed to a layer, and outside
            // the appearance a dark capture gets a light ground.
            let paint: () -> Void = { ground.layer?.backgroundColor = background.cgColor }
            if let appearance {
                appearance.performAsCurrentDrawingAppearance(paint)
            } else {
                paint()
            }
        }

        self.hostingView = hosting
        self.contentView = ground
        self.window = window
        window.orderFront(nil)
    }

    /// Take the window back down. Idempotent, and safe to call from a `defer`.
    func tearDown() {
        window.orderOut(nil)
    }

    // MARK: - Pumping

    /// One turn of each of the two pumps SwiftUI needs.
    ///
    /// Deliberately no sleep: what a caller waits on is a bounded poll over an
    /// observable, never elapsed time.
    func pump() async {
        Self.spinRunLoop()
        await Task.yield()
    }

    /// Poll for something to become true, bounded by a pump count.
    ///
    /// - Returns: whether the condition held, so a caller can `#require` it and
    ///   fail with a sentence rather than hang.
    @discardableResult
    func settle(
        maxPumps: Int = OffscreenHostDefaults.maxPumps,
        until condition: () -> Bool
    ) async -> Bool {
        for _ in 0..<maxPumps {
            if condition() { return true }
            await pump()
        }
        return condition()
    }

    /// Turn the main run loop `count` times, synchronously.
    ///
    /// `pump()` is the one to reach for. This exists for a caller that **cannot
    /// await** — anything building inside `performAsCurrentDrawingAppearance`,
    /// whose closure is synchronous — and it drives only half of what SwiftUI
    /// needs: AppKit's layout and display, never a `.task`. A view whose content
    /// arrives from one will not fill in here.
    func pumpSynchronously(
        times count: Int = 1, spin: TimeInterval = OffscreenHostDefaults.runLoopSpin
    ) {
        for _ in 0..<count {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(spin))
        }
    }

    /// Spend `count` pumps unconditionally — for the one case a condition cannot
    /// express: giving a view that has already appeared a few more turns to be
    /// asked to *draw* before a capture is taken.
    func pump(times count: Int) async {
        for _ in 0..<count { await pump() }
    }

    /// Synchronous on purpose: `RunLoop.run(_:before:)` is unavailable from an
    /// async context, and one bounded turn of the main run loop is exactly what
    /// AppKit needs to lay out and display what SwiftUI just published.
    private static func spinRunLoop() {
        _ = RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(OffscreenHostDefaults.runLoopSpin))
    }

    // MARK: - Finding views

    /// Every view of type `V` in the mounted hierarchy, depth first.
    func descendants<V: NSView>(_ type: V.Type) -> [V] {
        Self.descendants(type, of: contentView)
    }

    /// The first view of type `V` that satisfies `predicate`.
    func firstDescendant<V: NSView>(
        _ type: V.Type, where predicate: (V) -> Bool = { _ in true }
    ) -> V? {
        descendants(type).first(where: predicate)
    }

    /// The free-standing walk, for a caller that has a subtree rather than a
    /// host.
    static func descendants<V: NSView>(_ type: V.Type, of view: NSView) -> [V] {
        var found: [V] = []
        if let match = view as? V { found.append(match) }
        for subview in view.subviews {
            found.append(contentsOf: descendants(type, of: subview))
        }
        return found
    }

    // MARK: - Geometry

    /// `view`'s frame in window coordinates, flipped to a top-left origin so
    /// "above" reads as a smaller `y`.
    ///
    /// AppKit's window space has its origin at the BOTTOM left, and an assertion
    /// written in it says the opposite of what it looks like it says.
    func flippedWindowFrame(_ view: NSView) -> NSRect {
        let inWindow = view.convert(view.bounds, to: nil)
        let height = contentView.bounds.height
        return NSRect(
            x: inWindow.minX, y: height - inWindow.maxY,
            width: inWindow.width, height: inWindow.height)
    }

    // MARK: - Accessibility

    /// Every accessibility identifier the tree exposes.
    ///
    /// Meaningful only inside `withAccessibilityBridge`: with the bridge
    /// off, SwiftUI builds no accessibility tree at all and this returns an
    /// empty set however the views are annotated.
    func accessibilityIdentifiers() -> Set<String> {
        var found: Set<String> = []
        Self.walkAccessibilityTree(contentView) { node, _ in
            if let identifier = axAttribute(node, "accessibilityIdentifier") as? String,
               !identifier.isEmpty {
                found.insert(identifier)
            }
        }
        return found
    }

    /// The same walk as an indented outline, so a failure can name the tree it
    /// found rather than only the identifier it wanted.
    func accessibilityTreeDescription() -> String {
        var lines: [String] = []
        Self.walkAccessibilityTree(contentView) { node, depth in
            let role = axAttribute(node, "accessibilityRole") as? String ?? "-"
            let identifier = (axAttribute(node, "accessibilityIdentifier") as? String)
                .map { " id=\($0)" } ?? ""
            let label = (axAttribute(node, "accessibilityLabel") as? String)
                .map { " label=\($0.prefix(40))" } ?? ""
            lines.append(
                String(repeating: "  ", count: depth) + "\(type(of: node))"
                    + " role=\(role)\(identifier)\(label)")
        }
        return lines.joined(separator: "\n")
    }

    /// Depth-first over the **accessibility** tree rather than the view
    /// hierarchy, visiting each node once.
    ///
    /// The question these walks ask is what an assistive client — or a GUI
    /// driver, which is one — can actually reach, and two things about that tree
    /// are not obvious. Both had to be found by measurement:
    ///
    /// - **SwiftUI's nodes are not `NSAccessibilityProtocol` in Swift's eyes.**
    ///   They are `SwiftUI.AccessibilityNode` objects that implement the
    ///   accessibility methods without declaring the Objective-C protocol, so
    ///   `as?` fails on every one of them and a typed walk silently reports an
    ///   empty tree. They are reached the way Objective-C reaches them instead:
    ///   by selector.
    /// - **Children are the union** of what a node declares and, for an
    ///   `NSView`, its subviews — which is how AppKit itself resolves children
    ///   for a view that has not overridden them, and how an `NSTextView` inside
    ///   a representable is reached at all.
    private static func walkAccessibilityTree(
        _ root: NSView, visit: (NSObject, Int) -> Void
    ) {
        var seen = Set<ObjectIdentifier>()

        func children(of node: NSObject) -> [Any] {
            let declared = axAttribute(node, "accessibilityChildren") as? [Any] ?? []
            return declared + ((node as? NSView)?.subviews ?? [])
        }

        func step(_ element: Any, _ depth: Int) {
            guard let node = element as? NSObject else { return }
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }
            visit(node, depth)
            for child in children(of: node) { step(child, depth + 1) }
        }

        step(root, 0)
    }

    // MARK: - Drawing

    /// One rendered frame of the mounted hierarchy.
    ///
    /// - Parameter scale: pixels per point. `nil` — the default — captures
    ///   through `cacheDisplay(in:to:)` at the window's own backing scale, which
    ///   offscreen is 1. An explicit scale renders into a bitmap of that pixel
    ///   size instead, which is how a 2x asset comes out of a host that is on no
    ///   Retina display. The two routes are AppKit's own two spellings of the
    ///   same operation (`cacheDisplay` is documented as
    ///   `displayRectIgnoringOpacity(_:in:)` into a bitmap context), kept apart
    ///   only because the default one is the long-proven path and a capture is
    ///   the last place to take a chance.
    func capture(scale: CGFloat? = nil) throws -> Capture {
        contentView.layoutSubtreeIfNeeded()
        let bounds = contentView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            throw OffscreenHostError.nothingToCapture
        }

        guard let scale else {
            guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw OffscreenHostError.couldNotMakeBitmap
            }
            contentView.cacheDisplay(in: bounds, to: rep)
            return Capture(
                rep: rep, root: contentView,
                scale: CGFloat(rep.pixelsWide) / bounds.width)
        }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((bounds.width * scale).rounded()),
            pixelsHigh: Int((bounds.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw OffscreenHostError.couldNotMakeBitmap }
        // The rep's *point* size against its pixel size is what puts the scale
        // into the context's transform; without it the view draws at 1x into the
        // top-left quarter of the bitmap.
        rep.size = bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw OffscreenHostError.couldNotMakeBitmap
        }
        contentView.displayIgnoringOpacity(bounds, in: context)
        return Capture(rep: rep, root: contentView, scale: scale)
    }

    /// One rendered frame, addressed in TOP-LEFT pixel coordinates so "above"
    /// reads as a smaller `y` here too.
    struct Capture {
        let rep: NSBitmapImageRep
        /// The view the capture was taken of, and the space `pixelFrame(of:)`
        /// converts into.
        let root: NSView
        /// Pixels per point.
        let scale: CGFloat

        /// `view`'s frame in this capture's pixel space.
        func pixelFrame(of view: NSView) -> NSRect {
            let inRoot = view.convert(view.bounds, to: root)
            let top = root.isFlipped ? inRoot.minY : root.bounds.height - inRoot.maxY
            return NSRect(
                x: inRoot.minX * scale, y: top * scale,
                width: inRoot.width * scale, height: inRoot.height * scale)
        }

        /// The colour at one pixel, in sRGB. `nil` outside the bitmap.
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
                    x += OffscreenHostDefaults.sampleStride
                }
                y += OffscreenHostDefaults.sampleStride
            }
            return total == 0 ? 0 : Double(matched) / Double(total)
        }

        /// How much the picture varies: the variance of per-pixel luminance over
        /// the whole capture, on the same coarse grid.
        ///
        /// It answers one question — **did anything actually render** — and it is
        /// the question a snapshot suite most needs answered, because a view that
        /// was never laid out captures as a large, perfectly plausible, perfectly
        /// blank image. A flat field of any colour scores 0; a screenful of UI
        /// scores orders of magnitude more.
        func luminanceVariance() -> Double {
            var samples = 0
            var sum = 0.0
            var sumOfSquares = 0.0
            var y = 0
            while y < rep.pixelsHigh {
                var x = 0
                while x < rep.pixelsWide {
                    if let color = color(x: x, y: y) {
                        // Rec. 601 luma: the weights a person's eye applies, so a
                        // dark-on-light and a light-on-dark render score alike.
                        let luminance = 0.299 * color.redComponent
                            + 0.587 * color.greenComponent
                            + 0.114 * color.blueComponent
                        samples += 1
                        sum += luminance
                        sumOfSquares += luminance * luminance
                    }
                    x += OffscreenHostDefaults.sampleStride
                }
                y += OffscreenHostDefaults.sampleStride
            }
            guard samples > 0 else { return 0 }
            let mean = sum / Double(samples)
            return max(0, sumOfSquares / Double(samples) - mean * mean)
        }

        /// PNG bytes for this capture.
        func pngData() throws -> Data {
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw OffscreenHostError.couldNotEncodePNG
            }
            return data
        }

        /// Write this capture out as a PNG, creating the enclosing directory.
        func writePNG(to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pngData().write(to: url, options: [.atomic])
        }

        /// Same colour to within a hair.
        ///
        /// Compared against a pixel READ BACK from the same capture rather than
        /// against a literal, because what a deliberate sRGB red comes back as
        /// depends on the colour space it was rendered through — on a P3 screen
        /// pure red reads as roughly (0.91, 0.28, 0.17).
        static func matches(_ color: NSColor, _ reference: NSColor) -> Bool {
            let tolerance = OffscreenHostDefaults.colorTolerance
            return abs(color.redComponent - reference.redComponent) < tolerance
                && abs(color.greenComponent - reference.greenComponent) < tolerance
                && abs(color.blueComponent - reference.blueComponent) < tolerance
        }
    }
}

/// What can go wrong between a mounted view and a bitmap. Each case describes
/// itself, so the diagnostic lands on the primary failure line rather than in a
/// comment beside it.
enum OffscreenHostError: Error, CustomStringConvertible {
    case nothingToCapture
    case couldNotMakeBitmap
    case couldNotEncodePNG
    case drawingAppearanceDidNotRun

    var description: String {
        switch self {
        case .nothingToCapture:
            return "the hosted view has zero width or height — it was never laid out"
        case .couldNotMakeBitmap:
            return "AppKit would not make a bitmap for the hosted view"
        case .couldNotEncodePNG:
            return "the captured bitmap could not be encoded as a PNG"
        case .drawingAppearanceDidNotRun:
            return "the drawing-appearance closure never ran"
        }
    }
}

/// Run `body` with `appearance` installed as the current drawing appearance, or
/// directly when it is `nil`.
///
/// Anything that resolves a dynamic colour — a layer's `backgroundColor`, an
/// `NSAttributedString`'s text colour — resolves it once, against whatever
/// appearance is current at that moment, and never updates. So a dark-mode
/// capture has to be *built* in here, not merely captured in here.
///
/// `throws` rather than `rethrows`: the error has to be carried out of a
/// non-throwing AppKit closure through a `Result`, and Swift's `rethrows` check
/// is syntactic — it does not accept an error that arrives that way.
@MainActor
@discardableResult
func withDrawingAppearance<T>(
    _ appearance: NSAppearance?, _ body: () throws -> T
) throws -> T {
    guard let appearance else { return try body() }
    var outcome: Result<T, Error>?
    appearance.performAsCurrentDrawingAppearance {
        outcome = Result { try body() }
    }
    guard let outcome else { throw OffscreenHostError.drawingAppearanceDidNotRun }
    return try outcome.get()
}

/// One accessibility accessor, by selector — see
/// `OffscreenHost.walkAccessibilityTree` for why it cannot simply be a method
/// call on a typed value.
@MainActor
private func axAttribute(_ node: NSObject, _ name: String) -> Any? {
    guard node.responds(to: Selector((name))) else { return nil }
    return node.value(forKey: name)
}
