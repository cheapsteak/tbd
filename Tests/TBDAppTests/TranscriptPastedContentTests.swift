import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Covers Claude Code's terminal-paste wrapper in user prompts
/// (`<pasted_content id="…">…</pasted_content id="…">`): how it is removed from
/// the prompt text, and that both transcript renderers draw the span's text as
/// ordinary typed text — for USER prompts only — without the tags.
@MainActor
@Suite("Transcript pasted content")
struct TranscriptPastedContentTests {

    // MARK: - Fixtures

    /// The shape of a real stored prompt, with names scrubbed: typed text, a
    /// blank line, the wrapped paste, a blank line, more typed text that starts
    /// with a space.
    private static let realShape = "something weird happening in my tbd worktrees for acme. e.g. \n\n"
        + "<pasted_content id=\"62f5\">\n"
        + "/Users/acme/tbd/worktrees/acme-app/20260921-stiff-seahorse\n"
        + "</pasted_content id=\"62f5\">\n\n"
        + " the context limit seems to be 200k for new sessions, where does that come from? "
        + "it immediately exceeds on the first message and triggers compaction"

    private static let pastedPath = "/Users/acme/tbd/worktrees/acme-app/20260921-stiff-seahorse"

    /// The shape the transcript composer produces: the whole message is one
    /// bracketed paste, so the stored prompt is nothing but the wrapped span,
    /// with blank lines around it.
    private static let composerShape = "\n\n<pasted_content id=\"9b63\">\n"
        + "explain the **timing gate**, what is it for?\n\n"
        + "let's drop the ratchet\n"
        + "</pasted_content id=\"9b63\">\n"

    private static let composerTyped = "explain the **timing gate**, what is it for?\n\nlet's drop the ratchet"

    private func wrap(_ body: String, id: String = "62f5") -> String {
        "<pasted_content id=\"\(id)\">\n\(body)\n</pasted_content id=\"\(id)\">"
    }

    private func allText(_ blocks: [MessageBlock]) -> String {
        blocks.compactMap { block -> String? in
            if case .prose(let s) = block { return s.string }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: - Unwrapping

    @Test func realShapeKeepsTheSurroundingTextAndDropsOnlyTheTags() {
        #expect(TranscriptPastedContent.unwrap(Self.realShape)
            == "something weird happening in my tbd worktrees for acme. e.g. \n\n"
            + Self.pastedPath + "\n\n"
            + " the context limit seems to be 200k for new sessions, where does that come from? "
            + "it immediately exceeds on the first message and triggers compaction")
    }

    /// A composer message reads as the user wrote it: no leading blank lines
    /// from the wrapper, no trailing newline, internal blank lines kept.
    @Test func composerMessageUnwrapsToTheTypedText() {
        #expect(TranscriptPastedContent.unwrap(Self.composerShape) == Self.composerTyped)
    }

    @Test func twoSpansInOneMessage() {
        let text = "first\n\(wrap("one", id: "aaaa"))\nmiddle\n\(wrap("two\nlines", id: "0b1c"))\nlast"
        #expect(TranscriptPastedContent.unwrap(text) == "first\none\nmiddle\ntwo\nlines\nlast")
    }

    /// Only the wrapper's own newline on each side is removed; the span's own
    /// blank lines and indentation survive.
    @Test func onlyOneWrapperNewlineIsStrippedOnEachSide() {
        let text = "before\n<pasted_content id=\"62f5\">\n\n  indented\n\n</pasted_content id=\"62f5\">\nafter"
        #expect(TranscriptPastedContent.unwrap(text) == "before\n\n  indented\n\nafter")
    }

    /// The outer trim drops blank LINES only: indentation on the first line of
    /// text is markdown and stays.
    @Test func leadingIndentationOnTheFirstLineIsKept() {
        #expect(TranscriptPastedContent.unwrap("\n \n" + wrap("    code")) == "    code")
    }

    @Test func emptySpanLeavesTheSurroundingText() {
        let text = "before <pasted_content id=\"62f5\">\n</pasted_content id=\"62f5\"> after"
        #expect(TranscriptPastedContent.unwrap(text) == "before  after")
    }

    @Test func unmatchedOpeningTagIsLeftVerbatim() {
        let text = "look <pasted_content id=\"62f5\">\nno close here\n"
        #expect(TranscriptPastedContent.unwrap(text) == text)
    }

    /// A close with the wrong id is not a close for this span, so on its own it
    /// leaves everything verbatim…
    @Test func closeWithADifferentIdDoesNotMatch() {
        let text = "<pasted_content id=\"62f5\">\nbody\n</pasted_content id=\"9999\">"
        #expect(TranscriptPastedContent.unwrap(text) == text)
    }

    /// …and a later close with the right id still ends the span, carrying the
    /// mismatched close along as span text.
    @Test func laterCloseWithTheRightIdStillMatches() {
        let text = "<pasted_content id=\"62f5\">\nbody\n</pasted_content id=\"9999\">\nmore\n"
            + "</pasted_content id=\"62f5\">"
        #expect(TranscriptPastedContent.unwrap(text) == "body\n</pasted_content id=\"9999\">\nmore")
    }

    /// An opening tag whose body holds another opening tag is ambiguous: the
    /// outer tags stay verbatim, and the complete inner span is still unwrapped.
    @Test func nestedOpeningTagLeavesTheOuterTagVerbatim() {
        let text = "<pasted_content id=\"aaaa\">\nouter\n\(wrap("inner", id: "bbbb"))\n</pasted_content id=\"aaaa\">"
        #expect(TranscriptPastedContent.unwrap(text)
            == "<pasted_content id=\"aaaa\">\nouter\ninner\n</pasted_content id=\"aaaa\">")
    }

