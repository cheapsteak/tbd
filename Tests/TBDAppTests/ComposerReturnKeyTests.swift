import AppKit
import Foundation
import Testing
@testable import TBDApp

/// Chat-box Return semantics for the two first-message composers: Return
/// sends, Shift+Return and Option+Return break the line.
///
/// What is testable here is the *decision* and the *binding layer*, and the
/// suite is deliberately explicit about which is which:
///
/// - `ComposerReturnKey.action` is pure, and covers every case including the
///   IME guard.
/// - The AppKit probe below drives a real `NSTextView` with real key events to
///   confirm which command each chord resolves to — the fact the decision is
///   built on, and the one thing about it that is not ours to choose.
///
/// Neither proves the keystroke reaches the composer inside a presented sheet
/// with a live first responder. That part is verified by hand in the running
/// app; see the PR notes.
@MainActor
@Suite("ComposerReturnKey")
struct ComposerReturnKeyTests {

    // MARK: - The decision

    @Test("Plain Return sends; Shift and Option break the line")
    func returnFamilyDecision() {
        let plainReturn = #selector(NSResponder.insertNewline(_:))
        let optionReturn = #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))

        #expect(ComposerReturnKey.action(
            selector: plainReturn, shiftHeld: false, hasMarkedText: false) == .submit)
        // `StandardKeyBinding.dict` has no Shift+Return entry, so it arrives as
        // the same command as a plain Return and the modifier is the only thing
        // telling them apart.
        #expect(ComposerReturnKey.action(
            selector: plainReturn, shiftHeld: true, hasMarkedText: false) == .newline)
        // Option+Return IS a standard binding, so it arrives distinguished.
        #expect(ComposerReturnKey.action(
            selector: optionReturn, shiftHeld: false, hasMarkedText: false) == .newline)
        #expect(ComposerReturnKey.action(
            selector: optionReturn, shiftHeld: true, hasMarkedText: false) == .newline)
    }

    @Test("A Return that commits an IME candidate never sends")
    func imeCompositionIsNeverASubmit() {
        // Japanese and Chinese input commit the candidate with Return. Sending
        // the message on that keystroke would submit a half-typed sentence AND
        // swallow the commit.
        #expect(ComposerReturnKey.action(
            selector: #selector(NSResponder.insertNewline(_:)),
            shiftHeld: false, hasMarkedText: true) == .passThrough)
        #expect(ComposerReturnKey.action(
            selector: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
            shiftHeld: false, hasMarkedText: true) == .passThrough)
    }

    @Test("Every other command is AppKit's business")
    func otherCommandsPassThrough() {
        for selector in [
            #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.deleteBackward(_:)),
            #selector(NSResponder.insertParagraphSeparator(_:))
        ] {
            #expect(ComposerReturnKey.action(
                selector: selector, shiftHeld: false, hasMarkedText: false) == .passThrough)
        }
    }

    // MARK: - What AppKit actually delivers

    /// Records the commands a real `NSTextView` resolves keystrokes into.
    private final class SelectorRecorder: NSObject, NSTextViewDelegate {
        var commands: [Selector] = []
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            commands.append(commandSelector)
            return true  // swallow it: this probe is about resolution, not editing
        }
    }

    /// Drive one keystroke into a real off-screen `NSTextView` and report the
    /// command AppKit resolved it to.
    private func resolvedCommand(modifiers: NSEvent.ModifierFlags) -> Selector? {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true)
        let textView = NSTextView(frame: window.contentLayoutRect)
        let recorder = SelectorRecorder()
        textView.delegate = recorder
        window.contentView?.addSubview(textView)
        window.makeFirstResponder(textView)

        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ) else { return nil }
        textView.interpretKeyEvents([event])
        return recorder.commands.first
    }

    @Test("AppKit resolves the three chords the way the decision assumes")
    func appKitBindingsMatchTheDecision() throws {
        let plain = try #require(resolvedCommand(modifiers: []))
        #expect(plain == #selector(NSResponder.insertNewline(_:)))

        // The claim that costs the most if wrong: Shift+Return has no binding
        // of its own, so it lands on the SAME command as a plain Return and
        // only the modifier separates them.
        let shift = try #require(resolvedCommand(modifiers: [.shift]))
        #expect(shift == #selector(NSResponder.insertNewline(_:)))

        // Option+Return is a standard binding and arrives already distinct.
        let option = try #require(resolvedCommand(modifiers: [.option]))
        #expect(option == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
    }
}
