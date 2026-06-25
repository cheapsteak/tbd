import AppKit
import Markdown
import SwiftUI

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

    /// Parses `markdown` and returns the `TranscriptTableData` for its first GFM
    /// table (cells rendered through the same inline visitor as `render`), or
    /// `nil` if there is no table. Test seam for asserting the attachment-based
    /// table path without reaching into the private visitor. (#129)
    static func tableData(forMarkdown markdown: String, theme: TranscriptTextTheme = .chatBubble) -> TranscriptTableData? {
        let document = Document(parsing: markdown, options: [])
        var visitor = AttributedStringVisitor(theme: theme)
        for child in document.children {
            if let table = child as? Markdown.Table {
                return MarkdownTable.data(table, theme: theme, render: { visitor.visit($0) })
            }
        }
        return nil
    }

    /// Splits `markdown` into an ordered list of typed `MessageBlock`s: runs of
    /// consecutive non-table top-level blocks are rendered into one `.prose`
    /// `NSAttributedString` each (via the SAME visitor logic as `render`), and a
    /// `Table` node becomes a `.table` block carrying its `TranscriptTableData`.
    ///
    /// Unlike `render`, prose is rendered WITHOUT touching TextKit-2 attachments —
    /// tables are broken out as native blocks instead — so the bubble cell can lay
    /// prose out on TextKit 1 (fast, exact `usedRect`) and host the table as its
    /// own view. Code blocks, lists, blockquotes, paragraphs, and headings all
    /// stay inside prose with unchanged inline rendering. (#129)
    static func renderBlocks(_ markdown: String, theme: TranscriptTextTheme = .chatBubble) -> [MessageBlock] {
        let document = Document(parsing: markdown, options: [])
        var visitor = AttributedStringVisitor(theme: theme)
        var blocks: [MessageBlock] = []
        var proseRun = NSMutableAttributedString()

        func flushProse() {
            guard proseRun.length > 0 else { return }
            blocks.append(.prose(finalizedProse(proseRun, theme: theme)))
            proseRun = NSMutableAttributedString()
        }

        for child in document.children {
            if let table = child as? Markdown.Table {
                flushProse()
                let data = MarkdownTable.data(table, theme: theme, render: { visitor.visit($0) })
                if data.columnCount > 0 { blocks.append(.table(data)) }
            } else {
                proseRun.append(visitor.visit(child))
            }
        }
        flushProse()
        return blocks
    }

    /// Back-fills body font/color onto runs that didn't set their own — the same
    /// finalization `render` applies, factored out so `renderBlocks` produces
    /// identically-styled prose. Returns an immutable copy.
    private static func finalizedProse(_ run: NSMutableAttributedString, theme: TranscriptTextTheme) -> NSAttributedString {
        let full = NSRange(location: 0, length: run.length)
        run.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            if value == nil { run.addAttribute(.font, value: theme.bodyFont, range: range) }
        }
        run.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            if value == nil { run.addAttribute(.foregroundColor, value: theme.bodyColor, range: range) }
        }
        // Block visitors append a trailing "\n" (paragraph terminator), so the
        // prose ends with a hard line break that `usedRect` counts as an extra
        // empty line fragment — ~one line of dead space at the bottom of every
        // block. Trim the trailing run of newlines/whitespace so the prose ends
        // at its last visible glyph. Guard the all-whitespace/empty case so we
        // never delete an empty range. (#129)
        let whitespace = CharacterSet.whitespacesAndNewlines
        let ns = run.string as NSString
        var end = ns.length
        while end > 0,
              let scalar = Unicode.Scalar(ns.character(at: end - 1)),
              whitespace.contains(scalar) {
            end -= 1
        }
        if end < ns.length {
            run.deleteCharacters(in: NSRange(location: end, length: ns.length - end))
        }
        return NSAttributedString(attributedString: run)
    }
}

/// One typed segment of a chat message: either a run of prose (rendered markdown
/// as an `NSAttributedString`, laid out on TextKit 1) or a GFM table (its parsed
/// cell data, rendered as a native grid view). A message is an ordered list of
/// these, stacked vertically inside one bubble. (#129)
enum MessageBlock {
    case prose(NSAttributedString)
    case table(TranscriptTableData)
}

/// Walks the swift-markdown AST and appends styled runs. Only ever instantiated
/// and used on the main actor (inside `MarkdownAttributedRenderer.render`). (#129)
///
/// `@MainActor` keeps theme access (non-Sendable `NSFont`/`NSColor`) compiler-checked.
/// The `@preconcurrency` on the `MarkupVisitor` conformance reconciles the nonisolated
/// protocol requirements with this struct's main-actor isolation.
@MainActor
private struct AttributedStringVisitor {
    typealias Result = NSAttributedString

    let theme: TranscriptTextTheme
}

extension AttributedStringVisitor: @preconcurrency MarkupVisitor {
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

    // MARK: - Block visitors

    mutating func visitParagraph(_ p: Paragraph) -> NSAttributedString {
        let inner = NSMutableAttributedString()
        for child in p.children { inner.append(visit(child)) }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = theme.paragraphSpacing
        return paragraph(inner, style: style)
    }

