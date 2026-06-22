import Testing
import AppKit
@testable import TBDApp

@Suite("Markdown attributed renderer")
struct MarkdownAttributedRendererTests {
    @Test("plain prose renders its text")
    func plainProse() {
        let out = MarkdownAttributedRenderer.render("Hello world")
        #expect(out.string.contains("Hello world"))
    }
}
