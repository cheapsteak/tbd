import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The Settings toggle for `session_mod_usage_enabled`: the setter writes
/// through the injected closure and reads the daemon back, and a failed write
/// is surfaced rather than followed by a refresh.
///
/// Every `AppState` here runs over its own throwaway `UserDefaults` suite —
/// `.standard` on this unbundled executable is the developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("Session usage settings")
struct SessionModUsageSettingsTests {
    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-session-usage-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    private static func capabilities(sessionModUsage: Bool) -> DaemonCapabilitiesResult {
        var result = DaemonCapabilitiesResult(controlModeEnabled: false)
        result.sessionModUsageEnabled = sessionModUsage
        return result
    }

    @Test func setterPersistsOnAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.sessionModUsageFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return Self.capabilities(sessionModUsage: true)
            }

            await state.setSessionModUsageEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1, "the toggle must read the daemon back, not its own guess")
            #expect(state.daemonCapabilities?.sessionModUsageEnabled == true)
        }
    }

    @Test func setterPersistsOffAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            state.sessionModUsageFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                Self.capabilities(sessionModUsage: false)
            }

            await state.setSessionModUsageEnabled(false)

            #expect(written == [false])
            #expect(state.daemonCapabilities?.sessionModUsageEnabled == false)
        }
    }

    @Test func setterSurfacesAFailureAndLeavesCapabilitiesAlone() async {
        struct Boom: Error {}
        await withAppState { state in
            var refreshes = 0
            state.sessionModUsageFlagSetter = { @MainActor _ in throw Boom() }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return nil
            }

            await state.setSessionModUsageEnabled(true)

            #expect(refreshes == 0, "a failed write must not be followed by a refresh")
            #expect(state.daemonCapabilities == nil)
            #expect(state.alertMessage != nil)
        }
    }

    @Test func computedFlagFollowsCapabilities() async {
        await withAppState { state in
            #expect(state.daemonCapabilities == nil)
            #expect(state.sessionModUsageEnabled == false)
            state.daemonCapabilities = Self.capabilities(sessionModUsage: true)
            #expect(state.sessionModUsageEnabled == true)
            state.daemonCapabilities = Self.capabilities(sessionModUsage: false)
            #expect(state.sessionModUsageEnabled == false)
        }
    }
}
