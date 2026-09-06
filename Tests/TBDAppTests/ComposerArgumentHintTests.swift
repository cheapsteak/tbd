import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The dim placeholder after an accepted command token.
///
/// It is a function of the text and the caret, exactly like the trigger
/// detector, so the drawing has no state to get wrong: the hint either applies
/// right now or it does not.
@Suite("ComposerArgumentHint")
struct ComposerArgumentHintTests {

    private let commands = [
        CompletionCommand(
            name: "compact", description: "d", argumentHint: "[instructions]"),
        CompletionCommand(name: "clear", description: "d"),
    ]

    private func hint(_ text: String, caret: Int? = nil) -> String? {
        ComposerArgumentHint.hint(
            text: text, selectionLocation: caret ?? (text as NSString).length,
            commands: commands)
    }

    @Test func aSpaceAfterTheTokenShowsTheHint() {
        #expect(hint("/compact ") == "[instructions]")
    }

    /// Before the space, the completion MENU is showing and owns the hint. Two
    /// renderings of the same string at once would be one too many.
    @Test func noSpaceMeansNoHint() {
        #expect(hint("/compact") == nil)
    }

    /// Once an argument is typed the placeholder has been answered.
    @Test func anArgumentTypedRetiresTheHint() {
        #expect(hint("/compact be brief") == nil)
    }

    @Test func aCommandWithNoHintShowsNothing() {
        #expect(hint("/clear ") == nil)
    }

    /// Claude Code expands a command only at the START of a message, so a
    /// mid-sentence token takes no arguments and gets no placeholder.
    @Test func aMidSentenceTokenGetsNoHint() {
        #expect(hint("please /compact ") == nil)
    }

    @Test func anUnknownCommandGetsNoHint() {
        #expect(hint("/nonesuch ") == nil)
    }

    /// The caret has to be where the argument would go. Parked back inside the
    /// token, the person is editing the name, not filling in an argument.
    @Test func theCaretMustBeAtTheArgumentPosition() {
        #expect(hint("/compact ", caret: 4) == nil)
    }

    @Test func emptyTextShowsNothing() {
        #expect(hint("") == nil)
    }
}
