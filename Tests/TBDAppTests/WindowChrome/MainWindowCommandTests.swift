import SwiftUI
import Testing
@testable import TBDApp

@MainActor
@Suite("Main window commands")
struct MainWindowCommandTests {
    @Test func threeCommandsWithTheirShortcuts() {
        let all = MainWindowCommand.allCases
        #expect(all.count == 3)

        #expect(MainWindowCommand.back.title == "Back")
        #expect(MainWindowCommand.back.key.character == "[")
        #expect(MainWindowCommand.back.modifiers == .command)

        #expect(MainWindowCommand.forward.title == "Forward")
        #expect(MainWindowCommand.forward.key.character == "]")
        #expect(MainWindowCommand.forward.modifiers == .command)

        let changesModifiers: EventModifiers = [.command, .shift]
        #expect(MainWindowCommand.toggleChanges.title == "Toggle Changes")
        #expect(MainWindowCommand.toggleChanges.key.character == "e")
        #expect(MainWindowCommand.toggleChanges.modifiers == changesModifiers)
    }

    @Test func settingsHelpNamesTheNextLaunch() {
        #expect(GeneralSettingsTab.appKitSidebarHelp.contains("next launch"))
    }
}
