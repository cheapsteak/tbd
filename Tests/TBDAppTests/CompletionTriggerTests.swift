import Foundation
import Testing
@testable import TBDApp

/// When a completion menu opens, expressed as a function of the text and the
/// caret. Everything stateful — Escape suppression, IME composition — belongs to
/// the controller; this is the part that can be stated as a table.
///
/// The negatives are the point. A menu that opens inside `https://` or `foo/bar`
/// is a trap: it steals Return from a person typing a URL.
@Suite("CompletionTrigger")
struct CompletionTriggerTests {

    private func detect(_ text: String, caret: Int? = nil) -> CompletionTrigger.Match? {
        CompletionTrigger.detect(
            text: text, selectionLocation: caret ?? (text as NSString).length)
    }

    // MARK: - Opens

    @Test func atTheStartOfTheInput() throws {
        let match = try #require(detect("/comp"))
        #expect(match.kind == .command)
        #expect(match.query == "comp")
        #expect(match.sigilLocation == 0)
        #expect(match.tokenRange == NSRange(location: 0, length: 5))
    }

    @Test func afterWhitespaceMidSentence() throws {
        let match = try #require(detect("please run /comp"))
        #expect(match.query == "comp")
        #expect(match.sigilLocation == 11)
    }

    @Test func atTheStartOfALine() throws {
        let match = try #require(detect("first line\n/comp"))
        #expect(match.query == "comp")
    }

    @Test func theAtSignOpensTheMentionMenu() throws {
        let match = try #require(detect("ask @Expl"))
        #expect(match.kind == .mention)
        #expect(match.query == "Expl")
    }

    /// A bare sigil is a real trigger: it shows the top rows by frecency.
    @Test func aBareSigilOpensWithAnEmptyQuery() throws {
        let match = try #require(detect("/"))
        #expect(match.query.isEmpty)
    }

    // MARK: - Never a trap

    @Test func neverInsideAWord() {
        #expect(detect("https://example.com") == nil)
        #expect(detect("foo/bar") == nil)
        #expect(detect("me@example.com") == nil)
        #expect(detect("a/b/c") == nil)
    }

    /// A space closes it: the token ended, and what follows is arguments.
    @Test func aSpaceAfterTheTokenClosesIt() {
        #expect(detect("/compact ") == nil)
        #expect(detect("/compact now") == nil)
    }

    /// The caret leaving the token closes it, even though the token is still in
    /// the text. The menu is a suggestion about what is being typed, not a mode.
    @Test func aCaretOutsideTheTokenClosesIt() {
        #expect(detect("/comp and more", caret: 14) == nil)
        // Caret moved back to the very start, before the sigil.
        #expect(detect("/comp", caret: 0) == nil)
    }

    /// Backspacing into the token reopens it — the caret is inside again.
    @Test func aCaretInsideTheTokenReopensIt() throws {
        let match = try #require(detect("/compact", caret: 5))
        #expect(match.query == "comp",
                "the query is what precedes the caret, so filtering follows the edit")
    }

    @Test func emptyTextTriggersNothing() {
        #expect(detect("") == nil)
    }

    /// Multi-scalar characters must not shift the range: `NSTextView` selection
    /// is UTF-16, and a range computed in Character offsets would replace the
    /// wrong bytes on accept.
    @Test func rangesAreInUTF16Units() throws {
        let text = "🎉 /comp"
        let match = try #require(detect(text))
        #expect(match.sigilLocation == 3, "the emoji is two UTF-16 units plus a space")
        #expect(match.tokenRange == NSRange(location: 3, length: 5))
        #expect((text as NSString).substring(with: match.tokenRange) == "/comp")
    }
}
