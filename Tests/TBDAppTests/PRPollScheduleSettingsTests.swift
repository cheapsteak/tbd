import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The Settings toggle for `pr_poll_schedule_enabled`: the setter writes
/// through the injected closure and reads the daemon back, and a failed write
/// is surfaced rather than followed by a refresh.
///
/// Every `AppState` here runs over its own throwaway `UserDefaults` suite —
/// `.standard` on this unbundled executable is the developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("PR poll schedule settings")
struct PRPollScheduleSettingsTests {
    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-pr-poll-schedule-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    private static func capabilities(prPollSchedule: Bool) -> DaemonCapabilitiesResult {
        var result = DaemonCapabilitiesResult(controlModeEnabled: false)
        result.prPollScheduleEnabled = prPollSchedule
        return result
    }

    @Test func setterPersistsOnAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.prPollScheduleFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return Self.capabilities(prPollSchedule: true)
            }

            await state.setPRPollScheduleEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1, "the toggle must read the daemon back, not its own guess")
            #expect(state.daemonCapabilities?.prPollScheduleEnabled == true)
        }
    }

    @Test func setterPersistsOffAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            state.prPollScheduleFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                Self.capabilities(prPollSchedule: false)
            }

            await state.setPRPollScheduleEnabled(false)

            #expect(written == [false])
            #expect(state.daemonCapabilities?.prPollScheduleEnabled == false)
        }
    }

    @Test func setterSurfacesAFailureAndLeavesCapabilitiesAlone() async {
        struct Boom: Error {}
        await withAppState { state in
            var refreshes = 0
            state.prPollScheduleFlagSetter = { @MainActor _ in throw Boom() }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return nil
            }

            await state.setPRPollScheduleEnabled(true)

            #expect(refreshes == 0, "a failed write must not be followed by a refresh")
            #expect(state.daemonCapabilities == nil)
            #expect(state.alertMessage != nil)
        }
    }
}
