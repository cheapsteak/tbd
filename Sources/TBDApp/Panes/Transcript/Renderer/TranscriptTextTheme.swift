import AppKit

/// Visual spec for the TextKit transcript renderer — a value-type port of
/// `MarkdownUI.Theme.chatBubble` so the AppKit rendering matches the SwiftUI
/// look (#129). All values are copied from ChatBubbleView.swift's theme.
struct TranscriptTextTheme {
    let bodyFont: NSFont
    let bodyColor: NSColor
    let inlineCodeFont: NSFont
    let inlineCodeColor: NSColor
    let codeFont: NSFont
    let codeBackground: NSColor
    let blockquoteColor: NSColor
    let tableBorderColor: NSColor
    let tableHeaderBold: Bool
    let paragraphSpacing: CGFloat
    /// Tight vertical spacing BETWEEN list items, well under `paragraphSpacing`.
    /// Mirrors `ChatBubbleView`'s `.listItem { markdownMargin(top: .em(0.35)) }`
    /// so lists read tight like the SwiftUI transcript, not airy. (#129)
    let listItemSpacing: CGFloat
    let listIndent: CGFloat
    private let headingScale: [CGFloat]   // index 0 == h1

    func headingFont(level: Int) -> NSFont {
        let scale = headingScale[max(0, min(level - 1, headingScale.count - 1))]
        let size = bodyFont.pointSize * scale
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    @MainActor static let chatBubble: TranscriptTextTheme = {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let mono = NSFont.monospacedSystemFont(ofSize: body.pointSize * 0.92, weight: .regular)
        let code = NSFont.monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
        return TranscriptTextTheme(
            bodyFont: body,
            bodyColor: .labelColor,
            inlineCodeFont: mono,
            inlineCodeColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 172/255, green: 179/255, blue: 209/255, alpha: 1)
                    : NSColor(srgbRed: 82/255, green: 88/255, blue: 130/255, alpha: 1)
            },
            codeFont: code,
            codeBackground: NSColor.textBackgroundColor.withAlphaComponent(0.6),
            blockquoteColor: .secondaryLabelColor,
            tableBorderColor: NSColor.secondaryLabelColor.withAlphaComponent(0.3),
            tableHeaderBold: true,
            paragraphSpacing: 16,
            listItemSpacing: 4,
            listIndent: 24,
            headingScale: [1.4, 1.2, 1.05, 1.0, 1.0, 1.0]
        )
    }()
}
