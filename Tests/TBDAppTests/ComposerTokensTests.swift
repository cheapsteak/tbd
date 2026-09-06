import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The inline `[Image #N]` token is the anchor: it decides WHETHER an image is
/// sent and WHERE it sits among the words. A side map holds token → staged file;
/// the text is what decides.
///
/// The deletion and edit cases are the ones that matter. A token the person
/// removed must drop its image silently-but-visibly (the strip shows it
/// detached), and a token they typed over must not still smuggle a file into the
/// message.
@Suite("ComposerTokens")
struct ComposerTokensTests {

    @Test func theTokenTextIsStable() {
        #expect(ComposerTokens.text(for: 1) == "[Image #1]")
        #expect(ComposerTokens.text(for: 12) == "[Image #12]")
    }

    @Test func scanFindsTokensInOrderWithTheirRanges() {
        let text = "look at [Image #1] and [Image #2] please"
        let tokens = ComposerTokens.scan(text)
        #expect(tokens.map(\.number) == [1, 2])
        let ns = text as NSString
        #expect(ns.substring(with: tokens[0].range) == "[Image #1]")
        #expect(ns.substring(with: tokens[1].range) == "[Image #2]")
    }

    @Test func splittingProducesTextAndImagePartsInOrder() {
        let parts = ComposerTokens.parts(
            text: "look at [Image #1] and tell me",
            paths: [1: "/tmp/a.png"])
        #expect(parts == [
            .text("look at "),
            .imagePath("/tmp/a.png"),
            .text(" and tell me"),
        ])
    }

    @Test func emptyTextPartsAreSkipped() {
        let parts = ComposerTokens.parts(
            text: "[Image #1][Image #2]",
            paths: [1: "/tmp/a.png", 2: "/tmp/b.png"])
        #expect(parts == [.imagePath("/tmp/a.png"), .imagePath("/tmp/b.png")])
    }

    /// **A deleted token drops its image.** The map still holds the file; the
    /// text is what decides.
    @Test func aDeletedTokenDropsItsImage() {
        let parts = ComposerTokens.parts(
            text: "just words now",
            paths: [1: "/tmp/a.png"])
        #expect(parts == [.text("just words now")])
    }

    /// An edited token no longer matches, so it is literal text and its image is
    /// dropped — exactly what Claude Code's own composer does to the same
    /// placeholders.
    @Test func anEditedTokenIsLiteralTextAndDropsItsImage() {
        let parts = ComposerTokens.parts(
            text: "look at [Image #1x]",
            paths: [1: "/tmp/a.png"])
        #expect(parts == [.text("look at [Image #1x]")])
    }

    /// A token whose file was never staged is literal text too — never a part
    /// pointing at nothing.
    @Test func aTokenWithNoStagedFileStaysText() {
        let parts = ComposerTokens.parts(text: "look at [Image #9]", paths: [:])
        #expect(parts == [.text("look at [Image #9]")])
    }

    /// The not-running form: an argv prompt cannot carry attachments, so each
    /// token becomes the quoted path inline. The sentence reads the same and
    /// Claude reads the files with its Read tool.
    @Test func flatteningReplacesTokensWithQuotedPaths() {
        #expect(ComposerTokens.flattened(
            text: "look at [Image #1] and tell me",
            paths: [1: "/tmp/a.png"])
            == "look at '/tmp/a.png' and tell me")
    }

    @Test func flatteningLeavesAnUnstagedTokenAlone() {
        #expect(ComposerTokens.flattened(text: "see [Image #9]", paths: [:])
            == "see [Image #9]")
    }

    @Test func attachedNumbersAreWhatTheTextHolds() {
        #expect(ComposerTokens.attachedNumbers(in: "a [Image #1] b [Image #3]") == [1, 3])
        #expect(ComposerTokens.attachedNumbers(in: "nothing here").isEmpty)
    }

    /// Ranges are UTF-16, so an emoji ahead of a token does not shift the split.
    @Test func splittingSurvivesMultiScalarText() {
        let parts = ComposerTokens.parts(
            text: "🎉 [Image #1] 🎉", paths: [1: "/tmp/a.png"])
        #expect(parts == [.text("🎉 "), .imagePath("/tmp/a.png"), .text(" 🎉")])
    }
}