    @Test func idThatIsNotFourLowercaseHexDigitsIsNotATag() {
        for id in ["62F5", "62f", "62f5a", "zzzz"] {
            let text = wrap("body", id: id)
            #expect(TranscriptPastedContent.unwrap(text) == text, "id \(id)")
        }
    }

    /// Text with no recognised span is returned verbatim, whitespace included.
    @Test func plainTextIsUntouched() {
        let text = "\n  hello **world** <pasted_content  \n\n"
        #expect(TranscriptPastedContent.unwrap(text) == text)
        #expect(TranscriptPastedContent.unwrap("no tags at all") == "no tags at all")
        #expect(TranscriptPastedContent.unwrap("") == "")
    }

    // MARK: - Native renderer

    private func userBlocks(_ text: String) -> [MessageBlock] {
        TranscriptBubbleGeometry.composedBlocks(
            for: .userPrompt(id: "u", text: text, timestamp: nil), badgeUsage: nil, linkResolver: nil)
    }

    /// A composer message renders exactly as the same text typed directly
    /// would: no "pasted" caption, no code styling, markdown applied.
    @Test func composerMessageRendersLikeTypedText() throws {
        let blocks = userBlocks(Self.composerShape)
        let typed = userBlocks(Self.composerTyped)
        try #require(blocks.count == 1, "expected one prose block, got \(blocks)")
        try #require(typed.count == 1, "expected one prose block, got \(typed)")
        guard case .prose(let rendered) = blocks[0], case .prose(let expected) = typed[0] else {
            Issue.record("expected prose, got \(blocks)")
            return
        }
        #expect(rendered.isEqual(to: expected))
        #expect(!rendered.string.hasPrefix("pasted"))
        #expect(!rendered.string.contains("**"), "markdown should be applied")
        let start = (rendered.string as NSString).range(of: "explain").location
        #expect(rendered.attribute(.tbdCodeContext, at: start, effectiveRange: nil) == nil)
        #expect(rendered.attribute(.font, at: start, effectiveRange: nil) as? NSFont
            == TranscriptTextTheme.chatBubble.bodyFont)
    }

    @Test func realShapeRendersAsOneProseBlockWithoutTags() throws {
        let blocks = userBlocks(Self.realShape)
        try #require(blocks.count == 1, "expected one prose block, got \(blocks)")
        let all = allText(blocks)
        #expect(all.contains("something weird happening"))
        #expect(all.contains(Self.pastedPath))
        #expect(all.contains("the context limit"))
        #expect(!all.contains("pasted\n"))
        #expect(!all.contains("<pasted_content"))
        #expect(!all.contains("</pasted_content"))
    }

    /// The gated branch, off side: an assistant message quoting the tags renders
    /// them verbatim.
    @Test func assistantTextKeepsTheTagsVerbatim() {
        let item = TranscriptItem.assistantText(id: "a", text: Self.realShape, timestamp: nil, usage: nil)
        let blocks = TranscriptBubbleGeometry.composedBlocks(for: item, badgeUsage: nil, linkResolver: nil)
        let all = allText(blocks)
        // Markdown typesets the tags' straight quotes as curly ones, so match up
        // to the id's opening quote.
        #expect(all.contains("<pasted_content id="))
        #expect(all.contains("</pasted_content id="))
        // And the renderer's own default is off.
        let direct = allText(MarkdownAttributedRenderer.renderBlocks(Self.realShape, linkResolver: nil))
        #expect(direct == all)
    }

    /// An image marker inside a span is typed text like any other, so it still
    /// becomes an image block.
    @Test func imageMarkerInsideASpanBecomesAnImage() throws {
        let blocks = userBlocks(wrap("look [Image: source: /tmp/acme/1.png] here"))
        try #require(blocks.count == 3, "got \(blocks)")
        guard case .prose(let lead) = blocks[0],
              case .image(let attachment) = blocks[1],
              case .prose(let trail) = blocks[2] else {
            Issue.record("expected prose/image/prose, got \(blocks)")
            return
        }
        #expect(lead.string.contains("look"))
        #expect(attachment.path == "/tmp/acme/1.png")
        #expect(trail.string.contains("here"))
    }

    // MARK: - SwiftUI renderer

    @Test func swiftUISegmentsUnwrapOnlyWhenAsked() {
        #expect(MarkdownSegments.split(Self.composerShape, recognizePastes: true) == [
            .prose(Self.composerTyped)
        ])
        let verbatim = MarkdownSegments.split(Self.composerShape)
        let keepsTags = verbatim.contains { segment in
            if case .prose(let text) = segment { return text.contains("<pasted_content id=") }
            return false
        }
        #expect(keepsTags)
    }

    // MARK: - Estimator

    /// Same precondition as `TranscriptEstimatorAccuracyTests`: the fixture's
    /// wrap behaviour is calibrated at the default 13 pt body size.
    nonisolated private static var hostIsAtCalibratedTextSize: Bool {
        NSFont.preferredFont(forTextStyle: .body).pointSize == 13
    }

    /// The row-height estimate for a user prompt with a paste lands on the
    /// measurement: the estimator unwraps the span as the renderer does rather
    /// than charging the tags as prose.
    @Test(.enabled(if: hostIsAtCalibratedTextSize,
                   "the estimator fixtures are calibrated for a 13 pt system body font"))
    func estimateMatchesMeasurementForAPaste() {
        let text = "why is this here?\n\n"
            + wrap("\(Self.pastedPath)\nsecond line of the paste")
            + "\n\n and where does it come from?"
        for width: CGFloat in [680, 663] {
            let item = TranscriptItem.userPrompt(id: "u", text: text, timestamp: nil)
            let node = TranscriptRenderNode(id: "u", kind: .chatBubble(item), badgeUsage: nil)
            let estimate = TableTranscriptView.Coordinator.estimate(for: node, width: width)
            let bodyWidth = TranscriptBubbleGeometry.bodyWidth(columnWidth: width, role: .user)
            let measured = TranscriptBubbleGeometry.rowHeight(
                blocksHeight: MessageBlockMeasurer().blocksHeight(
                    TranscriptBubbleGeometry.composedBlocks(for: item, badgeUsage: nil, linkResolver: nil),
                    bodyWidth: bodyWidth),
                role: .user)
            #expect(abs(estimate - measured) <= 2, "width \(width): estimate \(estimate), measured \(measured)")
            #expect(estimate <= measured + 0.5, "width \(width): estimate over-reserves")
        }
    }
}
