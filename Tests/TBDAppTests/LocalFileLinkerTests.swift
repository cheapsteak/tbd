// Tests/TBDAppTests/LocalFileLinkerTests.swift
import Testing
import Foundation
@testable import TBDApp

struct LocalFileLinkerTests {
    // Stub `fileExists` so tests don't depend on the real filesystem.
    private func linker(existing: Set<String> = []) -> (String) -> String {
        { text in LocalFileLinker.linkify(text, fileExists: { existing.contains($0) }) }
    }

    @Test func emptyString_returnsEmpty() {
        let link = linker()
        #expect(link("") == "")
    }

    @Test func noPaths_returnsUnchanged() {
        let link = linker()
        #expect(link("just some prose without paths") == "just some prose without paths")
    }

    @Test func barePath_atEndOfLine_isLinkified() {
        let link = linker(existing: ["/tmp/foo.md"])
        let input = "see /tmp/foo.md"
        let want  = "see [/tmp/foo.md](tbd-file:/tmp/foo.md)"
        #expect(link(input) == want)
    }

    @Test func barePath_followedByTrailingComma_isLinkified_punctuationOutside() {
        let link = linker(existing: ["/tmp/foo.md"])
        let input = "wrote /tmp/foo.md, then continued"
        let want  = "wrote [/tmp/foo.md](tbd-file:/tmp/foo.md), then continued"
        #expect(link(input) == want)
    }

    @Test func barePath_followedByPeriod_isLinkified_periodOutside() {
        let link = linker(existing: ["/tmp/foo.md"])
        let input = "wrote /tmp/foo.md."
        let want  = "wrote [/tmp/foo.md](tbd-file:/tmp/foo.md)."
        #expect(link(input) == want)
    }

    @Test func barePath_followedByColon_isLinkified_colonOutside() {
        let link = linker(existing: ["/tmp/foo.md"])
        let input = "output_file: /tmp/foo.md"
        let want  = "output_file: [/tmp/foo.md](tbd-file:/tmp/foo.md)"
        #expect(link(input) == want)
    }

    @Test func barePath_afterEquals_noSpace_isLinkified() {
        // `output_file=/tmp/foo.md` is a common shell-style assignment some
        // tool wrappers emit (no space after `=`). `=` must count as a path
        // predecessor for this to linkify.
        let link = linker(existing: ["/tmp/foo.md"])
        let input = "output_file=/tmp/foo.md"
        let want  = "output_file=[/tmp/foo.md](tbd-file:/tmp/foo.md)"
        #expect(link(input) == want)
    }

    @Test func barePath_insideParens_isLinkified_parensOutside() {
        let link = linker(existing: ["/tmp/foo.md"])
        let input = "(see /tmp/foo.md)"
        let want  = "(see [/tmp/foo.md](tbd-file:/tmp/foo.md))"
        #expect(link(input) == want)
    }

    @Test func nonexistentPath_isNotLinkified() {
        let link = linker(existing: [])
        let input = "missing /tmp/nope.md"
        #expect(link(input) == input)
    }

    @Test func httpURL_isNotLinkified() {
        let link = linker(existing: ["/tmp/foo.md"])
        let input = "see http://example.com/path and /tmp/foo.md"
        let want  = "see http://example.com/path and [/tmp/foo.md](tbd-file:/tmp/foo.md)"
        #expect(link(input) == want)
    }

    @Test func existingMarkdownLink_isLeftAlone() {
        let link = linker(existing: ["/tmp/foo.md"])
        let input = "[design](/tmp/foo.md)"
        #expect(link(input) == input)
    }

    @Test func fencedCodeBlock_isLeftAlone() {
        let link = linker(existing: ["/tmp/foo.md"])
        let input = "```\nls /tmp/foo.md\n```"
        #expect(link(input) == input)
    }

    @Test func inlineCode_isLeftAlone() {
        let link = linker(existing: ["/tmp/foo.md"])
        let input = "the path `/tmp/foo.md` is fine"
        #expect(link(input) == input)
    }

    @Test func multiplePaths_allLinkified() {
        let link = linker(existing: ["/tmp/a.md", "/tmp/b.md"])
        let input = "/tmp/a.md and /tmp/b.md"
        let want  = "[/tmp/a.md](tbd-file:/tmp/a.md) and [/tmp/b.md](tbd-file:/tmp/b.md)"
        #expect(link(input) == want)
    }

    @Test func pathWithSpecialCharacters_isLinkified() {
        let p = "/private/tmp/claude-501/-Users-chang-tbd-worktrees-longeye-app-20260522-vertical-manatee/aa0e7f1a-ddfa-49be-9804-bbde46833998/tasks/a9af77d70d2239272.output"
        let link = linker(existing: [p])
        let input = "output_file: \(p)"
        let want  = "output_file: [\(p)](tbd-file:\(p))"
        #expect(link(input) == want)
    }

    @Test func percentEncodingInURL_isReversible() {
        // A real file with a space — escaping must round-trip via URL decoding
        // at click time. We verify the link target form here.
        let p = "/tmp/file with space.md"
        let link = linker(existing: [p])
        let out = link("look at \(p)")
        #expect(out.contains("(tbd-file:/tmp/file%20with%20space.md)"))
    }
}
