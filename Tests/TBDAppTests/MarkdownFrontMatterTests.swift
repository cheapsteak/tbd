import Testing
@testable import TBDApp

@Suite("MarkdownFrontMatter")
struct MarkdownFrontMatterTests {

    private typealias Entry = MarkdownFrontMatter.Entry

    // MARK: - Finding the block

    @Test("splits a leading block off and keeps the body after the closing line")
    func splitsFrontMatter() throws {
        let source = "---\ntitle: Acme widgets\nslug: acme-widgets\n---\n\n# Widgets\n"
        let (frontMatter, body) = MarkdownFrontMatter.split(source)
        let block = try #require(frontMatter)
        #expect(block.yaml == "title: Acme widgets\nslug: acme-widgets")
        #expect(block.entries == [
            Entry(key: "title", value: "Acme widgets", continuation: nil),
            Entry(key: "slug", value: "acme-widgets", continuation: nil),
        ])
        #expect(body == "\n# Widgets\n")
    }

    @Test("leaves a source without front matter unchanged")
    func noFrontMatter() {
        let source = "# Widgets\n\ntitle: not front matter\n"
        let (frontMatter, body) = MarkdownFrontMatter.split(source)
        #expect(frontMatter == nil)
        #expect(body == source)
    }

    @Test("an opening --- with no closing line is not front matter")
    func unclosedIsUnchanged() {
        let source = "---\ntitle: Acme\n\n# Widgets\n"
        let (frontMatter, body) = MarkdownFrontMatter.split(source)
        #expect(frontMatter == nil)
        #expect(body == source)
    }

    @Test("a --- line alone is not front matter")
    func loneOpeningLine() {
        let (frontMatter, body) = MarkdownFrontMatter.split("---")
        #expect(frontMatter == nil)
        #expect(body == "---")
    }

    @Test("... closes the block too")
    func dotsClose() throws {
        let (frontMatter, body) = MarkdownFrontMatter.split("---\nlayer: example\n...\nBody text.")
        let block = try #require(frontMatter)
        #expect(block.yaml == "layer: example")
        #expect(body == "Body text.")
    }

    @Test("... does not open a block")
    func dotsDoNotOpen() {
        let source = "...\nlayer: example\n...\nBody text."
        #expect(MarkdownFrontMatter.split(source).frontMatter == nil)
    }

    @Test("allows a leading UTF-8 BOM and trailing whitespace on the delimiters")
    func bomAndTrailingWhitespace() throws {
        let (frontMatter, body) = MarkdownFrontMatter.split("\u{FEFF}--- \t\ntitle: Acme\n---  \nBody")
        let block = try #require(frontMatter)
        #expect(block.yaml == "title: Acme")
        #expect(body == "Body")
    }

    @Test("handles CRLF line endings")
    func crlf() throws {
        let source = "---\r\ntitle: Acme\r\nupdated: 2026-01-01\r\n---\r\n# Widgets\r\n"
        let (frontMatter, body) = MarkdownFrontMatter.split(source)
        let block = try #require(frontMatter)
        #expect(block.yaml == "title: Acme\nupdated: 2026-01-01")
        #expect(block.entries == [
            Entry(key: "title", value: "Acme", continuation: nil),
            Entry(key: "updated", value: "2026-01-01", continuation: nil),
        ])
        #expect(body == "# Widgets\r\n")
    }

    @Test("a thematic break after the first line is never front matter")
    func laterThematicBreak() {
        let source = "# Widgets\n\n---\ntitle: Acme\n---\n"
        let (frontMatter, body) = MarkdownFrontMatter.split(source)
        #expect(frontMatter == nil)
        #expect(body == source)
    }

    @Test("a blank line before the opening --- means there is no front matter")
    func leadingBlankLine() {
        let source = "\n---\ntitle: Acme\n---\n"
        #expect(MarkdownFrontMatter.split(source).frontMatter == nil)
    }

    @Test("the delimiter must be exactly three dashes at column 0")
    func delimiterIsExact() {
        #expect(MarkdownFrontMatter.split("----\na: b\n----\n").frontMatter == nil)
        #expect(MarkdownFrontMatter.split(" ---\na: b\n---\n").frontMatter == nil)
    }

    // MARK: - Reading it as keys

    @Test("an empty value and [] are kept as written, and a URL value does not split the key")
    func scalarValues() throws {
        let source = "---\nowner:\nsources: []\nhomepage: https://example.com/a:b\ntitle: Acme: the plan\n---\n"
        let block = try #require(MarkdownFrontMatter.split(source).frontMatter)
        #expect(block.entries == [
            Entry(key: "owner", value: "", continuation: nil),
            Entry(key: "sources", value: "[]", continuation: nil),
            Entry(key: "homepage", value: "https://example.com/a:b", continuation: nil),
            Entry(key: "title", value: "Acme: the plan", continuation: nil),
        ])
    }

    @Test("indented lines, a compact list and a block scalar stay under their key")
    func continuationLines() throws {
        let source = """
        ---
        tags:
          - widgets
          - pipeline
        author:
          name: Acme
          email: dev@example.com
        summary: >-
          First line.

          Second paragraph.
        compact:
        - one
        - two

        updated: 2026-01-01
        ---
        """
        let block = try #require(MarkdownFrontMatter.split(source).frontMatter)
        #expect(block.entries == [
            Entry(key: "tags", value: "", continuation: "- widgets\n- pipeline"),
            Entry(key: "author", value: "", continuation: "name: Acme\nemail: dev@example.com"),
            Entry(key: "summary", value: "", continuation: "First line.\n\nSecond paragraph."),
            Entry(key: "compact", value: "", continuation: "- one\n- two"),
            Entry(key: "updated", value: "2026-01-01", continuation: nil),
        ])
    }

    @Test("a block that is not top-level keys has no entries")
    func unreadableBlock() throws {
        let comment = try #require(MarkdownFrontMatter.split("---\n# note\ntitle: Acme\n---\n").frontMatter)
        #expect(comment.entries == nil)
        let list = try #require(MarkdownFrontMatter.split("---\n- one\n- two\n---\n").frontMatter)
        #expect(list.entries == nil)
        let stray = try #require(MarkdownFrontMatter.split("---\ntitle: Acme\njust text\n---\n").frontMatter)
        #expect(stray.entries == nil)
    }

    // MARK: - HTML

    @Test("html is a key/value list")
    func htmlShape() throws {
        let block = try #require(MarkdownFrontMatter.split("---\ntitle: Acme\nsources: []\nowner:\n---\n").frontMatter)
        #expect(block.html == #"<dl class="tbd-front-matter"><dt>title</dt><dd>Acme</dd>"#
            + #"<dt>sources</dt><dd>[]</dd><dt>owner</dt><dd></dd></dl>"#)
    }

    @Test("html keeps a nested value visible, preformatted under its key")
    func htmlNestedValue() throws {
        let block = try #require(MarkdownFrontMatter.split("---\ntags:\n  - widgets\n  - pipeline\n---\n").frontMatter)
        #expect(block.html == #"<dl class="tbd-front-matter"><dt>tags</dt><dd><pre>- widgets"#
            + "\n" + "- pipeline</pre></dd></dl>")
    }

    @Test("html shows an unreadable block whole, as raw YAML")
    func htmlFallback() throws {
        let block = try #require(MarkdownFrontMatter.split("---\n- one\n- two\n---\n").frontMatter)
        #expect(block.html == #"<pre class="tbd-front-matter">- one"# + "\n" + "- two</pre>")
    }

    @Test("an empty block renders nothing")
    func htmlEmptyBlock() throws {
        let block = try #require(MarkdownFrontMatter.split("---\n---\nBody").frontMatter)
        #expect(block.entries == [])
        #expect(block.html == "")
    }

    @Test("html escapes markup in keys, values and continuation lines")
    func htmlEscapes() throws {
        let source = """
        ---
        title: <script>alert('x') & "y"</script>
        <b>key</b>: v
        notes:
          - <img src=x onerror=alert(1)>
        ---
        """
        let html = try #require(MarkdownFrontMatter.split(source).frontMatter).html
        #expect(!html.contains("<script"))
        #expect(!html.contains("<b>"))
        #expect(!html.contains("<img"))
        #expect(html.contains("<dd>&lt;script&gt;alert(&#39;x&#39;) &amp; &quot;y&quot;&lt;/script&gt;</dd>"))
        #expect(html.contains("<dt>&lt;b&gt;key&lt;/b&gt;</dt>"))
        #expect(html.contains("<pre>- &lt;img src=x onerror=alert(1)&gt;</pre>"))
    }

    @Test("the raw-YAML fallback is escaped too")
    func htmlFallbackEscapes() throws {
        let block = try #require(MarkdownFrontMatter.split("---\n# <script>alert(1)</script>\n---\n").frontMatter)
        #expect(block.html == #"<pre class="tbd-front-matter"># &lt;script&gt;alert(1)&lt;/script&gt;</pre>"#)
    }
}
