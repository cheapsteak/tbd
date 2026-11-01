import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("Automatic Notes setting")
@MainActor
struct AutoCreateNotesSettingTests {
    @Test("defaults to creating a starter note")
    func defaultsEnabled() {
        let state = AppState()

        #expect(state.autoCreateNotesEnabled)
    }

    @Test("loads a disabled preference from the config-bearing response")
    func loadsDisabledPreference() async {
        let state = AppState()
        state.modelProfilesFetcher = {
            ModelProfileListResult(profiles: [], autoCreateNotesEnabled: false)
        }

        await state.loadModelProfiles()

        #expect(!state.autoCreateNotesEnabled)
    }

    @Test("loads an enabled preference from the config-bearing response")
    func loadsEnabledPreference() async {
        let state = AppState()
        state.autoCreateNotesEnabled = false
        state.modelProfilesFetcher = {
            ModelProfileListResult(profiles: [], autoCreateNotesEnabled: true)
        }

        await state.loadModelProfiles()

        #expect(state.autoCreateNotesEnabled)
    }

    @Test("successful update changes the local mirror")
    func successfulUpdateChangesMirror() async {
        let state = AppState()
        state.autoCreateNotesEnabled = true
        state.autoCreateNotesSetter = { _ in }

        await state.setAutoCreateNotesEnabled(false)

        #expect(!state.autoCreateNotesEnabled)
    }

    @Test("failed update keeps the local mirror")
    func failedUpdateKeepsMirror() async {
        struct Rejected: Error {}

        let state = AppState()
        state.autoCreateNotesEnabled = true
        state.autoCreateNotesSetter = { _ in throw Rejected() }

        await state.setAutoCreateNotesEnabled(false)

        #expect(state.autoCreateNotesEnabled)
        #expect(state.alertIsError)
        #expect(state.alertMessage != nil)
    }

    @Test("the toggle names a starter note, which nothing opens by itself")
    func labelNamesAStarterNote() {
        #expect(GeneralSettingsTab.autoCreateNotesLabel == "Create a starter note for new worktrees")
    }

    @Test("help text names the Notes button and only fresh-branch conversation revival")
    func helpTextNamesPreciseException() {
        let expected: String =
            "On: each ordinary new worktree gets an empty \"Notes\" note, which opens from the Notes button " +
            "in the tab bar. Turn this off to skip it. " +
            "Conversations revived on a fresh branch still receive their populated provenance note."
        #expect(GeneralSettingsTab.autoCreateNotesHelp == expected)
    }
}
