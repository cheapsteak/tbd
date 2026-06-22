import AppKit
import Markdown

/// Converts a message's Markdown into an `NSAttributedString` for the TextKit 2
/// transcript. Pure: same input → same output, no view/layout state. (#129)
@MainActor
enum MarkdownAttributedRenderer {
    static func render(_ markdown: String, theme: TranscriptTextTheme = .chatBubble) -> NSAttributedString {
        let document = Document(parsing: markdown, options: [])
        var visitor = AttributedStringVisitor(theme: theme)
        let out = NSMutableAttributedString(attributedString: visitor.visit(document))
        let full = NSRange(location: 0, length: out.length)
        // Back-fill body font only onto runs that didn't set their own font
        // (preserves inline-code and heading fonts already applied per-run).
        out.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            if value == nil { out.addAttribute(.font, value: theme.bodyFont, range: range) }
        }
        // Back-fill body color only onto runs that didn't set their own color
        // (preserves link tint and inline-code color already applied per-run).
        out.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            if value == nil { out.addAttribute(.foregroundColor, value: theme.bodyColor, range: range) }
        }
        return out
    }
}

/// Walks the swift-markdown AST and appends styled runs. Only ever instantiated
/// and used on the main actor (inside `MarkdownAttributedRenderer.render`). (#129)
private struct AttributedStringVisitor: MarkupVisitor {
    typealias Result = NSAttributedString

    // nonisolated(unsafe): The visitor is only created/used on the main actor
    // inside MarkdownAttributedRenderer.render. NSFont/NSColor in TranscriptTextTheme
    // are not Sendable; this annotation suppresses the cross-isolation warning
    // while the actual usage is safe by construction.
    nonisolated(unsafe) let theme: TranscriptTextTheme

    mutating func defaultVisit(_ markup: Markup) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for child in markup.children {
            out.append(visit(child))
        }
        return out
    }

    mutating func visitText(_ text: Markdown.Text) -> NSAttributedString {
        NSAttributedString(string: text.string)
    }

    mutating func visitStrong(_ s: Strong) -> NSAttributedString { traited(s, .bold) }

    mutating func visitEmphasis(_ e: Emphasis) -> NSAttributedString { traited(e, .italic) }

    mutating func visitInlineCode(_ c: InlineCode) -> NSAttributedString {
        NSAttributedString(
            string: c.code,
            attributes: [
                .font: theme.inlineCodeFont,
                .foregroundColor: theme.inlineCodeColor
            ]
        )
    }

    mutating func visitLink(_ link: Markdown.Link) -> NSAttributedString {
        let inner = NSMutableAttributedString()
        for child in link.children { inner.append(visit(child)) }
        if let dest = link.destination, let url = URL(string: dest) {
            let range = NSRange(location: 0, length: inner.length)
            inner.addAttribute(.link, value: url, range: range)
            inner.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        }
        return inner
    }

    private mutating func traited(_ markup: any Markup, _ trait: NSFontDescriptor.SymbolicTraits) -> NSAttributedString {
        let inner = NSMutableAttributedString()
        for child in markup.children { inner.append(visit(child)) }
        let base = theme.bodyFont
        let desc = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(trait))
        let font = NSFont(descriptor: desc, size: base.pointSize) ?? base
        inner.addAttribute(.font, value: font, range: NSRange(location: 0, length: inner.length))
        return inner
    }
}
