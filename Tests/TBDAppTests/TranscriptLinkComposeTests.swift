// Tests/TBDAppTests/TranscriptLinkComposeTests.swift
import Testing
import AppKit
@testable import TBDApp

@MainActor
struct TranscriptLinkComposeTests {
    private let resolveDocsA: TranscriptPathResolver = {
        $0 == "docs/a.md" ? "/w/docs/a.md" : nil
    }

    private func prose(_ blocks: [MessageBlock]) -> NSAttributedString? {
        for block in blocks { if case .prose(let s) = block { return s } }
        return nil
    }

    /// The first `.link` run and the range it covers. The RANGE is what makes
    /// the styling assertions below discriminating: they read the attributes
    /// the pass actually left on the linked characters.
    private func firstLink(in s: NSAttributedString) -> (url: URL, range: NSRange)? {
        var found: (URL, NSRange)?
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(.link, in: full, options: []) { value, range, stop in
            if let url = value as? URL { found = (url, range); stop.pointee = true }
        }
        return found
    }

    private func color(_ s: NSAttributedString, at location: Int) -> NSColor? {
        s.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    private func underline(_ s: NSAttributedString, at location: Int) -> Int? {
        s.attribute(.underlineStyle, at: location, effectiveRange: nil) as? Int
    }

    @Test func renderBlocks_withResolver_linksAPathInProse() {
        let blocks = MarkdownAttributedRenderer.renderBlocks(
            "see docs/a.md now", theme: .chatBubble, linkResolver: resolveDocsA)
        let link = firstLink(in: prose(blocks)!)
        #expect(link?.url.scheme == "tbd-file")
        #expect(link?.url.path == "/w/docs/a.md")
    }

    // The prose half of the styling split, asserted through the real renderer:
    // tint present, underline absent.
    @Test func renderBlocks_proseLink_isTintedAndNotUnderlined() {
        let out = prose(MarkdownAttributedRenderer.renderBlocks(
            "see docs/a.md now", theme: .chatBubble, linkResolver: resolveDocsA))!
        let range = firstLink(in: out)!.range
        #expect(color(out, at: range.location) == NSColor.linkColor)
        #expect(underline(out, at: range.location) == nil)
    }

    // The reported case: a path inside backticks.
    //
    // Asserting only that a `.link` exists would pass whether or not
    // `visitInlineCode` ever set `.tbdCodeContext` — an implementer could skip
    // that edit entirely and ship a link whose tint the async highlight pass
    // erases. So this asserts the code TREATMENT: underlined, and still the
    // code foreground color rather than the link tint.
    @Test func renderBlocks_linksAPathInsideAnInlineCodeSpan() {
        let out = prose(MarkdownAttributedRenderer.renderBlocks(
            "committed to `docs/a.md` today", theme: .chatBubble,
            linkResolver: resolveDocsA))!
        let link = firstLink(in: out)!
        #expect(link.url.path == "/w/docs/a.md")
        #expect(underline(out, at: link.range.location) == NSUnderlineStyle.single.rawValue)
        #expect(color(out, at: link.range.location) != NSColor.linkColor)
    }

    // Same discrimination for a fenced block: without the `.tbdCodeContext`
    // attribute in `MarkdownCodeBlock.attributed`, this link would be tinted.
    @Test func renderBlocks_linksAPathInsideAFencedCodeBlock() {
        let out = prose(MarkdownAttributedRenderer.renderBlocks(
            "```\ndocs/a.md\n```", theme: .chatBubble, linkResolver: resolveDocsA))!
        let link = firstLink(in: out)!
        #expect(link.url.path == "/w/docs/a.md")
        #expect(underline(out, at: link.range.location) == NSUnderlineStyle.single.rawValue)
        #expect(color(out, at: link.range.location) != NSColor.linkColor)
    }

    // A fence WITH a language is the only path where `applyAsyncHighlights`
    // runs, and that pass is the entire reason code links underline instead of
    // tinting. So this is the case the rationale actually rests on: both
    // markers must be present over the linked characters — `.tbdCodeHighlight`
    // (the async pass will recolor here) and `.tbdCodeContext` (so the link
    // pass declines to tint).
    @Test func renderBlocks_fencedBlockWithALanguage_carriesBothCodeMarkers() {
        let out = prose(MarkdownAttributedRenderer.renderBlocks(
            "```swift\nlet p = docs/a.md\n```", theme: .chatBubble,
            linkResolver: resolveDocsA))!
        let link = firstLink(in: out)!
        #expect(link.url.path == "/w/docs/a.md")
        #expect(out.attribute(.tbdCodeHighlight, at: link.range.location,
                              effectiveRange: nil) as? String == "swift")
        #expect(out.attribute(.tbdCodeContext, at: link.range.location,
                              effectiveRange: nil) != nil)
        #expect(underline(out, at: link.range.location) == NSUnderlineStyle.single.rawValue)
    }

    @Test func renderBlocks_withNilResolver_marksNoFileLinks() {
        let blocks = MarkdownAttributedRenderer.renderBlocks(
            "see docs/a.md now", theme: .chatBubble, linkResolver: nil)
        #expect(firstLink(in: prose(blocks)!) == nil)
    }

    // A nil resolver must not suppress web URLs — they need no filesystem.
    @Test func renderBlocks_withNilResolver_stillLinksBareURLs() {
        let blocks = MarkdownAttributedRenderer.renderBlocks(
            "go https://example.com/x now", theme: .chatBubble, linkResolver: nil)
        #expect(firstLink(in: prose(blocks)!)?.url.absoluteString == "https://example.com/x")
    }

    // The visible text is ITSELF a candidate — that is the whole point of the
    // fixture. With link text like "the doc" the scanner finds nothing, so the
    // no-double-link guard is never reached and deleting it leaves the test
    // green.
    @Test func renderBlocks_leavesExistingMarkdownLinksIntact() {
        let blocks = MarkdownAttributedRenderer.renderBlocks(
            "[docs/a.md](https://example.com/original)", theme: .chatBubble,
            linkResolver: resolveDocsA)
        let out = prose(blocks)!
        #expect(firstLink(in: out)?.url.absoluteString == "https://example.com/original")
        // And exactly one link run: the guard skips the candidate rather than
        // splitting the existing link into pieces.
        var runs = 0
        let full = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.link, in: full, options: []) { value, _, _ in
            if value != nil { runs += 1 }
        }
        #expect(runs == 1)
    }

    // A CommonMark autolink renders its URL as the visible text, so the scanner
    // sees a candidate over a range the renderer already linked. The URL is the
    // same either way; what this pins is that the range survives intact rather
    // than being re-marked in pieces.
    @Test func renderBlocks_leavesAutolinksIntact() {
        let out = prose(MarkdownAttributedRenderer.renderBlocks(
            "<https://example.com/x>", theme: .chatBubble, linkResolver: nil))!
        let link = firstLink(in: out)!
        #expect(link.url.absoluteString == "https://example.com/x")
        #expect(link.range.length == ("https://example.com/x" as NSString).length)
    }

    // The spec's promise for a path that names nothing: it looks like ordinary
    // text. Not just unlinked — unstyled, down to the body color.
    @Test func renderBlocks_unresolvablePath_isCompletelyUnstyled() {
        let out = prose(MarkdownAttributedRenderer.renderBlocks(
            "see docs/nope.md now", theme: .chatBubble, linkResolver: resolveDocsA))!
        #expect(firstLink(in: out) == nil)
        let at = (out.string as NSString).range(of: "docs/nope.md").location
        #expect(underline(out, at: at) == nil)
        #expect(color(out, at: at) == TranscriptTextTheme.chatBubble.bodyColor)
    }

    // Each distinct token costs one `FileManager.fileExists`, and a streaming
    // row re-composes on every appended chunk, so the same tokens are re-asked
    // continuously on the main thread. The memo makes the repeat free.
    @Test func resolverCache_resolvesEachTokenOnlyOnce() {
        let cache = TranscriptLinkResolverCache()
        var calls: [String] = []
        let underlying: (String) -> String? = { token in
            calls.append(token)
            return token == "docs/a.md" ? "/w/docs/a.md" : nil
        }
        #expect(cache.resolve("docs/a.md", using: underlying) == "/w/docs/a.md")
        #expect(cache.resolve("docs/a.md", using: underlying) == "/w/docs/a.md")
        #expect(cache.resolve("nope.md", using: underlying) == nil)
        #expect(cache.resolve("nope.md", using: underlying) == nil)
        // A miss is memoized too: "names nothing" is the common answer and the
        // one worth not re-asking.
        #expect(calls == ["docs/a.md", "nope.md"])
    }

    // Grep output cites one file at many lines. Keying on the raw token would
    // make `foo.py:10` and `foo.py:42` two entries and two `stat()` calls for
    // one file, so the line suffix comes off before the lookup.
    @Test func resolverCache_ignoresTheLineSuffixWhenKeying() {
        let cache = TranscriptLinkResolverCache()
        var calls: [String] = []
        let underlying: (String) -> String? = { token in
            calls.append(token)
            return "/w/foo.py"
        }
        #expect(cache.resolve("foo.py:10", using: underlying) == "/w/foo.py")
        #expect(cache.resolve("foo.py:42", using: underlying) == "/w/foo.py")
        #expect(cache.resolve("foo.py:42:8", using: underlying) == "/w/foo.py")
        #expect(cache.resolve("foo.py", using: underlying) == "/w/foo.py")
        #expect(calls == ["foo.py"])
    }
}
