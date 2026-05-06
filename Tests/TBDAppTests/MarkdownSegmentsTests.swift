import Foundation
import Testing

@testable import TBDApp

@Suite("MarkdownSegments")
struct MarkdownSegmentsTests {
    @Test func plain_prose_one_segment() {
        let segs = MarkdownSegments.split("hello world")
        #expect(segs.count == 1)
        if case .prose(let t) = segs[0] { #expect(t == "hello world") } else { Issue.record("prose") }
    }

    @Test func single_fenced_block() {
        let input = """
        before
        ```swift
        let x = 1
        ```
        after
        """
        let segs = MarkdownSegments.split(input)
        #expect(segs.count == 3)
        if case .prose(let p1) = segs[0] { #expect(p1.contains("before")) } else { Issue.record("prose 0") }
        if case .code(let lang, let body) = segs[1] {
            #expect(lang == "swift")
            #expect(body == "let x = 1")
        } else { Issue.record("code 1") }
        if case .prose(let p2) = segs[2] { #expect(p2.contains("after")) } else { Issue.record("prose 2") }
    }

    @Test func fenced_block_no_language() {
        let input = """
        ```
        bare
        ```
        """
        let segs = MarkdownSegments.split(input)
        #expect(segs.count == 1)
        if case .code(let lang, let body) = segs[0] {
            #expect(lang == nil)
            #expect(body == "bare")
        } else { Issue.record("code") }
    }

    @Test func unterminated_fence_treats_rest_as_code() {
        let input = """
        intro
        ```python
        oops no closing
        """
        let segs = MarkdownSegments.split(input)
        #expect(segs.count == 2)
        if case .code(let lang, _) = segs[1] { #expect(lang == "python") } else { Issue.record("code") }
    }

    @Test func multiple_fenced_blocks() {
        let input = """
        a
        ```
        x
        ```
        b
        ```
        y
        ```
        c
        """
        let segs = MarkdownSegments.split(input)
        #expect(segs.count == 5)
    }

    @Test func inline_backticks_in_prose_not_treated_as_block_fence() {
        let input = "Use `git status` to check"
        let segs = MarkdownSegments.split(input)
        #expect(segs.count == 1)
        if case .prose = segs[0] { } else { Issue.record("prose") }
    }

    @Test func adjacent_fences_collapse_correctly() {
        let input = """
        ```
        first
        ```
        ```
        second
        ```
        """
        let segs = MarkdownSegments.split(input)
        let codeSegs = segs.compactMap { (s) -> String? in
            if case .code(_, let b) = s { return b } else { return nil }
        }
        #expect(codeSegs == ["first", "second"])
    }
}
