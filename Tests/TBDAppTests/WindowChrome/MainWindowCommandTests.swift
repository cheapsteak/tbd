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

        let fileModifiers: EventModifiers = [.command, .shift]
        #expect(MainWindowCommand.toggleFilePanel.title == "Toggle File Panel")
        #expect(MainWindowCommand.toggleFilePanel.key.character == "e")
        #expect(MainWindowCommand.toggleFilePanel.modifiers == fileModifiers)
    }

    @Test func settingsHelpNamesTheNextLaunch() {
        #expect(GeneralSettingsTab.appKitSidebarHelp.contains("next launch"))
        #expect(!GeneralSettingsTab.panelTabsHelp.contains("next launch"))
    }
}
