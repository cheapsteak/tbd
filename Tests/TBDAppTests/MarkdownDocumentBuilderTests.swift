import Foundation
import Testing
@testable import TBDApp

@Suite("MarkdownDocumentBuilder")
struct MarkdownDocumentBuilderTests {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("md-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("produces a complete document with the supplied CSS inlined")
    func buildsDocument() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let doc = try #require(MarkdownDocumentBuilder.build(
            markdown: "# Hi", documentDirectory: dir, worktreeRoot: dir, css: "body{color:red}"
        ))
        #expect(doc.contains("<!DOCTYPE html>"))
        #expect(doc.contains(#"<meta charset="utf-8">"#))
        #expect(doc.contains("body{color:red}"))
        #expect(doc.contains("<h1>Hi</h1>"))
    }

    @Test("contains no script element")
    func noScript() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let doc = try #require(MarkdownDocumentBuilder.build(
            markdown: "<script>alert(1)</script>\n\n# Safe",
            documentDirectory: dir, worktreeRoot: dir, css: ""
        ))
        #expect(!doc.contains("<script"))
    }

    @Test("front matter becomes a properties header, not a rule and a setext heading")
    func frontMatterHeader() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let doc = try #require(MarkdownDocumentBuilder.build(
            markdown: "---\ntitle: Acme\nslug: acme\n---\n\n# Widgets\n",
            documentDirectory: dir, worktreeRoot: dir, css: ""
        ))
        let header = #"<dl class="tbd-front-matter"><dt>title</dt><dd>Acme</dd><dt>slug</dt><dd>acme</dd></dl>"#
        let headerRange = try #require(doc.range(of: header))
        let titleRange = try #require(doc.range(of: "<h1>Widgets</h1>"))
        #expect(headerRange.upperBound < titleRange.lowerBound)
        #expect(!doc.contains("<hr"))
        #expect(!doc.contains("<h2"))
        #expect(!doc.contains("<details"))
    }

    @Test("an empty front matter block renders nothing")
    func emptyFrontMatter() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let doc = try #require(MarkdownDocumentBuilder.build(
            markdown: "---\n---\n# Widgets\n", documentDirectory: dir, worktreeRoot: dir, css: ""
        ))
        #expect(!doc.contains("tbd-front-matter"))
        #expect(!doc.contains("<hr"))
        #expect(doc.contains("<h1>Widgets</h1>"))
    }

    @Test("markup in front matter comes out as text")
    func frontMatterEscaped() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let doc = try #require(MarkdownDocumentBuilder.build(
            markdown: "---\ntitle: <script>alert(1)</script>\n---\n# Safe\n",
            documentDirectory: dir, worktreeRoot: dir, css: ""
        ))
        #expect(!doc.contains("<script"))
        #expect(doc.contains("<dd>&lt;script&gt;alert(1)&lt;/script&gt;</dd>"))
    }

    @Test("returns nil for a NUL byte inside front matter, as it does in the body")
    func nilOnNULInFrontMatter() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(MarkdownDocumentBuilder.build(
            markdown: "---\ntitle: a\u{0}b\n---\nBody", documentDirectory: dir, worktreeRoot: dir, css: ""
        ) == nil)
    }

    @Test("a document opening with a thematic break renders as it always did")
    func openingThematicBreakRendersUnchanged() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        for source in [
            "---\n\n# Intro\n\nSome *text*\n\n---\n\nMore",
            "---\nSetup notes for the widget service.\n\n```yaml\n---\nname: acme\n```\n\nMore text.\n",
        ] {
            let doc = try #require(MarkdownDocumentBuilder.build(
                markdown: source, documentDirectory: dir, worktreeRoot: dir, css: ""
            ))
            let unsplit = try #require(MarkdownHTMLRenderer.renderBody(source))
            #expect(doc.contains(unsplit))
            #expect(doc.contains("<hr />"))
            #expect(!doc.contains("tbd-front-matter"))
        }
    }

    @Test("returns nil when the renderer rejects the input")
    func nilOnRendererFailure() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(MarkdownDocumentBuilder.build(
            markdown: "bad\u{0}input", documentDirectory: dir, worktreeRoot: dir, css: ""
        ) == nil)
    }
}
