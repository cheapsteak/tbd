import AppKit
import SwiftUI

/// An NSTextField wrapped for SwiftUI that supports native AppKit expansion
/// tooltips — when the text is truncated, hovering reveals the full text in
/// a floating label (the same mechanism Xcode uses in its navigator).
struct ExpandingTextField: NSViewRepresentable {
    var text: String
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var textColor: NSColor = .labelColor

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.allowsExpansionToolTips = true
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
