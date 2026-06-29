import AppKit

extension NSAttributedString.Key {
    /// Marks a fenced code-block run (range == the block's code characters) that
    /// SHOULD be syntax-highlighted later, off the main thread. Its value is the
    /// language `String`. Present only when the block declared a language; a
    /// language-less block stays plain forever and carries no marker. (#129)
    static let tbdCodeHighlight = NSAttributedString.Key("tbdCodeHighlight")
}

/// Renders a fenced code block as a PLAIN monospaced `NSAttributedString`.
///
/// Syntax highlighting (JavaScriptCore / highlight.js) is intentionally NOT done
/// here: doing it synchronously on the main thread — in height measurement and
/// first paint — caused a hard freeze (the lazy JSCore VM init can stall tens of
/// seconds under memory pressure). Instead this renders plain text and, when the
/// block has a language, attaches a `.tbdCodeHighlight` marker over the code range
/// so the cell can colorize it asynchronously via `CodeHighlightService`. Because
/// the font (`theme.codeFont`) is fixed here and the async pass only adds
/// `.foregroundColor`, layout/height never changes — `render == measure` holds. (#129)
@MainActor
enum MarkdownCodeBlock {
    /// Returns a PLAIN monospaced `NSAttributedString` for the given fenced code block.
    ///
    /// - Font is `theme.codeFont` (monospaced, project-size).
    /// - Background (`theme.codeBackground`) is applied as `.backgroundColor`.
    /// - A paragraph style with head/tail indent (8 pt) indents the block visually.
    /// - When `language != nil`, a `.tbdCodeHighlight` marker (value = the language)
    ///   is attached over the code's characters so the cell can highlight it later.
    static func attributed(code: String, language: String?, theme: TranscriptTextTheme) -> NSAttributedString {
        let base = NSMutableAttributedString(
            string: code,
            attributes: [.font: theme.codeFont]
        )

        let full = NSRange(location: 0, length: base.length)

        // Apply code background across the entire block.
        base.addAttribute(.backgroundColor, value: theme.codeBackground, range: full)

        // Mark the code range for async syntax highlighting — only when a language
        // is present (matches the old "highlight only when language present"
        // behavior; language-less blocks stay plain forever).
        if let language, full.length > 0 {
            base.addAttribute(.tbdCodeHighlight, value: language, range: full)
        }

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
