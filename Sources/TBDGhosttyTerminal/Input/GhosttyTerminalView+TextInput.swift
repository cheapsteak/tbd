// Adapted from tkzmux c961533 Sources/TkzTerminalView/TerminalMetalView+TextInput.swift (MIT, see LICENSE-tkzmux.txt).
// GhosttyTerminalView+TextInput — `NSTextInputClient`.
//
// `NSTextInputClient` is declared here rather than on `GhosttyTerminalView` itself so the view
// stays free of input policy: conformance is what makes `NSView.inputContext` non-nil, and
// everything the protocol asks for is either geometry the view already exposes or state that
// belongs to `TerminalInputController`.
//
// The conformance is `@preconcurrency` because AppKit does not mark the protocol main-actor, while
// every method here is (the view is). AppKit only calls it on the main thread.
//
// ## The preedit overlay
//
// While an input method composes (a dead key, Japanese, Chinese), its marked text is shown over
// the cursor cell, underlined as macOS marks it, in the terminal's font and colours. It is a layer
// over the Metal frame, like the link underline, not terminal content: the program never sees the
// composition, only the text the input method commits, so nothing of it belongs in the grid. A
// commit or a cancel takes the layer away, and the committed text reaches the program as typed
// input, which it echoes into the grid.

import AppKit
import Foundation
import QuartzCore

extension GhosttyTerminalView: @preconcurrency NSTextInputClient {
    // MARK: - Marked text (preedit)

    public func hasMarkedText() -> Bool {
        inputController.hasMarkedText
    }

    public func markedRange() -> NSRange {
        guard inputController.hasMarkedText else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: (inputController.preedit as NSString).length)
    }

    /// The terminal has no editable text behind the cursor, so the "selection" for input purposes
    /// is the empty range at the insertion point. (Text selection on screen is the mouse
    /// controller's `SelectionController` and is a different concept entirely.)
    public func selectedRange() -> NSRange {
        guard inputController.hasMarkedText else { return NSRange(location: NSNotFound, length: 0) }
        return inputController.preeditSelectedRange
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        switch string {
        case let value as NSAttributedString: text = value.string
        case let value as String: text = value
        default: text = ""
        }
        inputController.setPreedit(text, selectedRange: selectedRange)
        // A layer over the frame, so a composition step needs no Metal frame of its own.
        updatePreeditOverlay()
    }

    public func unmarkText() {
        inputController.setPreedit("", selectedRange: NSRange(location: NSNotFound, length: 0))
        updatePreeditOverlay()
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard inputController.hasMarkedText else { return nil }
        let preedit = inputController.preedit as NSString
        let clamped = NSRange(
            location: min(range.location, preedit.length),
            length: min(range.length, max(0, preedit.length - min(range.location, preedit.length))))
        actualRange?.pointee = clamped
        return NSAttributedString(string: preedit.substring(with: clamped))
    }

    // MARK: - Committed text

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let value as NSAttributedString: text = value.string
        case let value as String: text = value
        default: return
        }
        // The commit ends the composition: the overlay goes, and the text goes to the program,
        // whose echo is what redraws the grid.
        inputController.insertFromInputContext(text)
        updatePreeditOverlay()
    }

    /// Deliberately empty.
    ///
    /// Two reasons, both load-bearing. (1) Without it, every unimplemented selector the input
    /// system dispatches (`insertNewline:`, `cancelOperation:`, `noop:`) walks off the end of the
    /// responder chain and AppKit beeps. (2) Enter, Tab and the arrow keys all arrive here *before*
    /// `keyDown` finishes; letting the default implementation act on them would insert a newline
    /// through the text system and then encode the key again.
    public override func doCommand(by selector: Selector) {}

    // MARK: - Geometry

    /// Where the IME candidate window should sit: the cursor cell, in **screen** coordinates.
    ///
    /// The view is flipped, so the cell rect needs no y-flip; `convert(_:to: nil)` then
    /// `convertToScreen` does the rest.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let window else { return .zero }
        return window.convertToScreen(convert(cursorCellRect(columns: 1), to: nil))
    }

    /// There is no addressable text behind the terminal for a point to index into.
    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// `columns` cells starting at the terminal's cursor, in view points.
    ///
    /// The cursor is read from the terminal rather than from the last frame, because composition
    /// can start before a frame has been built (a view shown a moment ago, or one in a test). The
    /// grid is measured in device pixels and pinned top-left in a flipped view, so the rect only
    /// divides by the backing scale.
    func cursorCellRect(columns: Int) -> NSRect {
        let geometry = gridGeometry
        let scale = max(backingScale, 1)
        let cursor = terminal.withLocked { $0.cursor }
        let origin = geometry.origin(ofColumn: cursor.col, row: cursor.row)
        return NSRect(
            x: CGFloat(origin.x) / scale,
            y: CGFloat(origin.y) / scale,
            width: CGFloat(geometry.cellSizePx.x) * CGFloat(max(1, columns)) / scale,
            height: CGFloat(geometry.cellSizePx.y) / scale)
    }
}

