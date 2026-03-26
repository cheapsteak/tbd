import AppKit
import SwiftUI

/// A truncating NSTextField for SwiftUI. Reports whether its content is
/// truncated via a binding, so the parent can show an expansion overlay.
struct ExpandingTextField: NSViewRepresentable {
    var text: String
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var textColor: NSColor = .labelColor

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.isBordered = false
        field.isEditable = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        field.font = font
        field.textColor = textColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
        nsView.font = font
        nsView.textColor = textColor
    }
}
