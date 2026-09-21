import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Covers Claude Code's terminal-paste wrapper in user prompts
/// (`<pasted_content id="…">…</pasted_content id="…">`): how it is split out of
/// the prompt text, and that both transcript renderers draw the paste as its
/// own captioned block — for USER prompts only — instead of showing the tags.
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

    private func wrap(_ body: String, id: String = "62f5") -> String {
        "<pasted_content id=\"\(id)\">\n\(body)\n</pasted_content id=\"\(id)\">"
    }

    private func allText(_ blocks: [MessageBlock]) -> String {
        blocks.compactMap { block -> String? in
            if case .prose(let s) = block { return s.string }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: - Splitter

    @Test func realShapeSplitsIntoTypedPastedTyped() {
        let segments = TranscriptPastedContent.split(Self.realShape)
        #expect(segments == [
            .typed("something weird happening in my tbd worktrees for acme. e.g. "),
            .pasted(id: "62f5", text: Self.pastedPath),
            .typed(" the context limit seems to be 200k for new sessions, where does that come from? "
                + "it immediately exceeds on the first message and triggers compaction")
        ])
    }

    @Test func twoPastesInOneMessage() {
        let text = "first\n\(wrap("one", id: "aaaa"))\nmiddle\n\(wrap("two\nlines", id: "0b1c"))\nlast"
        #expect(TranscriptPastedContent.split(text) == [
            .typed("first"),
            .pasted(id: "aaaa", text: "one"),
            .typed("middle"),
            .pasted(id: "0b1c", text: "two\nlines"),
            .typed("last")
        ])
    }

    @Test func pasteWithNoTypedTextIsASinglePastedSegment() {
        #expect(TranscriptPastedContent.split(wrap("only this")) == [.pasted(id: "62f5", text: "only this")])
    }

    /// Two pastes separated only by blank lines: the separator is not a typed
    /// segment of its own.
    @Test func whitespaceBetweenPastesIsDropped() {
        let text = wrap("a", id: "1111") + "\n\n" + wrap("b", id: "2222")
        #expect(TranscriptPastedContent.split(text) == [
            .pasted(id: "1111", text: "a"),
            .pasted(id: "2222", text: "b")
        ])
    }

    /// Only the wrapper's own newline on each side is removed; the paste's own
    /// blank lines and indentation survive.
    @Test func onlyOneWrapperNewlineIsStrippedOnEachSide() {
        let text = "<pasted_content id=\"62f5\">\n\n  indented\n\n</pasted_content id=\"62f5\">"
        #expect(TranscriptPastedContent.split(text) == [.pasted(id: "62f5", text: "\n  indented\n")])
    }

    @Test func emptyPasteIsAnEmptyPastedSegment() {
        let text = "before <pasted_content id=\"62f5\">\n</pasted_content id=\"62f5\"> after"
        #expect(TranscriptPastedContent.split(text) == [
            .typed("before "),
            .pasted(id: "62f5", text: ""),
            .typed(" after")
        ])
    }

    @Test func unmatchedOpeningTagIsLeftVerbatim() {
        let text = "look <pasted_content id=\"62f5\">\nno close here"
        #expect(TranscriptPastedContent.split(text) == [.typed(text)])
    }

    /// A close with the wrong id is not a close for this span, so on its own it
    /// leaves everything verbatim…
    @Test func closeWithADifferentIdDoesNotMatch() {
        let text = "<pasted_content id=\"62f5\">\nbody\n</pasted_content id=\"9999\">"
        #expect(TranscriptPastedContent.split(text) == [.typed(text)])
    }

    /// …and a later close with the right id still ends the span, carrying the
    /// mismatched close along as pasted text.
    @Test func laterCloseWithTheRightIdStillMatches() {
        let text = "<pasted_content id=\"62f5\">\nbody\n</pasted_content id=\"9999\">\nmore\n"
            + "</pasted_content id=\"62f5\">"
        #expect(TranscriptPastedContent.split(text) == [
            .pasted(id: "62f5", text: "body\n</pasted_content id=\"9999\">\nmore")
        ])
    }

    /// An opening tag whose body holds another opening tag is ambiguous: the
    /// outer tag stays verbatim, and the complete inner span is still found.
    @Test func nestedOpeningTagLeavesTheOuterTagVerbatim() {
        let text = "<pasted_content id=\"aaaa\">\nouter\n\(wrap("inner", id: "bbbb"))\n</pasted_content id=\"aaaa\">"
        #expect(TranscriptPastedContent.split(text) == [
            .typed("<pasted_content id=\"aaaa\">\nouter"),
            .pasted(id: "bbbb", text: "inner"),
            .typed("</pasted_content id=\"aaaa\">")
        ])
    }

    @Test func idThatIsNotFourLowercaseHexDigitsIsNotATag() {
        for id in ["62F5", "62f", "62f5a", "zzzz"] {
            let text = wrap("body", id: id)
            #expect(TranscriptPastedContent.split(text) == [.typed(text)], "id \(id)")
        }
    }

    /// Text without the tag takes the fast path and is returned verbatim,
    /// whitespace included.
    @Test func plainTextIsUntouched() {
        let text = "\n  hello **world** <pasted_content  \n\n"
        #expect(TranscriptPastedContent.split(text) == [.typed(text)])
        #expect(TranscriptPastedContent.split("no tags at all") == [.typed("no tags at all")])
        #expect(TranscriptPastedContent.split("") == [.typed("")])
    }

    // MARK: - Native renderer

    private func userBlocks(_ text: String) -> [MessageBlock] {
        TranscriptBubbleGeometry.composedBlocks(
            for: .userPrompt(id: "u", text: text, timestamp: nil), badgeUsage: nil, linkResolver: nil)
    }

    @Test func userPromptRendersThePasteAsItsOwnCaptionedBlock() throws {
        let blocks = userBlocks(Self.realShape)
        try #require(blocks.count == 3, "expected typed / pasted / typed, got \(blocks)")
        guard case .prose(let paste) = blocks[1] else {
            Issue.record("expected the paste as a prose block, got \(blocks[1])")
            return
        }
        #expect(paste.string == "pasted\n" + Self.pastedPath)
        // The caption is chrome; the body is set like a code block.
        let caption = paste.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(caption == TranscriptPastedBlock.captionFont)
        let bodyStart = (paste.string as NSString).range(of: Self.pastedPath).location
        let bodyFont = paste.attribute(.font, at: bodyStart, effectiveRange: nil) as? NSFont
        #expect(bodyFont == TranscriptTextTheme.chatBubble.codeFont)
        #expect(paste.attribute(.backgroundColor, at: bodyStart, effectiveRange: nil) != nil)
        #expect(paste.attribute(.tbdCodeContext, at: bodyStart, effectiveRange: nil) != nil)

        let all = allText(blocks)
        #expect(all.contains("something weird happening"))
        #expect(all.contains("the context limit"))
        #expect(!all.contains("<pasted_content"))
        #expect(!all.contains("</pasted_content"))
    }

    /// Pasted text is never markdown: `**` and `#` survive as typed characters.
    @Test func pastedTextIsNotParsedAsMarkdown() throws {
        let blocks = userBlocks(wrap("# not a heading\n**not bold**"))
        try #require(blocks.count == 1)
        guard case .prose(let paste) = blocks[0] else {
            Issue.record("expected prose")
            return
        }
        #expect(paste.string == "pasted\n# not a heading\n**not bold**")
    }

    @Test func emptyPasteRendersJustTheCaption() throws {
        let blocks = userBlocks("before\n<pasted_content id=\"62f5\">\n</pasted_content id=\"62f5\">")
        try #require(blocks.count == 2)
        guard case .prose(let paste) = blocks[1] else {
            Issue.record("expected prose")
            return
        }
        #expect(paste.string == "pasted")
    }

    /// The gated branch, off side: an assistant message quoting the tags renders
    /// them verbatim, as one prose block.
    @Test func assistantTextKeepsTheTagsVerbatim() {
        let item = TranscriptItem.assistantText(id: "a", text: Self.realShape, timestamp: nil, usage: nil)
        let blocks = TranscriptBubbleGeometry.composedBlocks(for: item, badgeUsage: nil, linkResolver: nil)
        #expect(blocks.count == 1)
        let all = allText(blocks)
        #expect(all.contains("<pasted_content id=\"62f5\">"))
        #expect(all.contains("</pasted_content id=\"62f5\">"))
        #expect(!all.contains("pasted\n/Users"))
        // And the renderer's own default is off.
        let direct = allText(MarkdownAttributedRenderer.renderBlocks(Self.realShape, linkResolver: nil))
        #expect(direct == all)
    }

    /// A path inside a paste is linked, and styled like a link in code.
    @Test func pathInAPasteIsLinkedWithCodeStyling() throws {
        let resolve: TranscriptPathResolver = { $0 == "docs/a.md" ? "/w/docs/a.md" : nil }
        let blocks = MarkdownAttributedRenderer.renderBlocks(
            wrap("see docs/a.md"), linkResolver: resolve, recognizePastes: true)
        let first = try #require(blocks.first)
        guard case .prose(let paste) = first else {
            Issue.record("expected prose")
            return
        }
        let location = (paste.string as NSString).range(of: "docs/a.md").location
        let url = paste.attribute(.link, at: location, effectiveRange: nil) as? URL
        #expect(url?.path == "/w/docs/a.md")
        #expect(paste.attribute(.underlineStyle, at: location, effectiveRange: nil) as? Int
            == NSUnderlineStyle.single.rawValue)
    }

    /// Image markers in the typed text still become image blocks beside a paste.
    @Test func imageMarkersInTypedTextStillWorkAlongsideAPaste() throws {
        let text = "look [Image: source: /tmp/acme/1.png] here\n\n" + wrap("pasted line")
        let blocks = userBlocks(text)
        try #require(blocks.count == 4, "got \(blocks)")
        guard case .prose(let lead) = blocks[0],
              case .image(let attachment) = blocks[1],
              case .prose(let trail) = blocks[2],
              case .prose(let paste) = blocks[3] else {
            Issue.record("expected prose/image/prose/paste, got \(blocks)")
            return
        }
        #expect(lead.string.contains("look"))
        #expect(attachment.path == "/tmp/acme/1.png")
        #expect(trail.string.contains("here"))
        #expect(paste.string == "pasted\npasted line")
    }

    /// A marker inside the paste is pasted text, not an attachment.
    @Test func imageMarkerInsideAPasteStaysText() {
        let blocks = userBlocks(wrap("[Image: source: /tmp/acme/1.png]"))
        #expect(blocks.count == 1)
        #expect(allText(blocks).contains("[Image: source: /tmp/acme/1.png]"))
    }

    // MARK: - SwiftUI renderer

    @Test func swiftUISegmentsSplitPastesOnlyWhenAsked() {
        #expect(MarkdownSegments.split(Self.realShape, recognizePastes: true) == [
            .prose("something weird happening in my tbd worktrees for acme. e.g. "),
            .pasted(id: "62f5", text: Self.pastedPath),
            .prose(" the context limit seems to be 200k for new sessions, where does that come from? "
                + "it immediately exceeds on the first message and triggers compaction")
        ])
        let verbatim = MarkdownSegments.split(Self.realShape)
        let hasPaste = verbatim.contains { segment in
            if case .pasted = segment { return true }
            return false
        }
        #expect(!hasPaste)
    }

    // MARK: - Estimator

    /// Same precondition as `TranscriptEstimatorAccuracyTests`: the fixture's
    /// wrap behaviour is calibrated at the default 13 pt body size.
    nonisolated private static var hostIsAtCalibratedTextSize: Bool {
        NSFont.preferredFont(forTextStyle: .body).pointSize == 13
    }

    /// The row-height estimate for a user prompt with a paste lands on the
    /// measurement: the estimator mirrors the paste block's structure (caption
    /// line, spacing, code lines) rather than charging the tags as prose.
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
