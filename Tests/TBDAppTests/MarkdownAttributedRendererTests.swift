import Testing
import AppKit
@testable import TBDApp

@MainActor
@Suite("Markdown attributed renderer")
struct MarkdownAttributedRendererTests {
    @Test("plain prose renders its text")
    func plainProse() {
        let out = MarkdownAttributedRenderer.render("Hello world")
        #expect(out.string.contains("Hello world"))
    }

    @Test("theme exposes a body font and an inline-code monospaced font")
    func themeFonts() {
        let t = TranscriptTextTheme.chatBubble
        #expect(t.bodyFont.pointSize > 0)
        #expect(t.inlineCodeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        #expect(t.headingFont(level: 1).pointSize > t.bodyFont.pointSize)
    }

    @Test("bold text carries a bold font trait")
    func bold() {
        let s = MarkdownAttributedRenderer.render("a **b** c")
        let r = boldRange(in: s, substring: "b")
        let font = s.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test("link carries a .link attribute with the destination")
    func link() {
        let s = MarkdownAttributedRenderer.render("see [x](https://e.com)")
        let r = (s.string as NSString).range(of: "x")
        let link = s.attribute(.link, at: r.location, effectiveRange: nil)
        #expect((link as? URL)?.absoluteString == "https://e.com" || (link as? String) == "https://e.com")
    }

    @Test("inline code nested in bold keeps monospace AND gains the bold trait")
    func nestedCodeInBold() {
        let s = MarkdownAttributedRenderer.render("**a `c` b**")
        let r = (s.string as NSString).range(of: "c")
        let font = s.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
        let traits = font?.fontDescriptor.symbolicTraits
        #expect(traits?.contains(.monoSpace) == true)
        #expect(traits?.contains(.bold) == true)
    }

    @Test("h1 uses the heading font (larger, semibold)")
    func heading() {
        let s = MarkdownAttributedRenderer.render("# Title")
        let f = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect((f?.pointSize ?? 0) > TranscriptTextTheme.chatBubble.bodyFont.pointSize)
    }

    @Test("unordered list renders a bullet and the item text")
    func list() {
        let s = MarkdownAttributedRenderer.render("- one\n- two").string
        #expect(s.contains("one") && s.contains("two"))
        #expect(s.contains("•") || s.contains("-"))
    }

    @Test("blockquote keeps nested link color while coloring plain prose secondary")
    func blockquoteNestedColors() {
        let s = MarkdownAttributedRenderer.render("> see [x](https://e.com)")
        let ns = s.string as NSString
        // The link run keeps its link attribute AND linkColor (not blockquoteColor).
        let xRange = ns.range(of: "x")
        #expect(s.attribute(.link, at: xRange.location, effectiveRange: nil) != nil)
        let xColor = s.attribute(.foregroundColor, at: xRange.location, effectiveRange: nil) as? NSColor
        #expect(xColor == NSColor.linkColor)
        #expect(xColor != TranscriptTextTheme.chatBubble.blockquoteColor)
        // Plain prose in the blockquote gets the secondary blockquote color.
        let seeRange = ns.range(of: "see")
        let seeColor = s.attribute(.foregroundColor, at: seeRange.location, effectiveRange: nil) as? NSColor
        #expect(seeColor == TranscriptTextTheme.chatBubble.blockquoteColor)
    }

    @Test("fenced code renders plain monospaced and marks a language block for async highlight")
    func codeBlock() {
        let s = MarkdownAttributedRenderer.render("```swift\nlet x = 1\n```")
        let f = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        // Plain render: monospaced font + the literal code text survive. Syntax
        // highlighting is now applied asynchronously off the main thread (#129), so
        // the synchronous render carries NO highlight colors — only the marker.
        #expect(f?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(s.string.contains("let x = 1"))

        // A fenced block WITH a language carries the `.tbdCodeHighlight` marker
        // (value == the language) over its code characters.
        let codeRange = (s.string as NSString).range(of: "let x = 1")
        let marker = s.attribute(.tbdCodeHighlight, at: codeRange.location, effectiveRange: nil) as? String
        #expect(marker == "swift")
    }

    @Test("fenced code WITHOUT a language is plain and carries no async-highlight marker")
    func codeBlockNoLanguage() {
        let s = MarkdownAttributedRenderer.render("```\nplain text\n```")
        let f = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(f?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(s.string.contains("plain text"))
        // No language → stays plain forever → no marker anywhere.
        var foundMarker = false
        s.enumerateAttribute(.tbdCodeHighlight, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if v != nil { foundMarker = true }
        }
        #expect(!foundMarker)
    }

    @Test("GFM table becomes a single grid-view attachment carrying its cell text")
    func table() {
        // `NSTextTable` does not lay out under STTextView's TextKit 2; the table
        // is now rendered as ONE `TranscriptCardAttachment` hosting a SwiftUI
        // grid. The cell strings live inside the view, not the attributed string,
        // so we assert the attachment + its parsed table data instead. (#129)
        let md = "| A | B |\n|---|---|\n| 1 | 2 |"
        let s = MarkdownAttributedRenderer.render(md)

        var attachment: TranscriptCardAttachment?
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let a = v as? TranscriptCardAttachment { attachment = a }
        }
        #expect(attachment != nil)

        // No `NSTextTable` blocks remain in the attributed string.
        var foundBlock = false
        s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let ps = v as? NSParagraphStyle, !ps.textBlocks.isEmpty { foundBlock = true }
        }
        #expect(!foundBlock)

        // The parsed cell data round-trips header + body text through the shared
        // inline renderer.
        let data = parsedTableData(from: md)
        #expect(data.columnCount == 2)
        #expect(data.header.map(\.string) == ["A", "B"])
        #expect(data.rows.map { $0.map(\.string) } == [["1", "2"]])
    }

