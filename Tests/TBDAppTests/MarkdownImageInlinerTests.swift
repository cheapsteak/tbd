import Foundation
import Testing
@testable import TBDApp

@Suite("MarkdownImageInliner")
struct MarkdownImageInlinerTests {

    /// 1x1 transparent PNG.
    static let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )!

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("md-inliner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("inlines a small local image as a data URI")
    func inlinesLocalImage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.tinyPNG.write(to: dir.appendingPathComponent("pic.png"))

        var inliner = MarkdownImageInliner(documentDirectory: dir)
        let out = inliner.inline(html: #"<img src="pic.png" alt="x" />"#)

        #expect(out.contains("data:image/png;base64,"))
        #expect(!out.contains(#"src="pic.png""#))
    }

    @Test("leaves remote URLs untouched")
    func leavesRemoteAlone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var inliner = MarkdownImageInliner(documentDirectory: dir)
        let out = inliner.inline(html: #"<img src="https://example.com/b.png" />"#)

        #expect(out.contains("https://example.com/b.png"))
        #expect(!out.contains("data:"))
    }

    @Test("replaces an oversized image with a placeholder")
    func placeholderForOversized() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = Data(repeating: 0x41, count: MarkdownImageInliner.perImageLimit + 1)
        try big.write(to: dir.appendingPathComponent("big.png"))

        var inliner = MarkdownImageInliner(documentDirectory: dir)
        let out = inliner.inline(html: #"<img src="big.png" />"#)

        #expect(!out.contains("data:image"))
        #expect(out.contains("tbd-oversized-image"))
        #expect(out.contains("big.png"))
    }

    @Test("stops inlining once the document budget is exhausted")
    func respectsDocumentBudget() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Nine 2 MiB images: eight fit in the 16 MiB budget, the ninth does not.
        let each = Data(repeating: 0x41, count: MarkdownImageInliner.perImageLimit)
        for i in 0..<9 {
            try each.write(to: dir.appendingPathComponent("i\(i).png"))
        }
        let html = (0..<9).map { #"<img src="i\#($0).png" />"# }.joined()

        var inliner = MarkdownImageInliner(documentDirectory: dir)
        let out = inliner.inline(html: html)

        let inlined = out.components(separatedBy: "data:image").count - 1
        #expect(inlined == 8)
        #expect(out.contains("tbd-oversized-image"))
    }

    @Test("rejects path traversal outside the document directory")
    func rejectsTraversal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.deletingLastPathComponent().appendingPathComponent("secret.png")
        try Self.tinyPNG.write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }

        var inliner = MarkdownImageInliner(documentDirectory: dir)
        let out = inliner.inline(html: #"<img src="../secret.png" />"#)

        #expect(!out.contains("data:image"))
    }

    @Test("leaves a missing file alone rather than crashing")
    func missingFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var inliner = MarkdownImageInliner(documentDirectory: dir)
        let out = inliner.inline(html: #"<img src="nope.png" />"#)

        #expect(!out.contains("data:image"))
    }
}
