import AppKit
import SwiftUI

/// A TextField that preserves cursor position when regaining focus,
/// instead of selecting all text (SwiftUI's default behavior).
struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursorPosition: Int
    var isFocused: Binding<Bool>
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onKeyDown: ((_ key: UInt16) -> Bool)?

    func makeNSView(context: Context) -> FocusStableTextField {
        let field = FocusStableTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byClipping
        return field
    }

    func updateNSView(_ nsView: FocusStableTextField, context: Context) {
        // Only update text if it changed externally (not from user typing)
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onKeyDown = onKeyDown
        nsView.desiredCursorPosition = cursorPosition

        if isFocused.wrappedValue {
            DispatchQueue.main.async {
                if nsView.window?.firstResponder != nsView.currentEditor() {
                    // Close any popover instantly before refocusing
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0
                        nsView.window?.makeFirstResponder(nsView)
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: InlineTextField

        init(_ parent: InlineTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            if let editor = field.currentEditor() {
                parent.cursorPosition = editor.selectedRange.location
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFocused.wrappedValue = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            // Arrow keys for emoji picker navigation
            if let onKeyDown = parent.onKeyDown {
                let keyMap: [Selector: UInt16] = [
                    #selector(NSResponder.moveUp(_:)): 126,
                    #selector(NSResponder.moveDown(_:)): 125,
                    #selector(NSResponder.moveLeft(_:)): 123,
                    #selector(NSResponder.moveRight(_:)): 124,
                ]
                if let keyCode = keyMap[commandSelector] {
                    if onKeyDown(keyCode) {
                        return true // consumed by emoji picker
                    }
                }
            }
            return false
        }
    }
}

/// NSTextField subclass that preserves cursor position on refocus
/// instead of selecting all text.
final class FocusStableTextField: NSTextField {
    var onKeyDown: ((_ key: UInt16) -> Bool)?
    var desiredCursorPosition: Int?
    private var savedSelection: NSRange?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            let target = desiredCursorPosition ?? savedSelection?.location
            if let pos = target {
                DispatchQueue.main.async { [weak self] in
                    if let editor = self?.currentEditor() {
                        let clamped = min(pos, editor.string.count)
                        editor.selectedRange = NSRange(location: clamped, length: 0)
                    }
                }
            }
        }
        return result
    }

    override func textDidEndEditing(_ notification: Notification) {
        if let editor = currentEditor() {
            savedSelection = editor.selectedRange
        }
        super.textDidEndEditing(notification)
    }
}
