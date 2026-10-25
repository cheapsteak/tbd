import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The Settings toggles for daemon-held feature flags. Each setter writes the
/// gesture through its injected closure and reads the daemon back, and a
/// failed write is surfaced rather than followed by a refresh. The setters
/// share that shape, so one parameterized suite runs every one of them down
/// both branches and the failure path; the contracts only one flag has follow
/// the shared tests.
///
/// Every `AppState` here runs over its own throwaway `UserDefaults` suite —
/// `.standard` on this unbundled executable is the developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("Daemon flag settings")
struct DaemonFlagSettingsTests {
    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-daemon-flag-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    // MARK: - The shared setter shape

    @Test(arguments: DaemonFlagToggle.allCases)
    func setterPersistsOnAndRefreshesCapabilities(_ flag: DaemonFlagToggle) async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            flag.installSetter(on: state) { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return flag.capabilities(reporting: true)
            }

            await flag.set(true, on: state)

            #expect(written == [true])
            #expect(refreshes == 1, "the toggle must read the daemon back, not its own guess")
            #expect(flag.reported(by: state.daemonCapabilities) == true)
        }
    }

    /// The off branch is its own test rather than a second assertion: a setter
    /// that ignored its argument would pass the on-only test.
    @Test(arguments: DaemonFlagToggle.allCases)
    func setterPersistsOffAndRefreshesCapabilities(_ flag: DaemonFlagToggle) async {
        await withAppState { state in
            var written: [Bool] = []
            flag.installSetter(on: state) { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                flag.capabilities(reporting: false)
            }

            await flag.set(false, on: state)

            #expect(written == [false])
            #expect(flag.reported(by: state.daemonCapabilities) == false)
        }
    }

    /// A write the daemon refused must not be followed by a read-back, and must
    /// not leave the toggle showing a state nothing persisted.
    @Test(arguments: DaemonFlagToggle.allCases)
    func setterSurfacesAFailureAndLeavesCapabilitiesAlone(_ flag: DaemonFlagToggle) async {
        struct Boom: Error {}
        await withAppState { state in
            var refreshes = 0
            flag.installSetter(on: state) { @MainActor _ in throw Boom() }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return nil
            }

            await flag.set(true, on: state)

            #expect(refreshes == 0, "a failed write must not be followed by a refresh")
            #expect(state.daemonCapabilities == nil)
            #expect(state.alertMessage != nil)
        }
    }

    // MARK: - Contracts one flag has

    @Test func sessionModUsageFlagFollowsCapabilities() async {
        await withAppState { state in
            #expect(state.daemonCapabilities == nil)
            #expect(state.sessionModUsageEnabled == false)
            state.daemonCapabilities = DaemonFlagToggle.sessionModUsage.capabilities(reporting: true)
            #expect(state.sessionModUsageEnabled == true)
            state.daemonCapabilities = DaemonFlagToggle.sessionModUsage.capabilities(reporting: false)
            #expect(state.sessionModUsageEnabled == false)
        }
    }

    @Test func transcriptPromptAnswerFlagFollowsCapabilities() async {
        await withAppState { state in
            #expect(state.daemonCapabilities == nil)
            #expect(state.transcriptPromptAnswerEnabled == false)
            state.daemonCapabilities = DaemonFlagToggle.transcriptPromptAnswer.capabilities(reporting: true)
            #expect(state.transcriptPromptAnswerEnabled == true)
            state.daemonCapabilities = DaemonFlagToggle.transcriptPromptAnswer.capabilities(reporting: false)
            #expect(state.transcriptPromptAnswerEnabled == false)
        }
    }

    /// The help string carries promises the operator acts on: the change
    /// applies to sessions started after it, and only where Claude Code loads
    /// TBD's mod. Pinned so a rewrite that drops either has to be deliberate.
    @Test func transcriptStreamingHelpStatesWhenTheChangeAppliesAndWhatItNeeds() {
        #expect(
            AppState.transcriptStreamingHelp.contains(
                "Applies to sessions started after you turn it on, and only where Claude Code loads TBD's mod."))
        #expect(AppState.transcriptStreamingHelp.contains("Off by default (soaking)."))
    }

    @Test("the remote transcript live sync toggle help names the hint requirement")
    func remoteTranscriptLiveSyncHelpNamesTheHintRequirement() {
        #expect(GeneralSettingsTab.remoteTranscriptLiveSyncHelp.contains("transcript hint"))
    }

    @Test("a daemon that does not report remote transcript live sync reads it as off")
    func unreportedRemoteTranscriptLiveSyncReadsOff() throws {
        let decoded = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(#"{"controlModeEnabled":false}"#.utf8))
        #expect(decoded.remoteTranscriptLiveSyncEnabled == false)
        #expect(Config.remoteTranscriptLiveSyncEnabledDefault == false, "the flag ships off while it soaks")
    }
}

