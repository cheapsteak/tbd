import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The Settings toggle for `transcript_prompt_answer_enabled`: the setter writes
/// through the injected closure and reads the daemon back, and a failed write
/// is surfaced rather than followed by a refresh.
///
/// Every `AppState` here runs over its own throwaway `UserDefaults` suite —
/// `.standard` on this unbundled executable is the developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("Transcript prompt answer settings")
struct TranscriptPromptAnswerSettingsTests {
    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-transcript-prompt-answer-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    private static func capabilities(transcriptPromptAnswer: Bool) -> DaemonCapabilitiesResult {
        var result = DaemonCapabilitiesResult(controlModeEnabled: false)
        result.transcriptPromptAnswerEnabled = transcriptPromptAnswer
        return result
    }

    @Test func setterPersistsOnAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.transcriptPromptAnswerFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return Self.capabilities(transcriptPromptAnswer: true)
            }

            await state.setTranscriptPromptAnswerEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1, "the toggle must read the daemon back, not its own guess")
            #expect(state.daemonCapabilities?.transcriptPromptAnswerEnabled == true)
        }
    }

    @Test func setterPersistsOffAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            state.transcriptPromptAnswerFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                Self.capabilities(transcriptPromptAnswer: false)
            }

            await state.setTranscriptPromptAnswerEnabled(false)

            #expect(written == [false])
            #expect(state.daemonCapabilities?.transcriptPromptAnswerEnabled == false)
        }
    }

    @Test func setterSurfacesAFailureAndLeavesCapabilitiesAlone() async {
        struct Boom: Error {}
        await withAppState { state in
            var refreshes = 0
            state.transcriptPromptAnswerFlagSetter = { @MainActor _ in throw Boom() }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return nil
            }

            await state.setTranscriptPromptAnswerEnabled(true)

            #expect(refreshes == 0, "a failed write must not be followed by a refresh")
            #expect(state.daemonCapabilities == nil)
            #expect(state.alertMessage != nil)
        }
    }

    @Test func computedFlagFollowsCapabilities() async {
        await withAppState { state in
            #expect(state.daemonCapabilities == nil)
            #expect(state.transcriptPromptAnswerEnabled == false)
            state.daemonCapabilities = Self.capabilities(transcriptPromptAnswer: true)
            #expect(state.transcriptPromptAnswerEnabled == true)
            state.daemonCapabilities = Self.capabilities(transcriptPromptAnswer: false)
            #expect(state.transcriptPromptAnswerEnabled == false)
        }
    }
}
