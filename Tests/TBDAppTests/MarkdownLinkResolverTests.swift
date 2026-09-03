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

        // Positive control, in the same test: without it this passes green
        // even with `removingPercentEncoding` deleted from the resolver, since
        // the literal name `%2e%2e%2f%2e%2e%2fsecret.md` does not exist either
        // and an unrewritten href is the same observation as a rejected one.
        // This href decodes to a file that DOES exist inside the root, so the
        // decode has to be happening for the test to pass at all.
        let inside = try write("release notes.md", in: docs)

        let resolver = MarkdownLinkResolver(documentDirectory: docs, worktreeRoot: root)
        let out = resolver.resolve(html: #"<a href="%2e%2e%2f%2e%2e%2fsecret.md">oops</a>"#)
        let control = resolver.resolve(html: #"<a href="release%20notes.md">notes</a>"#)

        #expect(!out.contains("file://"))
        #expect(control.contains(inside.standardizedFileURL.absoluteString))
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
        let html = ##"<a href="#installation">Installation</a>"##
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

    @Test("the link pass rewrites the anchor and leaves the image src alone")
    func leavesImageSourcesAlone() throws {
        // Feeding it an `<img>` alone proves nothing: the regex is anchored on
        // `<a`, so a lone image could never have matched however broken the
        // pass was. Both tags in one document is the discriminating shape —
        // loosen the regex to `src=` and the image assertion fails, break the
        // anchor half and the link assertion fails.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("pic.png", in: dir)
        let target = try write("log.md", in: dir)

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let out = resolver.resolve(
            html: #"<p><img src="pic.png" alt="x" /><a href="log.md">log</a></p>"#)

        #expect(out.contains(#"<img src="pic.png" alt="x" />"#))
        #expect(out.contains(target.standardizedFileURL.absoluteString))
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

    // MARK: - Root-relative hrefs

    @Test("a root-relative href resolves against the worktree root, not the document")
    func resolvesRootRelativeAgainstRoot() throws {
        // GitHub semantics: a leading `/` addresses the repository root.
        // Resolved against the document directory instead, this lands on the
        // dead `<root>/docs/docs/setup.md`.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let target = try write("docs/setup.md", in: root)

        let resolver = MarkdownLinkResolver(documentDirectory: docs, worktreeRoot: root)
        let out = resolver.resolve(html: #"<a href="/docs/setup.md">setup</a>"#)

        #expect(out.contains(target.standardizedFileURL.absoluteString))
    }

    @Test("a root-relative href does not silently pick the same-named sibling")
    func rootRelativePrefersRootOverDocumentDirectory() throws {
        // Both files exist. Resolving `/README.md` against the document
        // directory finds `docs/README.md` and looks like it worked — the
        // silent-wrong-file half of the defect, which the dead-link test
        // above cannot see.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let atRoot = try write("README.md", in: root)
        let decoy = try write("README.md", in: docs)

        let resolver = MarkdownLinkResolver(documentDirectory: docs, worktreeRoot: root)
        let out = resolver.resolve(html: #"<a href="/README.md">readme</a>"#)

        #expect(out.contains(atRoot.standardizedFileURL.absoluteString))
        #expect(!out.contains(decoy.standardizedFileURL.absoluteString))
    }

    @Test("an absolute system path is reinterpreted under the root, never escaping it")
    func absoluteSystemPathStaysInsideRoot() throws {
        // `/etc/passwd` becomes `<root>/etc/passwd`. The file is created here
        // so the test discriminates: without the reinterpretation the href
        // would have to name the real `/etc/passwd`, and with it the href
        // names the in-root file. A missing target would have made both
        // outcomes look identical.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let inRoot = try write("etc/passwd", in: root)

        let resolver = MarkdownLinkResolver(documentDirectory: root, worktreeRoot: root)
        let out = resolver.resolve(html: #"<a href="/etc/passwd">creds</a>"#)

        #expect(out.contains(inRoot.standardizedFileURL.absoluteString))
        #expect(!out.contains(#"file:///etc/passwd""#))
    }

    @Test("a bare / href is left alone")
    func leavesBareRootHrefAlone() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = MarkdownLinkResolver(documentDirectory: root, worktreeRoot: root)
        let html = #"<a href="/">home</a>"#
        #expect(resolver.resolve(html: html) == html)
    }

    // MARK: - Undoing comrak's escaping

    @Test("an apostrophe entity is decoded")
    func decodesApostropheEntity() throws {
        // comrak's `escape_href` writes `'` as `&#x27;` — verified in its
        // source, alongside `&amp;` for `&`. Leaving it undecoded makes every
        // link to a file with an apostrophe in its name dead.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try write("user's guide.md", in: dir)

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let out = resolver.resolve(html: ##"<a href="user&#x27;s%20guide.md">guide</a>"##)

        #expect(out.contains(target.standardizedFileURL.absoluteString))
    }

    @Test("an escaped ampersand entity is still decoded")
    func decodesAmpersandEntity() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try write("this & that.md", in: dir)

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let out = resolver.resolve(html: #"<a href="this%20&amp;%20that.md">both</a>"#)

        #expect(out.contains(target.standardizedFileURL.absoluteString))
    }

    @Test("an encoded # in a filename is not mistaken for a fragment")
    func doesNotTruncateAtAnEncodedHash() throws {
        // `#` is in comrak's HREF_SAFE set, so a real fragment arrives
        // literal and a `#` in a filename arrives as `%23`. Splitting after
        // the percent-decode cuts this href down to `a`.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try write("a#b.md", in: dir)

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let out = resolver.resolve(html: #"<a href="a%23b.md">a</a>"#)

        #expect(out.contains(target.standardizedFileURL.absoluteString))
    }

    // MARK: - Scheme detection

    @Test("a colon inside a filename is not read as a scheme")
    func colonInFilenameIsNotAScheme() throws {
        // `:` is in comrak's HREF_SAFE set, so `[notes](v1:changelog.md)`
        // reaches the resolver unencoded. `URL(string:)?.scheme` reports
        // `v1` for it, which abandoned the link as if it were remote.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try write("v1:changelog.md", in: dir)

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let out = resolver.resolve(html: #"<a href="v1:changelog.md">notes</a>"#)

        #expect(out.contains(target.standardizedFileURL.absoluteString))
    }

    @Test("authority-bearing and opaque schemes are still refused")
    func stillRefusesRealSchemes() throws {
        // The permissive half of the scheme check must not reach these.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The opaque ones are the discriminating half: each names a file that
        // really is sitting in the root, so a resolver that read them as
        // relative paths would rewrite the href and redden this test.
        let opaque = ["mailto:a@b.com", "data:text", "file:x.md", "javascript:x.md"]
        for name in opaque {
            try write(name, in: dir)
        }

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let raws = opaque + [
            "https://evil.com", "http://evil.com", "smb://evil.com", "tbd://evil.com",
        ]
        for raw in raws {
            let html = #"<a href="\#(raw)">x</a>"#
            #expect(resolver.resolve(html: html) == html, "\(raw) must be left alone")
        }
    }

    // MARK: - What the target has to be

    @Test("a directory named like a document is not a link target")
    func rejectsDirectoryTarget() throws {
        // Parity with `MarkdownImageInliner`, which requires a regular file.
        // `fileExists` alone says yes to a directory named `notes.md`.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asDirectory = dir.appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: true)
        #expect(FileManager.default.fileExists(atPath: asDirectory.path))

        let resolver = MarkdownLinkResolver(documentDirectory: dir, worktreeRoot: dir)
        let html = #"<a href="notes.md">notes</a>"#
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