// MARK: - Preedit overlay

extension GhosttyTerminalView {
    /// The name of the layer that shows the input method's composition text.
    static let preeditLayerName = "TBDGhosttyTerminal.preedit"

    /// The layer over the cursor cell that shows the composition text, while an input method is
    /// composing. nil otherwise. It holds the text and the underline.
    var preeditLayer: CALayer? {
        layer?.sublayers?.first { $0.name == Self.preeditLayerName }
    }

    /// The text half of `preeditLayer`. A test seam.
    var preeditTextLayer: CATextLayer? {
        preeditLayer?.sublayers?.lazy.compactMap { $0 as? CATextLayer }.first
    }

    /// Shows the composition text over the cursor, or takes it away once there is none.
    ///
    /// The text is drawn on the terminal's background, so it covers the cells beneath it and the
    /// cursor, and it is as many cells wide as the text needs: two for each CJK character. A
    /// composition too wide for the rest of the row moves left to stay inside the view.
    func updatePreeditOverlay() {
        let text = inputController.preedit
        guard !text.isEmpty, let host = layer else {
            preeditLayer?.removeFromSuperlayer()
            return
        }
        let (container, textLayer, underline) = preeditLayers(in: host)

        let font = terminalAppearance.font
        let colors = terminal.withLocked { (foreground: $0.foregroundColor, background: $0.backgroundColor) }
        let foreground = Self.cgColor(colors.foreground ?? terminalAppearance.foreground)
        let background = Self.cgColor(colors.background ?? terminalAppearance.background)

        // Whole cells, with a little slack so a text exactly two cells wide is not rounded to three.
        let cellWidth = max(cursorCellRect(columns: 1).width, 1)
        let textWidth = NSAttributedString(string: text, attributes: [.font: font]).size().width
        let columns = max(1, Int((textWidth / cellWidth - 0.01).rounded(.up)))
        var overlayFrame = cursorCellRect(columns: columns)
        if bounds.width > 0, overlayFrame.maxX > bounds.width {
            overlayFrame.origin.x = max(0, bounds.width - overlayFrame.width)
        }

        let scale = max(backingScale, 1)
        container.frame = overlayFrame
        container.backgroundColor = background
        textLayer.frame = container.bounds
        textLayer.contentsScale = scale
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.foregroundColor = foreground
        textLayer.string = text
        // The link underline's weight: a fourteenth of the cell height, at least a device pixel.
        let thickness = max(1, (overlayFrame.height * scale / 14).rounded()) / scale
        underline.frame = CGRect(x: 0, y: overlayFrame.height - thickness, width: overlayFrame.width, height: thickness)
        underline.backgroundColor = foreground
    }

    /// The overlay's container, text and underline layers, made on first use.
    private func preeditLayers(in host: CALayer) -> (CALayer, CATextLayer, CALayer) {
        if let container = preeditLayer, let sublayers = container.sublayers, sublayers.count == 2,
           let textLayer = sublayers[0] as? CATextLayer {
            return (container, textLayer, sublayers[1])
        }
        preeditLayer?.removeFromSuperlayer()
        return makePreeditLayer(in: host)
    }

    private func makePreeditLayer(in host: CALayer) -> (CALayer, CATextLayer, CALayer) {
        // No implicit animations: the layer should jump to each composition step, not slide.
        let still: [String: any CAAction] = [
            "position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull(),
            "backgroundColor": NSNull(), "foregroundColor": NSNull(), "string": NSNull(),
        ]
        let container = CALayer()
        container.name = Self.preeditLayerName
        container.actions = still
        // Above the link underline, which sits at 1.
        container.zPosition = 2
        let textLayer = CATextLayer()
        textLayer.actions = still
        textLayer.isWrapped = false
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .none
        let underline = CALayer()
        underline.actions = still
        container.addSublayer(textLayer)
        container.addSublayer(underline)
        host.addSublayer(container)
        return (container, textLayer, underline)
    }

    private static func cgColor(_ rgb: GhosttyAppearance.RGB) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}