    mutating func visitHeading(_ h: Heading) -> NSAttributedString {
        let inner = NSMutableAttributedString()
        for child in h.children { inner.append(visit(child)) }
        let headFont = theme.headingFont(level: h.level)
        let full = NSRange(location: 0, length: inner.length)
        inner.addAttribute(.font, value: headFont, range: full)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = theme.paragraphSpacing
        return paragraph(inner, style: style)
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for child in list.children { out.append(visit(child)) }
        return out
    }

    mutating func visitOrderedList(_ list: OrderedList) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var counter = Int(list.startIndex)
        for child in list.children {
            if let item = child as? ListItem {
                out.append(visitListItem(item, marker: "\(counter). "))
                counter += 1
            } else {
                out.append(visit(child))
            }
        }
        return out
    }

    mutating func visitListItem(_ item: ListItem) -> NSAttributedString {
        visitListItem(item, marker: "• ")
    }

    mutating func visitBlockQuote(_ b: BlockQuote) -> NSAttributedString {
        let inner = NSMutableAttributedString()
        for child in b.children { inner.append(visit(child)) }
        // Color only runs that didn't set their own foreground color, so nested
        // links keep linkColor and inline-code keeps its tint (mirrors the
        // render-level body-color back-fill). Blanket-coloring would clobber them.
        let full = NSRange(location: 0, length: inner.length)
        inner.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            if value == nil { inner.addAttribute(.foregroundColor, value: theme.blockquoteColor, range: range) }
        }
        let style = NSMutableParagraphStyle()
        style.headIndent = theme.listIndent
        style.firstLineHeadIndent = theme.listIndent
        style.paragraphSpacing = theme.paragraphSpacing
        return paragraph(inner, style: style)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSAttributedString {
        MarkdownCodeBlock.attributed(
            code: codeBlock.code,
            language: codeBlock.language,
            theme: theme
        )
    }

    mutating func visitTable(_ table: Markdown.Table) -> NSAttributedString {
        // `NSTextTable` is a TextKit 1 construct that STTextView's TextKit 2
        // layout flattens into a vertical cell list. Instead emit the whole
        // table as ONE view attachment hosting a real SwiftUI grid. (#129)
        let data = MarkdownTable.data(table, theme: theme, render: { self.visit($0) })
        guard data.columnCount > 0 else { return NSAttributedString() }
        let tableView = TranscriptTableView(
            data: data,
            borderColor: Color(theme.tableBorderColor)
        )
        // A stable-ish ID from the table's source range keeps the attachment
        // correlatable across streaming rebuilds without needing a render node.
        let nodeID = "table-\(table.range?.lowerBound.line ?? 0)-\(table.range?.lowerBound.column ?? 0)"
        let attachment = TranscriptCardAttachment(nodeID: nodeID, card: AnyView(tableView))
        let out = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        out.append(NSAttributedString(string: "\n"))
        return out
    }

    mutating func visitThematicBreak(_ b: ThematicBreak) -> NSAttributedString {
        let rule = NSMutableAttributedString(string: "————————")
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = theme.paragraphSpacing
        style.alignment = .center
        return paragraph(rule, style: style)
    }

    // MARK: - Block helper

    /// Applies `style` to all of `inner` and appends a newline. `NSMutableAttributedString`
    /// is a reference type, so this is safe to call without `inout`.
    private func paragraph(_ inner: NSMutableAttributedString, style: NSMutableParagraphStyle) -> NSAttributedString {
        let full = NSRange(location: 0, length: inner.length)
        inner.addAttribute(.paragraphStyle, value: style, range: full)
        inner.append(NSAttributedString(string: "\n"))
        return inner
    }

    private mutating func visitListItem(_ item: ListItem, marker: String) -> NSAttributedString {
        let inner = NSMutableAttributedString(string: marker)
        // Render the item's content INLINE rather than via `visit(child)`. A
        // list item's text is wrapped by swift-markdown in a `Paragraph`, and
        // `visitParagraph` stamps the full 16pt inter-paragraph spacing plus a
        // trailing newline onto it — so visiting children directly produced a
        // double paragraph break and an airy ~16pt gap between every list item
        // (issue #129). Pulling the inline children out keeps items tight.
        for child in item.children {
            if let paragraph = child as? Paragraph {
                for inline in paragraph.children { inner.append(visit(inline)) }
            } else {
                inner.append(visit(child))
            }
        }
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = theme.listIndent
        // Tight inter-item spacing to match the SwiftUI list (`markdownMargin
        // top: .em(0.35)`), not the full inter-paragraph spacing.
        style.paragraphSpacing = theme.listItemSpacing
        return paragraph(inner, style: style)
    }

    // MARK: - Inline helpers

    private mutating func traited(_ markup: any Markup, _ trait: NSFontDescriptor.SymbolicTraits) -> NSAttributedString {
        let inner = NSMutableAttributedString()
        for child in markup.children { inner.append(visit(child)) }
        // Merge the trait into each run's EXISTING font rather than blanket-replacing,
        // so nested inline-code (monospace) inside bold/italic keeps its monospace face
        // AND gains the bold/italic trait. Runs with no font yet get the body font + trait.
        let full = NSRange(location: 0, length: inner.length)
        inner.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            let base = (value as? NSFont) ?? theme.bodyFont
            let desc = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(trait))
            let font = NSFont(descriptor: desc, size: base.pointSize) ?? base
            inner.addAttribute(.font, value: font, range: range)
        }
        return inner
    }
}
