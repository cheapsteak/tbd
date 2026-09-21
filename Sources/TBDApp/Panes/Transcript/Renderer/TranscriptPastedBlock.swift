import AppKit

/// Renders a terminal paste from a user prompt (see `TranscriptPastedContent`)
/// as one prose block: a small "pasted" caption line, then the pasted text set
/// exactly like a language-less fenced code block — monospaced, on the code
/// background, inset, and never parsed as markdown.
///
/// It is a `.prose` block rather than a new block kind so it lays out and
/// measures on TextKit 1 like every other prose block: `render == measure`
/// holds by construction. The row-height estimator in `TableTranscriptView`
/// reads the constants below so its arithmetic describes the same layout.
///
/// Shown in full: transcript rows have no inline expand/collapse (see
/// `Sources/TBDApp/Panes/Transcript/CLAUDE.md`).
@MainActor
enum TranscriptPastedBlock {
    /// The caption drawn above the pasted text.
    nonisolated static let caption = "pasted"

    /// Caption face — the small system size, so the label reads as chrome
    /// rather than as part of the message.
    static let captionFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    /// Paragraph spacing between the caption and the pasted text.
    static let captionSpacing: CGFloat = 2

    /// Head indent of the caption, matching `MarkdownCodeBlock`'s 8 pt inset so
    /// the caption lines up with the text it labels.
    static let inset: CGFloat = 8

    /// The block's unfinalized attributed text: the caption paragraph followed by
    /// `MarkdownCodeBlock.attributed(code:language:nil:)` for the body. The caller
    /// runs the same finalization every prose block gets (body-color back-fill,
    /// link pass, trailing-newline trim); the body keeps `.tbdCodeContext`, so a
    /// path in a paste becomes a link that underlines like one in a code block.
    static func attributed(_ text: String, theme: TranscriptTextTheme) -> NSMutableAttributedString {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = inset
        style.headIndent = inset
        style.paragraphSpacing = captionSpacing
        let out = NSMutableAttributedString(
            string: caption + "\n",
            attributes: [
                .font: captionFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style
            ])
        out.append(MarkdownCodeBlock.attributed(code: text, language: nil, theme: theme))
        return out
    }
}
