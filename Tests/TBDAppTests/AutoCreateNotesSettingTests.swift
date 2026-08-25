import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("Automatic Notes setting")
@MainActor
struct AutoCreateNotesSettingTests {
    @Test("defaults to creating Notes tabs")
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

    @Test("help text names only fresh-branch conversation revival")
    func helpTextNamesPreciseException() {
        #expect(
            GeneralSettingsTab.autoCreateNotesHelp ==
                "Turn this off to skip empty Notes tabs in ordinary new worktrees. " +
                "Conversations revived on a fresh branch still receive their populated provenance note."
        )
    }
}
