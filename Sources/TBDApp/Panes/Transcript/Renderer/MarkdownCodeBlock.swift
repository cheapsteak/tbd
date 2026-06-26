import AppKit
import Highlightr

/// Renders a fenced code block as a syntax-highlighted `NSAttributedString`.
///
/// Highlightr wraps highlight.js and its init is expensive (~300 ms on first call
/// because it loads the full highlight.js runtime). A single `@MainActor` static
/// instance is cached so subsequent calls are fast. (#129)
@MainActor
enum MarkdownCodeBlock {
    private static let highlightr: Highlightr? = {
        let h = Highlightr()
        h?.setTheme(to: "xcode")
        return h
    }()

    /// Returns an `NSAttributedString` for the given fenced code block.
    ///
    /// - Colors come from Highlightr/highlight.js (syntax highlighting).
    /// - Font is always `theme.codeFont` (monospaced, project-size) — overrides
    ///   whatever font Highlightr set so we stay on the design system.
    /// - Background (`theme.codeBackground`) is applied as `.backgroundColor`.
    /// - A paragraph style with head/tail indent (8 pt) indents the block visually.
    static func attributed(code: String, language: String?, theme: TranscriptTextTheme) -> NSAttributedString {
        // Try syntax highlighting; fall back to plain monospaced if unavailable.
        let base: NSMutableAttributedString
        if let h = highlightr,
           let lang = language,
           let highlighted = h.highlight(code, as: lang) {
            base = NSMutableAttributedString(attributedString: highlighted)
        } else {
            base = NSMutableAttributedString(
                string: code,
                attributes: [.font: theme.codeFont]
            )
        }

        let full = NSRange(location: 0, length: base.length)

        // Override font: keep highlight COLORS but impose our mono font/size.
        base.enumerateAttribute(.font, in: full, options: []) { _, range, _ in
            base.addAttribute(.font, value: theme.codeFont, range: range)
        }

        // Apply code background across the entire block.
        base.addAttribute(.backgroundColor, value: theme.codeBackground, range: full)

        // Inset the block with a paragraph style.
        let style = NSMutableParagraphStyle()
        style.headIndent = 8
        style.tailIndent = -8
        style.firstLineHeadIndent = 8
        base.addAttribute(.paragraphStyle, value: style, range: full)

        // Append trailing newline to form a paragraph.
        base.append(NSAttributedString(string: "\n"))

        return base
    }
}
