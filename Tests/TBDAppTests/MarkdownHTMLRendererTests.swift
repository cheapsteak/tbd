import Testing
@testable import TBDApp

@Suite("MarkdownHTMLRenderer")
struct MarkdownHTMLRendererTests {

    @Test("renders headings and paragraphs")
    func rendersBasics() throws {
        let html = try #require(MarkdownHTMLRenderer.renderBody("# Title\n\nBody text."))
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<p>Body text.</p>"))
    }

    @Test("renders GFM tables")
    func rendersTables() throws {
        let html = try #require(MarkdownHTMLRenderer.renderBody("| a | b |\n|---|---|\n| 1 | 2 |"))
        #expect(html.contains("<table>"))
        #expect(html.contains("<th>a</th>"))
    }

    @Test("renders GitHub alerts, which cmark-gfm cannot")
    func rendersAlerts() throws {
        let html = try #require(MarkdownHTMLRenderer.renderBody("> [!NOTE]\n> Heads up."))
        #expect(html.contains("markdown-alert-note"))
    }

    @Test("renders task lists and strikethrough and autolinks")
    func rendersExtensions() throws {
        let html = try #require(MarkdownHTMLRenderer.renderBody(
            "- [x] done\n\n~~struck~~\n\nhttps://example.com"
        ))
        #expect(html.contains("type=\"checkbox\""))
        #expect(html.contains("<del>struck</del>"))
        #expect(html.contains("href=\"https://example.com\""))
    }

    // MARK: - Safe-mode invariants. These are the security contract; if any
    // of these fail, comrak's safe mode is off and an allowlist sanitizer is
    // required before this ships.

    @Test("clobbers raw HTML rather than emitting it")
    func clobbersRawHTML() throws {
        let html = try #require(MarkdownHTMLRenderer.renderBody(
            "<details><summary>x</summary>hidden</details>"
        ))
        #expect(html.contains("raw HTML omitted"))
        #expect(!html.contains("<details"))
        #expect(!html.contains("<summary"))
    }

    @Test("clobbers inline script tags")
    func clobbersScript() throws {
        let html = try #require(MarkdownHTMLRenderer.renderBody("<script>alert(1)</script>"))
        #expect(!html.contains("<script"))
    }

    @Test("empties javascript: link destinations")
    func stripsJavascriptURLs() throws {
        let html = try #require(MarkdownHTMLRenderer.renderBody("[bad](javascript:alert(1))"))
        #expect(!html.lowercased().contains("javascript:"))
    }

    @Test("link destinations cannot break out of the href attribute")
    func noAttributeInjection() throws {
        let html = try #require(MarkdownHTMLRenderer.renderBody(
            #"[x](<" onmouseover="alert(1)>)"#
        ))
        // Whitelist the exact composed output rather than asserting the absence
        // of a scary substring. comrak percent-encodes the quote (" -> %22), so
        // the whole destination stays inside the href value, inert. A
        // !contains("onmouseover") check would be a blacklist: it fires on this
        // safely-encoded text while a genuine breakout that spelled the handler
        // differently would sail past it.
        #expect(html.contains(#"<a href="%22%20onmouseover=%22alert(1)">x</a>"#))

        // Structural invariant, independent of the fixture's spelling: a
        // breakout would give the anchor a second attribute, and every
        // attribute contributes exactly one `="` sequence.
        let anchor = try #require(html.range(of: "<a ").map { r in
            String(html[r.lowerBound..<(html.range(of: ">", range: r.lowerBound..<html.endIndex)?.upperBound ?? html.endIndex)])
        })
        #expect(anchor.components(separatedBy: #"=""#).count - 1 == 1)
    }

    @Test("the breakout guard actually detects a breakout")
    func breakoutGuardIsNotVacuous() {
        // Mutation check: the same structural assertion must FAIL on a string
        // where an attribute really did escape. A guard that cannot fail is
        // not a guard.
        let brokenOut = #"<a href="" onmouseover="alert(1)">x</a>"#
        let anchor = String(brokenOut[brokenOut.startIndex..<brokenOut.range(of: ">")!.upperBound])
        #expect(anchor.components(separatedBy: #"=""#).count - 1 == 2)
    }

    @Test("returns nil for input containing an embedded NUL")
    func rejectsEmbeddedNUL() {
        #expect(MarkdownHTMLRenderer.renderBody("before\u{0}after") == nil)
    }

    @Test("handles empty input")
    func handlesEmpty() throws {
        let html = try #require(MarkdownHTMLRenderer.renderBody(""))
        #expect(html.isEmpty)
    }
}
