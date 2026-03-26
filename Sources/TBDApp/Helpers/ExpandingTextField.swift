import AppKit
import SwiftUI

/// A truncating NSTextField for SwiftUI that reports whether its content
/// is truncated via a binding, so the parent can conditionally show an
/// expansion overlay.
struct ExpandingTextField: NSViewRepresentable {
    var text: String
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var textColor: NSColor = .labelColor
    @Binding var isTruncated: Bool

    func makeNSView(context: Context) -> TruncationDetectingTextField {
        let field = TruncationDetectingTextField(labelWithString: text)
        field.isBordered = false
        field.isEditable = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        field.font = font
        field.textColor = textColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onTruncationChanged = { [self] truncated in
            DispatchQueue.main.async { self.isTruncated = truncated }
        }
        return field
    }

    func updateNSView(_ nsView: TruncationDetectingTextField, context: Context) {
        nsView.stringValue = text
        nsView.font = font
        nsView.textColor = textColor
        nsView.onTruncationChanged = { [self] truncated in
            DispatchQueue.main.async { self.isTruncated = truncated }
        }
    }
}

/// NSTextField subclass that detects truncation on layout changes.
final class TruncationDetectingTextField: NSTextField {
    var onTruncationChanged: ((Bool) -> Void)?

    override func layout() {
        super.layout()
        let truncated = intrinsicContentSize.width > bounds.width + 1
        onTruncationChanged?(truncated)
    }
}
