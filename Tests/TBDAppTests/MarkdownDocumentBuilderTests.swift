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
            markdown: "# Hi", documentDirectory: dir, css: "body{color:red}"
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
            documentDirectory: dir, css: ""
        ))
        #expect(!doc.contains("<script"))
    }

    @Test("bundled default stylesheet loads and is non-empty")
    func defaultCSSLoads() {
        #expect(MarkdownDocumentBuilder.defaultCSS.contains("--md-fg"))
        #expect(MarkdownDocumentBuilder.defaultCSS.contains("prefers-color-scheme"))
    }

    @Test("returns nil when the renderer rejects the input")
    func nilOnRendererFailure() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(MarkdownDocumentBuilder.build(
            markdown: "bad\u{0}input", documentDirectory: dir, css: ""
        ) == nil)
    }
}
