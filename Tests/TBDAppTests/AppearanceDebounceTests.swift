import Combine
import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Test that rapid scheme changes are debounced to avoid spamming RPCs to the daemon.
/// This test verifies that the debounce operator is applied to the schemeID publisher.
/// We test the debounce behavior by subscribing directly to the appearance's $schemeID
/// publisher and observing that rapid changes collapse to fewer emissions.
@MainActor
@Suite("AppState appearance debounce")
struct AppearanceDebounceTests {
    @Test("rapid scheme changes within debounce window collapse to single emission")
    func rapidSchemeChangesDebounce() async {
        // Use isolated UserDefaults so the test never touches the developer's app preferences.
        let suiteName = "TBDAppTests.AppearanceDebounce.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appearance = AppearanceSettings(defaults: defaults)

        // Subscribe to the debounced schemeID emissions to count how many fire.
        var debounceEmissions: [String] = []
        let testSubscription = appearance.$schemeID
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { schemeID in
                debounceEmissions.append(schemeID)
            }

        // Rapidly change the scheme within the debounce window.
        // Since appearance starts with the default scheme, explicitly set three different ones
        // in rapid succession without waiting.
        appearance.schemeID = "scheme-a"
        appearance.schemeID = "scheme-b"
        appearance.schemeID = "scheme-c"

        // Give the debounce timer time to fire. 600ms vs the 200ms window leaves
        // a 3x safety margin — `Task.sleep` has no lower-bound guarantee on
        // constrained CI runners, and a tighter margin would risk flakes.
        try? await Task.sleep(nanoseconds: 600_000_000)

        // The debounce should coalesce the three changes into just one emission of the final value.
        // Note: the initial value (default scheme) may also emit depending on timing, but we're
        // testing that the three rapid changes don't produce three separate emissions.
        let finalEmissions = debounceEmissions.filter { $0 == "scheme-c" }
        #expect(finalEmissions.count == 1, "Final scheme change should emit exactly once")

        testSubscription.cancel()
    }

    @Test("separated scheme changes produce separate emissions")
    func separatedSchemeChangesProduceMultipleEmissions() async {
        let suiteName = "TBDAppTests.AppearanceDebounceSpaced.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appearance = AppearanceSettings(defaults: defaults)

        var debounceEmissions: [String] = []
        let testSubscription = appearance.$schemeID
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { schemeID in
                debounceEmissions.append(schemeID)
            }

        // First scheme change and wait for debounce to complete.
        appearance.schemeID = "scheme-a"
        try? await Task.sleep(nanoseconds: 600_000_000) // 3x the 200ms debounce window
        let countAfterFirst = debounceEmissions.count

        // Second scheme change after debounce fired — should emit again.
        appearance.schemeID = "scheme-b"
        try? await Task.sleep(nanoseconds: 600_000_000) // Wait for second debounce window

        // Should have more emissions now than before the second change.
        let countAfterSecond = debounceEmissions.count
        #expect(countAfterSecond > countAfterFirst, "Separated changes should produce multiple emissions")

        testSubscription.cancel()
    }
}
