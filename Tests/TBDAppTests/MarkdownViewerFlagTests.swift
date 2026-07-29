import Foundation
import Testing
@testable import TBDApp

@Suite("MarkdownViewerFlag")
struct MarkdownViewerFlagTests {

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "MarkdownViewerFlagTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("defaults to off")
    func defaultsOff() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(MarkdownViewerPreferences.useWebView(defaults) == false)
    }

    @Test("reads an explicit opt-in")
    func readsOptIn() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: MarkdownViewerPreferences.useWebViewKey)
        #expect(MarkdownViewerPreferences.useWebView(defaults) == true)
    }

    @Test("reads an explicit opt-out")
    func readsOptOut() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: MarkdownViewerPreferences.useWebViewKey)
        #expect(MarkdownViewerPreferences.useWebView(defaults) == false)
    }

    @Test("render service produces a document for a real file")
    func renderServiceWorks() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("md-svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("README.md")
        try "# Service".write(to: file, atomically: true, encoding: .utf8)

        let html = await MarkdownRenderService.shared.render(path: file.path, css: "")
        #expect(try #require(html).contains("<h1>Service</h1>"))
    }

    @Test("render service returns nil for a missing file")
    func renderServiceMissingFile() async {
        let html = await MarkdownRenderService.shared.render(
            path: "/nonexistent/\(UUID().uuidString).md", css: ""
        )
        #expect(html == nil)
    }
}
