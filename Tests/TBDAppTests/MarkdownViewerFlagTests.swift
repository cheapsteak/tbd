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

        let html = await MarkdownRenderService.shared.render(
            path: file.path, worktreeRoot: dir.path, css: ""
        )
        #expect(try #require(html).contains("<h1>Service</h1>"))
    }

    @Test("render service returns nil for a missing file")
    func renderServiceMissingFile() async {
        let html = await MarkdownRenderService.shared.render(
            path: "/nonexistent/\(UUID().uuidString).md", worktreeRoot: "", css: ""
        )
        #expect(html == nil)
    }

    @Test("a symlink cannot smuggle an oversized markdown file past the size guard")
    func renderServiceRejectsOversizedSymlink() async throws {
        // attributesOfItem has lstat semantics: for a symlink it reports the
        // length of the target *string* (~6 bytes) while String(contentsOf:)
        // follows the link and reads the whole target. A repo can check in
        // `README.md -> huge-file`.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("md-svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let big = dir.appendingPathComponent("huge")
        try String(repeating: "a", count: 1_600_000).write(to: big, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("README.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)

        // Guard against a false pass: the target must exist, so a nil result
        // means "rejected by the cap", not "unreadable".
        #expect(FileManager.default.fileExists(atPath: big.path))

        let html = await MarkdownRenderService.shared.render(
            path: link.path, worktreeRoot: dir.path, css: ""
        )
        #expect(html == nil)
    }
}
