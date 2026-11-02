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

    @Test("... closes only a block that reads cleanly as keys")
    func dotsCloseOnlyCleanBlocks() {
        let source = "---\nNote: draft\nMore thoughts\n...\n\n# Title"
        let (frontMatter, body) = MarkdownFrontMatter.split(source)
        #expect(frontMatter == nil)
        #expect(body == source)
    }

    @Test("after a first ... fails, later ... lines never close the block")
    func onlyTheFirstDotsIsTried() throws {
        // The shape that was quadratic: many key lines, then `x`, so reading
        // the block walks every key before it fails, then many `...` lines.
        // The first `...` fails, and every later one must be skipped rather
        // than re-read the whole block.
        // This pins the correct result for that shape; it cannot by itself
        // detect a speed regression.
        let keys = (1...2000).map { "k\($0): v" }.joined(separator: "\n")
        let dots = Array(repeating: "...", count: 2000).joined(separator: "\n")
        let block = keys + "\nx\n" + dots
        let unclosed = "---\n" + block + "\nBody"
        let (none, unchanged) = MarkdownFrontMatter.split(unclosed)
        #expect(none == nil)
        #expect(unchanged == unclosed)

        // A `---` after them still closes it, as raw YAML that keeps every line.
        let closed = "---\n" + block + "\n---\nBody"
        let (frontMatter, body) = MarkdownFrontMatter.split(closed)
        let parsed = try #require(frontMatter)
        #expect(parsed.entries == nil)
        #expect(parsed.yaml == block)
        #expect(body == "Body")
    }

    @Test("... does not close an empty block, so the rule and the dots stay")
    func dotsDoNotCloseAnEmptyBlock() {
        let source = "---\n...\nBody"
        let (frontMatter, body) = MarkdownFrontMatter.split(source)
        #expect(frontMatter == nil)
        #expect(body == source)
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

    @Test("a blank line after the opening --- means a thematic break, not front matter")
    func openingThematicBreak() {
        for source in [
            "---\n\n# Intro\n\nSome *text*\n\n---\n\nMore",
            "---\n  \t\ntitle: Acme\n---\n",
        ] {
            let (frontMatter, body) = MarkdownFrontMatter.split(source)
            #expect(frontMatter == nil)
            #expect(body == source)
        }
    }

    @Test("a block that does not open with a key: line is a rule, a banner or a heading")
    func noKeyLines() {
        for source in [
            "---\n# Intro\n\nSome *text*\n\n---\n\nMore",
            "---\n**DEPRECATED** — see the new docs.\n---\n\n# Project",
            "---\n- one\n- two\n---\n",
            "---\n# Project Title\n\nSome description.\n\nNote: this requires Node 18.\n\n---\n\n## Next",
            "---\n# only a comment\n---\n",
        ] {
            let (frontMatter, body) = MarkdownFrontMatter.split(source)
            #expect(frontMatter == nil)
            #expect(body == source)
        }
    }

    @Test("a --- inside a fenced code block never closes a block, even one with a key")
    func fencedCloser() {
        for source in [
            "---\ntitle: Acme\nSetup notes for the widget service.\n\n```yaml\n---\nname: acme\n```\n\nMore text.\n",
            "---\ntitle: Acme\n~~~\n---\n~~~\n",
            "---\ntitle: Acme\nSetup notes.\n\n   ```yaml\n---\nname: acme\n   ```\n",
        ] {
            let (frontMatter, body) = MarkdownFrontMatter.split(source)
            #expect(frontMatter == nil)
            #expect(body == source)
        }
    }

    @Test("markdown syntax at the start of a line is never a key")
    func markdownSyntaxIsNotAKey() {
        for source in [
            "---\n> Note: this page moved to docs/new.md\n---\n# Title",
            "---\n*Status*: draft\n---\n# Title",
            "---\n| Owner: | me |\n---\n# Title",
            "---\n`code`: x\n---\n# Title",
            "---\n1. Install: run make\n2. Test: run make test\n---\n# Title",
            "---\n+ Owner: me\n---\n# Title",
            "---\n1) Step: x\n---\n# Title",
        ] {
            let (frontMatter, body) = MarkdownFrontMatter.split(source)
            #expect(frontMatter == nil)
            #expect(body == source)
        }
    }

    @Test("keys that only look like list markers are still keys")
    func listMarkerLookalikesAreKeys() throws {
        let block = try #require(
            MarkdownFrontMatter.split("---\n_build: list\n2026: year\n1.5: ratio\n+x: plus\n---\n").frontMatter
        )
        let keys = block.entries?.map(\.key)
        #expect(keys == ["_build", "2026", "1.5", "+x"])
    }

    @Test("an indented fence inside a block scalar is the scalar's text, not markdown")
    func fenceInsideBlockScalar() throws {
        let source = "---\ntitle: Acme\nexample: |\n  ```sh\n  make\n  ```\n---\nBody"
        let (frontMatter, body) = MarkdownFrontMatter.split(source)
        let block = try #require(frontMatter)
        #expect(block.entries == [
            Entry(key: "title", value: "Acme", continuation: nil),
            Entry(key: "example", value: "", continuation: "```sh\nmake\n```"),
        ])
        #expect(body == "Body")
    }

    @Test("four spaces of indent is not a fence, so the block still splits")
    func indentedBackticksAreNotAFence() throws {
        let (frontMatter, body) = MarkdownFrontMatter.split("---\ntitle: Acme\nnotes: |\n    ```sh\n---\nBody")
        let block = try #require(frontMatter)
        #expect(block.entries == [
            Entry(key: "title", value: "Acme", continuation: nil),
            Entry(key: "notes", value: "", continuation: "```sh"),
        ])
        #expect(body == "Body")
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

    @Test("a block scalar indicator is not shown as the value, even with no lines after it")
    func emptyBlockScalar() throws {
        let block = try #require(MarkdownFrontMatter.split("---\nnotes: |\nsummary: >-\nupdated: 2026-01-01\n---\n").frontMatter)
        #expect(block.entries == [
            Entry(key: "notes", value: "", continuation: nil),
            Entry(key: "summary", value: "", continuation: nil),
            Entry(key: "updated", value: "2026-01-01", continuation: nil),
        ])
        #expect(block.html.contains("<dt>notes</dt><dd></dd>"))
    }

    @Test("a plain value that wraps onto indented lines is folded into one value")
    func foldedPlainScalar() throws {
        let source = """
        ---
        summary: A long summary that
          wraps onto a second line
        description: First paragraph
          that wraps.

          Second paragraph.
        tags: acme
          - not folded
        updated: 2026-01-01
        ---
        """
        let block = try #require(MarkdownFrontMatter.split(source).frontMatter)
        #expect(block.entries == [
            Entry(key: "summary", value: "A long summary that wraps onto a second line", continuation: nil),
            Entry(key: "description", value: "First paragraph that wraps.\nSecond paragraph.", continuation: nil),
            Entry(key: "tags", value: "acme", continuation: "- not folded"),
            Entry(key: "updated", value: "2026-01-01", continuation: nil),
        ])
        let html = block.html
        #expect(html.contains("<dt>summary</dt><dd>A long summary that wraps onto a second line</dd>"))
        #expect(html.contains(
            "<dt>description</dt><dd><p>First paragraph that wraps.</p><p>Second paragraph.</p></dd>"
        ))
        #expect(html.contains("<dt>tags</dt><dd>acme<pre>- not folded</pre></dd>"))
    }

    @Test("a nested map under a valued key keeps its lines")
    func nestedMapIsNotFolded() throws {
        let block = try #require(MarkdownFrontMatter.split("---\nowner: acme\n  team: widgets\n---\n").frontMatter)
        #expect(block.entries == [Entry(key: "owner", value: "acme", continuation: "team: widgets")])
    }

    @Test("a comment after a block scalar indicator is dropped with it; one after a value is kept")
    func blockScalarIndicatorComment() throws {
        let source = "---\nnotes: | # free text\n  line one\nsummary: >- #short\ntitle: Acme # draft\n---\n"
        let block = try #require(MarkdownFrontMatter.split(source).frontMatter)
        #expect(block.entries == [
            Entry(key: "notes", value: "", continuation: "line one"),
            Entry(key: "summary", value: "", continuation: nil),
            Entry(key: "title", value: "Acme # draft", continuation: nil),
        ])
    }

    @Test("a quoted key ends at its closing quote and shows without the quotes")
    func quotedKeys() throws {
        let source = "---\n\"a: b\": c\n'it''s': yes\n\"say \\\"hi\\\"\" : there\n---\n"
        let block = try #require(MarkdownFrontMatter.split(source).frontMatter)
        #expect(block.entries == [
            Entry(key: "a: b", value: "c", continuation: nil),
            Entry(key: "it''s", value: "yes", continuation: nil),
            Entry(key: #"say \"hi\""#, value: "there", continuation: nil),
        ])
        #expect(block.html.contains("<dt>a: b</dt><dd>c</dd>"))
    }

    @Test("a block that is not top-level keys has no entries")
    func unreadableBlock() throws {
        let comment = try #require(MarkdownFrontMatter.split("---\n# note\ntitle: Acme\n---\n").frontMatter)
        #expect(comment.entries == nil)
        let list = try #require(MarkdownFrontMatter.split("---\ntitle: Acme\n- one\n---\n").frontMatter)
        #expect(list.entries == nil)
        let unclosedQuote = try #require(MarkdownFrontMatter.split("---\ntitle: Acme\n\"open: v\n---\n").frontMatter)
        #expect(unclosedQuote.entries == nil)
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
        let block = try #require(MarkdownFrontMatter.split("---\n# note\ntitle: Acme\n---\n").frontMatter)
        #expect(block.html == #"<pre class="tbd-front-matter"># note"# + "\n" + "title: Acme</pre>")
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
        let block = try #require(MarkdownFrontMatter.split("---\n# <script>alert(1)</script>\ntitle: Acme\n---\n").frontMatter)
        #expect(block.html == #"<pre class="tbd-front-matter"># &lt;script&gt;alert(1)&lt;/script&gt;"#
            + "\n" + "title: Acme</pre>")
    }
}
