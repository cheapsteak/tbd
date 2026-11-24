import Foundation
import Testing
@testable import TBDApp
import TestSupport

/// The tab bar sits below the detail pagers, where `@AppStorage` reads
/// `.standard`, so it reads the reset-time style through `AppState`, from the
/// store `AppState` was built with.
@MainActor
@Suite("AppState.usageResetTimeStyle")
struct AppStateUsageResetTimeStyleTests {
    @Test func readsTheStyleFromItsOwnStore() {
        withTestDefaults("UsageResetTimeStyle.Store") { defaults in
            let state = AppState(userDefaults: defaults)
            let unset = state.usageResetTimeStyle
            #expect(unset == .timeOfReset)

            defaults.set(
                ProfileUsagePresentation.ResetTimeStyle.timeUntilReset.rawValue,
                forKey: AppState.usageResetTimeStyleKey)
            let countdown = state.usageResetTimeStyle
            #expect(countdown == .timeUntilReset)
        }
    }

    @Test func unknownValueReadsTimeOfReset() {
        withTestDefaults("UsageResetTimeStyle.Unknown") { defaults in
            defaults.set("acme", forKey: AppState.usageResetTimeStyleKey)
            let state = AppState(userDefaults: defaults)
            let style = state.usageResetTimeStyle
            #expect(style == .timeOfReset)
        }
    }
}
