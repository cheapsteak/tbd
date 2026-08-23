import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp

/// Who owns the composer's text, and where a submit reads it from.
///
/// Tier 1: deterministic, in-process state only — a real but off-screen
/// `NSTextView` driven through a real `Coordinator`. No sleeps, no
/// subprocesses, no filesystem, no `~/tbd`.
///
/// `SubmittingTextEditor` takes text in exactly once, at `makeNSView`, and
/// never again: the view owns what it holds while it is on screen, and SwiftUI
/// only ever hears about it. That is what makes a lagging update pass unable to
/// move the caret — there is no write for it to carry. These cases pin the two
/// halves of that contract a test can reach: every edit is reported outward in
/// order, and a submit reads the TEXT VIEW rather than the coordinator's
/// `parent`, which an update pass can leave a beat behind.
///
/// `updateNSView` itself is not callable from a test — there is no way to
/// construct a `Context` — so the staleness case constructs the same condition
/// directly, by driving a coordinator whose `parent` is the one it was built
/// with.
@MainActor
@Suite("ComposerTextOwnership")
struct ComposerTextOwnershipTests {

    /// What the editor reported outward, in the order it reported it.
    private final class Reports {
        var changes: [String] = []
        var submitted: [String] = []
        var cancels = 0
    }

    /// A real off-screen `NSTextView` delegating to a real `Coordinator`.
    private struct Probe {
        let window: NSWindow
        let textView: NSTextView
        let coordinator: SubmittingTextEditor.Coordinator
        let reports: Reports

        /// Insert at the caret the way a keystroke does, so the delegate fires
        /// and the coordinator reports the edit.
        @MainActor
        func type(_ text: String) {
            textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        /// Hand the coordinator a resolved command the way AppKit's
        /// `interpretKeyEvents` would.
        @MainActor
        @discardableResult
        func command(_ selector: Selector) -> Bool {
            coordinator.textView(textView, doCommandBy: selector)
        }
    }

    /// `initialText` seeds the coordinator's `parent`, which is the value a
    /// wrong implementation would submit. `seedTextView` is what the view
    /// actually ends up holding — passed separately so a test can make the two
    /// disagree, which is the whole point of the staleness case.
    private func makeProbe(initialText: String = "", seedTextView: String? = nil) -> Probe {
        // `doCommandBy` reads `NSApp.currentEvent` for the Shift modifier, and
        // `NSApp` is nil until an application object exists.
        _ = NSApplication.shared

        let reports = Reports()
        let editor = SubmittingTextEditor(
            initialText: initialText,
            onTextChange: { reports.changes.append($0) },
            onSubmit: { reports.submitted.append($0) },
            onCancel: { reports.cancels += 1 },
            focusOnAppear: false)
        let coordinator = SubmittingTextEditor.Coordinator(editor)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true)
        let textView = NSTextView(frame: window.contentLayoutRect)
        textView.delegate = coordinator
        // Mirror the `makeNSView` settings this suite is answerable to.
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        // Straight onto the storage, bypassing the delegate: this stands in for
        // the seeding `makeNSView` does, which reports nothing outward either.
        textView.string = seedTextView ?? initialText
        window.contentView?.addSubview(textView)
        window.makeFirstResponder(textView)
        return Probe(
            window: window, textView: textView, coordinator: coordinator, reports: reports)
    }

    @Test("Every keystroke is reported outward, in order, as the view now holds it")
    func typingForwardsEachValue() {
        let probe = makeProbe()
        probe.type("d")
        probe.type("r")
        probe.type("aft")

        #expect(probe.reports.changes == ["d", "dr", "draft"])
        #expect(probe.textView.string == "draft")
        // Reporting is one-way: nothing flowed back into the view.
        #expect(probe.reports.submitted.isEmpty)
    }

    @Test("Return submits what the text view holds, not what the parent was handed")
    func submitReadsTheTextViewNotTheStaleParent() {
        // The staleness, constructed: the coordinator's `parent` still carries
        // the text the view was made with, while the view has moved on. This is
        // exactly the shape an update pass evaluated before the last keystroke
        // leaves behind, and submitting `parent.initialText` here would send a
        // message missing everything typed since.
        let probe = makeProbe(initialText: "stale seed", seedTextView: "stale seed")
        probe.type(" plus the last word")
        #expect(probe.coordinator.parent.initialText == "stale seed")

        probe.command(#selector(NSResponder.insertNewline(_:)))

        #expect(probe.reports.submitted == ["stale seed plus the last word"])
        // Return sends rather than breaking the line, so the text is untouched.
        #expect(probe.textView.string == "stale seed plus the last word")
    }

    @Test("Escape forwards cancel and swallows the key")
    func escapeForwardsCancel() {
        let probe = makeProbe()
        probe.type("half a thought")

        let handled = probe.command(#selector(NSResponder.cancelOperation(_:)))

        #expect(handled)
        #expect(probe.reports.cancels == 1)
        #expect(probe.reports.submitted.isEmpty)
    }
}
