import AppKit
import Testing
@testable import TBDApp

@MainActor
struct TextFinderCommandTests {
    @Test("Find command uses AppKit text finder action")
    func findCommandUsesAppKitTextFinderAction() {
        #expect(TextFinderCommand.action == #selector(NSResponder.performTextFinderAction(_:)))
        #expect(TextFinderCommand.tag(for: .showFindInterface) == NSTextFinder.Action.showFindInterface.rawValue)
    }

    @Test("Find next and previous commands use AppKit text finder tags")
    func findNextAndPreviousCommandsUseAppKitTextFinderTags() {
        #expect(TextFinderCommand.tag(for: .nextMatch) == NSTextFinder.Action.nextMatch.rawValue)
        #expect(TextFinderCommand.tag(for: .previousMatch) == NSTextFinder.Action.previousMatch.rawValue)
    }
}
