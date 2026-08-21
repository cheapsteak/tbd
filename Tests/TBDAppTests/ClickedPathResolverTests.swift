import Testing
import Foundation
@testable import TBDApp

struct ClickedPathResolverTests {
    private let worktree = "/work/tree"

    private func resolve(
        _ token: String,
        existing: Set<String> = [],
        worktreePath: String? = nil
    ) -> String? {
        ClickedPathResolver.resolve(
            token,
            worktreePath: worktreePath ?? worktree,
            isReadableFile: { existing.contains($0) }
        )
    }

    @Test func absolutePath_thatExists_resolvesToItself() {
        #expect(resolve("/work/tree/CLAUDE.md", existing: ["/work/tree/CLAUDE.md"])
                == "/work/tree/CLAUDE.md")
    }

    @Test func absolutePath_thatDoesNotExist_returnsNil() {
        #expect(resolve("/work/tree/nope.md") == nil)
    }

    @Test func relativePath_resolvesAgainstWorktree() {
        #expect(resolve("docs/nightwatch.md", existing: ["/work/tree/docs/nightwatch.md"])
                == "/work/tree/docs/nightwatch.md")
    }

    @Test func relativePath_withEmptyWorktree_returnsNil() {
        #expect(resolve("docs/nightwatch.md",
                        existing: ["/work/tree/docs/nightwatch.md"],
                        worktreePath: "") == nil)
    }

    @Test func tildePath_expandsToHome() {
        let home = NSHomeDirectory()
        #expect(resolve("~/notes.md", existing: ["\(home)/notes.md"]) == "\(home)/notes.md")
    }

    @Test func fileURL_resolvesToItsPath() {
        #expect(resolve("file:///work/tree/CLAUDE.md", existing: ["/work/tree/CLAUDE.md"])
                == "/work/tree/CLAUDE.md")
    }

    // URL parsing treats the `~` as a host and drops it from `.path`, so this
    // form needs the manual strip-and-expand branch.
    @Test func fileURL_withTilde_expandsToHome() {
        let home = NSHomeDirectory()
        #expect(resolve("file://~/notes.md", existing: ["\(home)/notes.md"])
                == "\(home)/notes.md")
    }

    @Test func relativePath_withLineSuffix_stripsSuffix() {
        #expect(resolve("Sources/A.swift:17", existing: ["/work/tree/Sources/A.swift"])
                == "/work/tree/Sources/A.swift")
    }

    // Pins the ported behavior — the suffix strip is uniform across absolute
    // and relative. (Cmd+click on this form was observed to fail in the
    // terminal, but not here: the token widener strips `:` before the resolver
    // ever sees it. That defect lives elsewhere and is filed separately.)
    @Test func absolutePath_withLineAndColumnSuffix_stripsSuffix() {
        #expect(resolve("/work/tree/CLAUDE.md:3:1", existing: ["/work/tree/CLAUDE.md"])
                == "/work/tree/CLAUDE.md")
    }

    @Test func webURL_isNotAPath() {
        #expect(resolve("https://example.com/x.md", existing: ["https://example.com/x.md"]) == nil)
    }

    // MARK: - The real-filesystem overload

    /// Builds `<tmp>/sub/` with `<tmp>/sub/f.md` inside it, then removes it.
    ///
    /// The directory rule is unreachable through the injected overload: every
    /// test above supplies its own predicate, so deleting `!isDir.boolValue`
    /// from the convenience overload leaves all of them green. Only the two-arg
    /// overload against a real tree pins it.
    private func withTempTree(_ body: (String) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClickedPathResolverTests-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("f.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.path)
    }

    @Test func realDirectory_doesNotResolve() throws {
        try withTempTree { root in
            #expect(ClickedPathResolver.resolve("sub", worktreePath: root) == nil)
        }
    }

    @Test func realFile_resolvesThroughTheFilesystemOverload() throws {
        try withTempTree { root in
            #expect(ClickedPathResolver.resolve("sub/f.md", worktreePath: root)
                    == root + "/sub/f.md")
        }
    }
}
