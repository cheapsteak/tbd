import SwiftUI
import AppKit

/// SwiftUI wrapper around NSComboBox so we can have a typeahead field that
/// also accepts arbitrary free-text input. The `suggestions` array seeds the
/// dropdown; the bound `text` value is what survives — not constrained to the
/// list. Use when the canonical set is well-known but escape hatches are
/// worth keeping (e.g. AWS regions where new regions may launch before we
/// update the list).
struct ComboBoxField: NSViewRepresentable {
    @Binding var text: String
    let suggestions: [String]
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSComboBox {
        let cb = NSComboBox()
        cb.usesDataSource = false
        cb.isEditable = true
        cb.completes = true
        cb.placeholderString = placeholder
        cb.addItems(withObjectValues: suggestions)
        cb.delegate = context.coordinator
        cb.target = context.coordinator
        cb.action = #selector(Coordinator.editingChanged(_:))
        return cb
    }

    func updateNSView(_ nsView: NSComboBox, context: Context) {
        // Only push state in if SwiftUI's source-of-truth diverged — otherwise
        // we'd reset the caret while the user is typing.
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Refresh the dropdown contents if the suggestion list changed.
        let current = (0..<nsView.numberOfItems).compactMap { nsView.itemObjectValue(at: $0) as? String }
        if current != suggestions {
            nsView.removeAllItems()
            nsView.addItems(withObjectValues: suggestions)
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        @Binding var text: String
        init(text: Binding<String>) { self._text = text }

        @objc func editingChanged(_ sender: NSComboBox) {
            text = sender.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let cb = notification.object as? NSComboBox else { return }
            let i = cb.indexOfSelectedItem
            if i >= 0 {
                text = (cb.itemObjectValue(at: i) as? String) ?? text
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let cb = notification.object as? NSComboBox else { return }
            text = cb.stringValue
        }
    }
}
