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
    /// Called when Tab or Space is pressed. Return true to consume the event.
    var onSpecialKey: ((_ key: SpecialKey) -> Bool)?

    enum SpecialKey {
        case tab, space
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byClipping
        // Monitor key events to intercept Tab/Space before AppKit handles them
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak field] event in
            guard let field, field.currentEditor() != nil else { return event }
            // Tab (keyCode 48) or Space (keyCode 49)
            if event.keyCode == 48 || event.keyCode == 49 {
                let key: SpecialKey = event.keyCode == 48 ? .tab : .space
                if let onSpecialKey = context.coordinator.parent.onSpecialKey, onSpecialKey(key) {
                    return nil // consumed
                }
            }
            return event
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        let textChanged = nsView.stringValue != text
        if textChanged {
            nsView.stringValue = text
        }

        if isFocused.wrappedValue {
            DispatchQueue.main.async {
                let needsFocus = nsView.window?.firstResponder != nsView.currentEditor()
                if needsFocus {
                    nsView.window?.makeFirstResponder(nsView)
                }
                // Set cursor position after focus is established and text is updated
                if needsFocus || textChanged {
                    if let editor = nsView.currentEditor() {
                        let pos = min(cursorPosition, editor.string.count)
                        editor.selectedRange = NSRange(location: pos, length: 0)
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextField
        var monitor: Any?

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
            if let onKeyDown = parent.onKeyDown {
                let keyMap: [Selector: UInt16] = [
                    #selector(NSResponder.moveUp(_:)): 126,
                    #selector(NSResponder.moveDown(_:)): 125,
                    #selector(NSResponder.moveLeft(_:)): 123,
                    #selector(NSResponder.moveRight(_:)): 124,
                ]
                if let keyCode = keyMap[commandSelector] {
                    if onKeyDown(keyCode) {
                        return true
                    }
                }
            }
            return false
        }
    }
}
