import AppKit
import Testing
@testable import TBDApp

struct TextFinderCommandTests {
    @Test("Find command uses AppKit text finder action")
    func findCommandUsesAppKitTextFinderAction() {
        #expect(TextFinderCommand.action == #selector(NSResponder.performTextFinderAction(_:)))
        #expect(TextFinderCommand.tag == NSTextFinder.Action.showFindInterface.rawValue)
    }
}
