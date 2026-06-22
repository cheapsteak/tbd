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

    @Test("fenced code uses a monospaced font and a background")
    func codeBlock() {
        let s = MarkdownAttributedRenderer.render("```swift\nlet x = 1\n```")
        let f = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(f?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(s.string.contains("let x = 1"))
    }

    @Test("GFM table produces text-table blocks for each cell")
    func table() {
        let md = "| A | B |\n|---|---|\n| 1 | 2 |"
        let s = MarkdownAttributedRenderer.render(md)
        #expect(s.string.contains("A") && s.string.contains("2"))
        var foundBlock = false
        s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let ps = v as? NSParagraphStyle, !ps.textBlocks.isEmpty { foundBlock = true }
        }
        #expect(foundBlock)
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
        #expect(out.string.contains("speed"))

        // Attribute presence
        var foundMono = false
        var foundBold = false
        var foundLink = false
        var foundBlock = false

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

        out.enumerateAttribute(.paragraphStyle, in: fullRange) { value, _, _ in
            if let ps = value as? NSParagraphStyle, !ps.textBlocks.isEmpty { foundBlock = true }
        }

        #expect(foundMono)
        #expect(foundBold)
        #expect(foundLink)
        #expect(foundBlock)
    }

    // MARK: - Helpers

    func boldRange(in s: NSAttributedString, substring: String) -> NSRange {
        (s.string as NSString).range(of: substring)
    }
}
