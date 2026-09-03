import Foundation
import Testing
@testable import TBDApp

@Suite("MarkdownLinkResolver")
struct MarkdownLinkResolverTests {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("md-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func write(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# doc".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Rewriting

    @Test("rewrites a document-relative link to an absolute file URL")
    func rewritesRelativeLink() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try write("log.md", in: dir)

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let out = resolver.resolve(html: #"<a href="log.md">log</a>"#)

        #expect(out == #"<a href="\#(target.standardizedFileURL.absoluteString)">log</a>"#)
    }

    @Test("rewrites a ./-prefixed link")
    func rewritesDotSlashLink() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("log.md", in: dir)

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let out = resolver.resolve(html: #"<a href="./log.md">log</a>"#)

        #expect(out.contains("file://"))
        #expect(out.contains("log.md"))
        #expect(!out.contains(#"href="./log.md""#))
    }

    @Test("preserves the anchor's other attributes")
    func preservesAttributes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("log.md", in: dir)

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let out = resolver.resolve(html: #"<a href="log.md" title="the log">log</a>"#)

        #expect(out.contains(#"title="the log""#))
        #expect(out.contains("file://"))
    }

    @Test("percent-encoded destinations are decoded before resolution")
    func decodesPercentEncoding() throws {
        // comrak percent-encodes destinations, so `[x](my log.md)` arrives as
        // `my%20log.md` and a literal resolution would miss the file.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("my log.md", in: dir)

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let out = resolver.resolve(html: #"<a href="my%20log.md">log</a>"#)

        #expect(out.contains("file://"))
        #expect(out.contains("my%20log.md"))
    }

    @Test("a fragment on a relative link is dropped, the file still resolves")
    func dropsFragmentOnRelativeLink() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try write("log.md", in: dir)

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let out = resolver.resolve(html: #"<a href="./log.md#results">log</a>"#)

        #expect(out.contains(target.standardizedFileURL.absoluteString))
        #expect(!out.contains("#results"))
    }

    @Test("rewrites every link in a document")
    func rewritesMultipleLinks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a.md", in: dir)
        try write("b.md", in: dir)

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let out = resolver.resolve(
            html: #"<p><a href="a.md">a</a> and <a href="./b.md">b</a></p>"#)

        #expect(out.components(separatedBy: "file://").count - 1 == 2)
    }

    // MARK: - Containment

    @Test("a ../ link that stays inside the worktree root is rewritten")
    func allowsParentRelativeInsideRoot() throws {
        // `docs/guide.md` linking `../README.md` is a mainstream repo layout.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let target = try write("README.md", in: root)

        let resolver = MarkdownLinkResolver(documentDirectory: docs, worktreeRoot: root)
        let out = resolver.resolve(html: #"<a href="../README.md">readme</a>"#)

        #expect(out.contains(target.standardizedFileURL.absoluteString))
    }

    @Test("a ../ link that escapes the worktree root is left unrewritten")
    func rejectsTraversalOutsideRoot() throws {
        // Per-test sandbox, not a fixed name in the shared temp root: a fixed
        // name races concurrent suite runs in sibling worktrees and the loser's
        // cleanup deletes the file, turning this into a FALSE PASS
        // indistinguishable from "the target was missing".
        let sandbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("repo")
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let secret = try write("secret.md", in: sandbox)

        // Guard against the false pass: the target must actually exist, so an
        // unrewritten result means "rejected", not "not found".
        #expect(FileManager.default.fileExists(atPath: secret.path))

        let resolver = MarkdownLinkResolver(documentDirectory: docs, worktreeRoot: root)
        let out = resolver.resolve(html: #"<a href="../../secret.md">oops</a>"#)

        #expect(out == #"<a href="../../secret.md">oops</a>"#)
        #expect(!out.contains("file://"))
    }

    @Test("percent-encoded traversal is rejected too")
    func rejectsEncodedTraversal() throws {
        // The decode MUST precede the containment check, or %2e%2e%2f walks
        // straight past a lexical guard.
        let sandbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("repo")
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let secret = try write("secret.md", in: sandbox)
        #expect(FileManager.default.fileExists(atPath: secret.path))

        let resolver = MarkdownLinkResolver(documentDirectory: docs, worktreeRoot: root)
        let out = resolver.resolve(html: #"<a href="%2e%2e%2f%2e%2e%2fsecret.md">oops</a>"#)

        #expect(!out.contains("file://"))
    }

    @Test("a symlink that escapes the worktree root is rejected")
    func rejectsEscapingSymlink() throws {
        let sandbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let secret = try write("secret.md", in: sandbox)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("innocent.md"), withDestinationURL: secret)
        #expect(FileManager.default.fileExists(atPath: secret.path))

        let resolver = MarkdownLinkResolver(documentDirectory: root, worktreeRoot: root)
        let out = resolver.resolve(html: #"<a href="innocent.md">x</a>"#)

        #expect(!out.contains("file://"))
    }

    @Test("works when the document is reached through a symlinked root")
    func worksUnderSymlinkedRoot() throws {
        // Pins the ROOT-side resolvingSymlinksInPath(). Dropping it makes every
        // link in every repo under a symlinked path silently stop working, and
        // no temp-path test would notice: NSTemporaryDirectory() already equals
        // its own realpath, so only a user-created symlink exposes a one-sided
        // resolution.
        let sandbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let real = sandbox.appendingPathComponent("real/doc")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try write("log.md", in: real)
        try FileManager.default.createSymbolicLink(
            at: sandbox.appendingPathComponent("link"),
            withDestinationURL: sandbox.appendingPathComponent("real"))

        let viaLink = sandbox.appendingPathComponent("link/doc")
        let resolver = MarkdownLinkResolver(
            documentDirectory: viaLink, worktreeRoot: sandbox.appendingPathComponent("link"))
        let out = resolver.resolve(html: #"<a href="log.md">log</a>"#)

        #expect(out.contains("file://"))
        // The href keeps the path the user navigated, not its realpath, so the
        // pane's selection matches what the sidebar shows.
        #expect(out.contains("/link/doc/log.md"))
    }

    // MARK: - Left alone

    @Test("absolute http(s) hrefs are untouched")
    func leavesRemoteAlone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        for raw in ["https://example.com/docs", "http://example.com/x", "mailto:a@b.com"] {
            let html = #"<a href="\#(raw)">x</a>"#
            #expect(resolver.resolve(html: html) == html)
        }
    }

    @Test("fragment-only hrefs are untouched")
    func leavesFragmentAnchorsAlone() throws {
        // Every README table of contents depends on these reaching the webview
        // as same-document anchors.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let html = #"<a href="#installation">Installation</a>"#
        #expect(resolver.resolve(html: html) == html)
    }

    @Test("protocol-relative hrefs are untouched")
    func leavesProtocolRelativeAlone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let html = #"<a href="//evil.com/x">x</a>"#
        #expect(resolver.resolve(html: html) == html)
    }

    @Test("an href pointing at nothing is left unrewritten")
    func leavesMissingTargetAlone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let html = #"<a href="nope.md">nope</a>"#
        #expect(resolver.resolve(html: html) == html)
    }

    @Test("image tags are not touched by the link pass")
    func leavesImagesAlone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("pic.png", in: dir)

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let html = #"<img src="pic.png" alt="x" />"#
        #expect(resolver.resolve(html: html) == html)
    }

    @Test("a tag whose name merely starts with 'a' is not matched")
    func leavesAbbrAlone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("log.md", in: dir)

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let html = #"<abbr href="log.md">x</abbr>"#
        #expect(resolver.resolve(html: html) == html)
    }

    // MARK: - Through the document builder

    @Test("a relative markdown link survives the whole build pipeline")
    func resolvesThroughDocumentBuilder() throws {
        // Construct through the production path: the regex, the ordering
        // against the image inliner, and the builder wiring all participate.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try write("for-adam-log.md", in: dir)

        let doc = try #require(MarkdownDocumentBuilder.build(
            markdown: "See [the log](./for-adam-log.md) and [the web](https://example.com).",
            documentDirectory: dir, worktreeRoot: dir, css: ""
        ))

        #expect(doc.contains(target.standardizedFileURL.absoluteString))
        #expect(doc.contains("https://example.com"))
    }
}
