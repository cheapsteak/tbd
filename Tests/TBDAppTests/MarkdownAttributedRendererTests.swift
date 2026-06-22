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

    // MARK: - Helpers

    func boldRange(in s: NSAttributedString, substring: String) -> NSRange {
        (s.string as NSString).range(of: substring)
    }
}
