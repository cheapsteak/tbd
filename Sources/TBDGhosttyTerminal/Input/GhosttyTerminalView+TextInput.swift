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

import AppKit
import Foundation

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
        // The preedit is drawn on top of the grid, so a composition step is a reason to redraw even
        // though the terminal itself did not change.
        surface.markNeedsDisplay()
        requestFrame()
    }

    public func unmarkText() {
        inputController.setPreedit("", selectedRange: NSRange(location: NSNotFound, length: 0))
        surface.markNeedsDisplay()
        requestFrame()
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
        inputController.insertFromInputContext(text)
        surface.markNeedsDisplay()
        requestFrame()
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
    /// The grid is measured in device pixels and the view is flipped, so the cell rect divides by
    /// the backing scale and needs no y-flip; `convert(_:to: nil)` then `convertToScreen` does the
    /// rest.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let window else { return .zero }

        let geometry = gridGeometry
        let scale = max(backingScale, 1)
        let cursor = surface.cursor
        let origin = geometry.origin(ofColumn: cursor.column, row: cursor.row)
        let rect = NSRect(
            x: CGFloat(origin.x) / scale,
            y: CGFloat(origin.y) / scale,
            width: CGFloat(geometry.cellSizePx.x) / scale,
            height: CGFloat(geometry.cellSizePx.y) / scale)

        return window.convertToScreen(convert(rect, to: nil))
    }

    /// There is no addressable text behind the terminal for a point to index into.
    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
