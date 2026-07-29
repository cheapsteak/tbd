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
        // The secret lives in a per-test sandbox, NOT the shared temp root.
        // A fixed name in NSTemporaryDirectory() races across concurrent
        // `swift test` runs in sibling worktrees, and the loser's cleanup
        // deletes the file — turning this security test into a FALSE PASS
        // indistinguishable from `missingFile`.
        let sandbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let dir = sandbox.appendingPathComponent("doc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let secret = sandbox.appendingPathComponent("secret.png")
        try Self.tinyPNG.write(to: secret)

        // Guard against the false pass: the target must actually exist, so a
        // non-inlined result means "rejected", not "not found".
        #expect(FileManager.default.fileExists(atPath: secret.path))

        var inliner = MarkdownImageInliner(documentDirectory: dir)
        let out = inliner.inline(html: #"<img src="../secret.png" />"#)

        #expect(!out.contains("data:image"))
    }

    @Test("rejects a symlink that escapes the document directory")
    func rejectsEscapingSymlink() throws {
        let sandbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let dir = sandbox.appendingPathComponent("doc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let secret = sandbox.appendingPathComponent("secret.png")
        try Self.tinyPNG.write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("innocent.png"), withDestinationURL: secret
        )
        #expect(FileManager.default.fileExists(atPath: secret.path))

        var inliner = MarkdownImageInliner(documentDirectory: dir)
        let out = inliner.inline(html: #"<img src="innocent.png" />"#)

        #expect(!out.contains("data:image"))
    }

    @Test("a symlink cannot smuggle an oversized file past the caps")
    func symlinkCannotBypassSizeCap() throws {
        // attributesOfItem has lstat semantics and reports a symlink as ~10
        // bytes while contents(atPath:) follows it. Reading size from the
        // RESOLVED url is what keeps the cap honest.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.png")
        try Data(repeating: 0x41, count: MarkdownImageInliner.perImageLimit + 1).write(to: big)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("small-looking.png"), withDestinationURL: big
        )

        var inliner = MarkdownImageInliner(documentDirectory: dir)
        let out = inliner.inline(html: #"<img src="small-looking.png" />"#)

        #expect(!out.contains("data:image"))
        #expect(out.contains("tbd-oversized-image"))
    }

    @Test("does not inline non-image files")
    func rejectsNonImage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "secret key".write(to: dir.appendingPathComponent("notes.md"),
                               atomically: true, encoding: .utf8)

        var inliner = MarkdownImageInliner(documentDirectory: dir)
        let out = inliner.inline(html: #"<img src="notes.md" />"#)

        #expect(!out.contains("data:"))
    }

    @Test("preserves alt text when inlining")
    func preservesAlt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.tinyPNG.write(to: dir.appendingPathComponent("pic.png"))

        var inliner = MarkdownImageInliner(documentDirectory: dir)
        let out = inliner.inline(html: #"<img src="pic.png" alt="a diagram" />"#)

        #expect(out.contains("data:image/png;base64,"))
        #expect(out.contains(#"alt="a diagram""#))
    }

    @Test("resolves percent-encoded filenames")
    func resolvesPercentEncoding() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.tinyPNG.write(to: dir.appendingPathComponent("my pic.png"))

        var inliner = MarkdownImageInliner(documentDirectory: dir)
        let out = inliner.inline(html: #"<img src="my%20pic.png" />"#)

        #expect(out.contains("data:image/png;base64,"))
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