/// One case per daemon flag whose Settings toggle goes through the shared
/// write-then-read-back setter shape. Adding a flag with that shape is a case
/// here and an arm in each switch, and the three shared tests cover it.
enum DaemonFlagToggle: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case programStatus
    case prPollSchedule
    case sessionModUsage
    case transcriptPromptAnswer
    case transcriptStreaming
    case remoteTranscriptLiveSync

    var testDescription: String { rawValue }

    /// Replace the closure this flag's setter writes the gesture through.
    @MainActor
    func installSetter(on state: AppState, _ setter: @escaping @MainActor (Bool) async throws -> Void) {
        switch self {
        case .programStatus: state.programStatusFlagSetter = setter
        case .prPollSchedule: state.prPollScheduleFlagSetter = setter
        case .sessionModUsage: state.sessionModUsageFlagSetter = setter
        case .transcriptPromptAnswer: state.transcriptPromptAnswerFlagSetter = setter
        case .transcriptStreaming: state.transcriptStreamingFlagSetter = setter
        case .remoteTranscriptLiveSync: state.remoteTranscriptLiveSyncFlagSetter = setter
        }
    }

    /// The toggle's gesture: the setter under test.
    @MainActor
    func set(_ enabled: Bool, on state: AppState) async {
        switch self {
        case .programStatus: await state.setProgramStatusEnabled(enabled)
        case .prPollSchedule: await state.setPRPollScheduleEnabled(enabled)
        case .sessionModUsage: await state.setSessionModUsageEnabled(enabled)
        case .transcriptPromptAnswer: await state.setTranscriptPromptAnswerEnabled(enabled)
        case .transcriptStreaming: await state.setTranscriptStreamingEnabled(enabled)
        case .remoteTranscriptLiveSync: await state.setRemoteTranscriptLiveSyncEnabled(enabled)
        }
    }

    /// A capabilities reply that reports this flag as `enabled`.
    func capabilities(reporting enabled: Bool) -> DaemonCapabilitiesResult {
        var result = DaemonCapabilitiesResult(controlModeEnabled: false)
        switch self {
        case .programStatus: result.programStatusEnabled = enabled
        case .prPollSchedule: result.prPollScheduleEnabled = enabled
        case .sessionModUsage: result.sessionModUsageEnabled = enabled
        case .transcriptPromptAnswer: result.transcriptPromptAnswerEnabled = enabled
        case .transcriptStreaming: result.transcriptStreamingEnabled = enabled
        case .remoteTranscriptLiveSync: result.remoteTranscriptLiveSyncEnabled = enabled
        }
        return result
    }

    /// What `capabilities` reports for this flag, or nil when there is no reply.
    func reported(by capabilities: DaemonCapabilitiesResult?) -> Bool? {
        guard let capabilities else { return nil }
        switch self {
        case .programStatus: return capabilities.programStatusEnabled
        case .prPollSchedule: return capabilities.prPollScheduleEnabled
        case .sessionModUsage: return capabilities.sessionModUsageEnabled
        case .transcriptPromptAnswer: return capabilities.transcriptPromptAnswerEnabled
        case .transcriptStreaming: return capabilities.transcriptStreamingEnabled
        case .remoteTranscriptLiveSync: return capabilities.remoteTranscriptLiveSyncEnabled
        }
    }
}