    @Test("table cells render inline markdown (bold survives)")
    func tableCellInlineMarkdown() {
        let md = "| **Bold** | code |\n|---|---|\n| `mono` | x |"
        let data = parsedTableData(from: md)
        // Header cell "**Bold**" keeps a bold-trait font.
        let headerFont = data.header[0].attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(headerFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        // Body cell "`mono`" keeps a monospaced inline-code font.
        let bodyFont = data.rows[0][0].attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(bodyFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    @Test("composite markdown renders heading, bold, link, list, code block, and table with expected attributes")
    func compositeMixed() {
        let md = """
        # Getting Started

        Use **swift** to install `Package`, see [docs](https://swift.org).

        - alpha
        - beta

        ```swift
        let result = compute()
        ```

        | Name  | Value |
        |-------|-------|
        | speed | 42    |
        """
        let out = MarkdownAttributedRenderer.render(md)
        #expect(out.length > 0)

        // Substring presence
        #expect(out.string.contains("Getting Started"))
        #expect(out.string.contains("swift"))
        #expect(out.string.contains("docs"))
        #expect(out.string.contains("alpha"))
        #expect(out.string.contains("result"))
        // Table cell text ("speed") now lives inside the grid-view attachment,
        // not the attributed string — assert it on the parsed table data instead.
        #expect(parsedTableData(from: md).rows.contains { $0.map(\.string).contains("speed") })

        // Attribute presence
        var foundMono = false
        var foundBold = false
        var foundLink = false
        var foundTableAttachment = false

        let fullRange = NSRange(location: 0, length: out.length)

        out.enumerateAttribute(.font, in: fullRange) { value, _, _ in
            guard let font = value as? NSFont else { return }
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.monoSpace) { foundMono = true }
            if traits.contains(.bold) { foundBold = true }
        }

        out.enumerateAttribute(.link, in: fullRange) { value, _, _ in
            if value != nil { foundLink = true }
        }

        out.enumerateAttribute(.attachment, in: fullRange) { value, _, _ in
            if value is TranscriptCardAttachment { foundTableAttachment = true }
        }

        #expect(foundMono)
        #expect(foundBold)
        #expect(foundLink)
        #expect(foundTableAttachment)
    }

    // MARK: - Block splitting (renderBlocks)

    @Test("renderBlocks: prose-only markdown is one prose block, no table block")
    func blocksProseOnly() {
        let blocks = MarkdownAttributedRenderer.renderBlocks("# Title\n\nSome **prose** text.")
        #expect(blocks.count == 1)
        guard case .prose(let s) = blocks[0] else {
            Issue.record("expected a single prose block")
            return
        }
        #expect(s.string.contains("Title"))
        #expect(s.string.contains("prose"))
    }

    @Test("renderBlocks: a single-paragraph prose block has no trailing newline (no dead bottom space)")
    func blocksProseTrimsTrailingNewline() {
        let blocks = MarkdownAttributedRenderer.renderBlocks("Some prose text.")
        #expect(blocks.count == 1)
        guard case .prose(let s) = blocks[0] else {
            Issue.record("expected a single prose block")
            return
        }
        // Block visitors append a paragraph-terminating "\n"; the prose finalizer
        // must trim it so `usedRect` doesn't count a phantom empty line. (#129)
        #expect(!s.string.hasSuffix("\n"))
        #expect(s.string.hasSuffix("."))

        // And the measured height is ~one line, not two: lay it out wide enough
        // that the text never wraps and compare against a plain single-line
        // reference rendered with the same body font. Without the trim the prose
        // would measure ~2x this (a phantom trailing empty line). (#129)
        let measurer = TranscriptBubbleMeasurer()
        let reference = NSAttributedString(
            string: "Some prose text.",
            attributes: [.font: TranscriptTextTheme.chatBubble.bodyFont]
        )
        let oneLine = measurer.textHeight(of: reference, width: 4000)
        let measured = measurer.textHeight(of: s, width: 4000)
        #expect(measured < oneLine * 1.6)
    }

    @Test("renderBlocks: a blockquote is separated from the next paragraph by a single newline, not a blank line")
    func blocksBlockquoteSingleTrailingNewline() {
        let blocks = MarkdownAttributedRenderer.renderBlocks("> quoted line\n\nNext paragraph.")
        #expect(blocks.count == 1)
        guard case .prose(let s) = blocks[0] else {
            Issue.record("expected a single prose block")
            return
        }
        // The blockquote's child paragraph appends its own "\n" and the blockquote
        // wrapper appended another, so the quote ended with "\n\n" — a blank line
        // before the following paragraph. It must now be a single line break.
        #expect(s.string.contains("quoted line\nNext paragraph"))
        #expect(!s.string.contains("quoted line\n\n"))
    }

    @Test("renderBlocks: a table becomes its own table block, splitting surrounding prose")
    func blocksProseTableProse() {
        let md = """
        Intro paragraph.

        | A | B |
        |---|---|
        | 1 | 2 |

        Trailing paragraph.
        """
        let blocks = MarkdownAttributedRenderer.renderBlocks(md)
        #expect(blocks.count == 3)
        guard case .prose(let lead) = blocks[0] else { Issue.record("block 0 not prose"); return }
        guard case .table(let data) = blocks[1] else { Issue.record("block 1 not table"); return }
        guard case .prose(let trail) = blocks[2] else { Issue.record("block 2 not prose"); return }
        #expect(lead.string.contains("Intro"))
        #expect(data.columnCount == 2)
        #expect(data.header.map(\.string) == ["A", "B"])
        #expect(trail.string.contains("Trailing"))
    }

    @Test("renderBlocks: code blocks and lists stay inside prose (not split out)")
    func blocksCodeAndListStayInProse() {
        let md = """
        ```swift
        let x = 1
        ```

        - one
        - two
        """
        let blocks = MarkdownAttributedRenderer.renderBlocks(md)
        // No table → all prose, grouped into one block.
        #expect(blocks.count == 1)
        guard case .prose(let s) = blocks[0] else { Issue.record("expected prose"); return }
        #expect(s.string.contains("let x = 1"))
        #expect(s.string.contains("one") && s.string.contains("two"))
        // Prose carries NO table attachment (tables are broken out as blocks).
        var hasAttachment = false
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if v != nil { hasAttachment = true }
        }
        #expect(!hasAttachment)
    }

    @Test("renderBlocks: two adjacent tables yield two table blocks")
    func blocksTwoTables() {
        let md = """
        | A | B |
        |---|---|
        | 1 | 2 |

        | C | D |
        |---|---|
        | 3 | 4 |
        """
        let blocks = MarkdownAttributedRenderer.renderBlocks(md)
        let tableCount = blocks.reduce(0) { if case .table = $1 { return $0 + 1 } else { return $0 } }
        #expect(tableCount == 2)
    }

    // MARK: - Helpers

    func boldRange(in s: NSAttributedString, substring: String) -> NSRange {
        (s.string as NSString).range(of: substring)
    }

    func parsedTableData(from markdown: String) -> TranscriptTableData {
        guard let data = MarkdownAttributedRenderer.tableData(forMarkdown: markdown) else {
            Issue.record("expected a table in markdown: \(markdown)")
            return TranscriptTableData(header: [], rows: [])
        }
        return data
    }
}
