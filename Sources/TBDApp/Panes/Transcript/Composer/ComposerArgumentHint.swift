import Foundation
import TBDShared

/// The dim placeholder shown after an accepted command token, naming what the
/// command takes.
///
/// It appears only once a space follows the token: before that the completion
/// menu is up and already showing the hint on the row, and rendering the same
/// string twice at once is one rendering too many. It retires as soon as an
/// argument is typed, because the placeholder has then been answered.
///
/// Start of the input only. Claude Code expands a command only at the start of a
/// message, so a mid-sentence token takes no arguments and a placeholder there
/// would promise behaviour that does not exist.
///
/// Pure, and a function of the text and the caret alone — so the drawing has no
/// state of its own to get out of step.
enum ComposerArgumentHint {
    static func hint(
        text: String, selectionLocation: Int, commands: [CompletionCommand]
    ) -> String? {
        let ns = text as NSString
        guard ns.length > 0, text.hasPrefix("/") else { return nil }
        guard let spaceRange = ns.range(of: " ").toOptionalRange() else { return nil }
        // Exactly one space, and the caret sitting right after it: the argument
        // position, and nothing typed into it yet.
        let argumentStart = spaceRange.location + spaceRange.length
        guard argumentStart == ns.length, selectionLocation == ns.length else { return nil }

        let name = ns.substring(with: NSRange(location: 1, length: spaceRange.location - 1))
        guard let command = commands.first(where: { $0.name == name }),
              let hint = command.argumentHint, !hint.isEmpty
        else { return nil }
        return hint
    }
}

private extension NSRange {
    /// `NSString.range(of:)` reports `NSNotFound` rather than nil.
    func toOptionalRange() -> NSRange? { location == NSNotFound ? nil : self }
}
