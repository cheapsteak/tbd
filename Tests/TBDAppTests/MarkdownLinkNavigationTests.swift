import Foundation
import Testing
@testable import TBDApp

@Suite("MarkdownLinkNavigation")
struct MarkdownLinkNavigationTests {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("md-nav-\(UUID().uuidString)")
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

    @Test("a repo-local markdown file is accepted")
    func acceptsFileInsideRoot() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try write("docs/log.md", in: root)

        #expect(MarkdownLinkNavigation.target(for: target, worktreeRoot: root.path)
            == target.standardizedFileURL.path)
    }

    @Test("a file outside the worktree root is refused")
    func refusesFileOutsideRoot() throws {
        // The scenario: a README containing
        // `[docs](file:///Users/me/.claude/CLAUDE.md)`. The navigation policy
        // is pure and knows no worktree, so it can only say "markdown file" —
        // this is the check that keeps it out of the pane.
        let sandbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = try write("secret.md", in: sandbox)

        // Guard against the false pass: the target must exist, so a nil result
        // means "refused", not "not found".
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(MarkdownLinkNavigation.target(for: outside, worktreeRoot: root.path) == nil)
    }

    @Test("a symlink pointing out of the worktree root is refused")
    func refusesEscapingSymlink() throws {
        let sandbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = try write("secret.md", in: sandbox)
        let innocent = root.appendingPathComponent("innocent.md")
        try FileManager.default.createSymbolicLink(at: innocent, withDestinationURL: outside)

        #expect(MarkdownLinkNavigation.target(for: innocent, worktreeRoot: root.path) == nil)
    }

    @Test("a repo reached through a symlinked root still works")
    func acceptsSymlinkedRoot() throws {
        // Both sides are symlink-resolved. Resolving only the candidate would
        // refuse every repo that lives under a symlinked path.
        let sandbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let real = sandbox.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try write("log.md", in: real)
        let link = sandbox.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let viaLink = link.appendingPathComponent("log.md")
        // The path handed back is the one the user navigated, not its
        // realpath, so the pane's header and the sidebar agree.
        #expect(MarkdownLinkNavigation.target(for: viaLink, worktreeRoot: link.path)
            == viaLink.standardizedFileURL.path)
    }

    @Test("a directory named like a document is refused")
    func refusesDirectory() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let asDirectory = root.appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: true)

        #expect(FileManager.default.fileExists(atPath: asDirectory.path))
        #expect(MarkdownLinkNavigation.target(for: asDirectory, worktreeRoot: root.path) == nil)
    }

    @Test("a file that vanished between render and click is refused")
    func refusesMissingFile() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(MarkdownLinkNavigation.target(
            for: root.appendingPathComponent("gone.md"), worktreeRoot: root.path) == nil)
    }

    @Test("the worktree root itself is not a target")
    func refusesTheRootItself() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(MarkdownLinkNavigation.target(for: root, worktreeRoot: root.path) == nil)
    }

    @Test("a sibling directory sharing the root's name prefix is refused")
    func refusesSiblingWithSharedPrefix() throws {
        // The trailing separator on the root: `/tmp/x-secrets` must not read
        // as inside `/tmp/x`.
        let sandbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sibling = try write("repo-secrets/log.md", in: sandbox)

        #expect(MarkdownLinkNavigation.target(for: sibling, worktreeRoot: root.path) == nil)
    }

    @Test("a non-file URL is refused")
    func refusesNonFileURL() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://example.com/a.md"))

        #expect(MarkdownLinkNavigation.target(for: url, worktreeRoot: root.path) == nil)
    }

    @Test("an empty worktree root refuses everything")
    func refusesEmptyRoot() throws {
        // Without this, `"" + "/"` is a prefix of every absolute path and the
        // containment check would wave the whole filesystem through.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try write("log.md", in: root)

        #expect(MarkdownLinkNavigation.target(for: target, worktreeRoot: "") == nil)
    }
}
