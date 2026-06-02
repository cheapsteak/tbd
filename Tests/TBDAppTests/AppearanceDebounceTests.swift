import Combine
import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tests that scheme changes are debounced before they turn into daemon RPCs.
///
/// These tests reconstruct the same Combine pipeline that
/// `AppState.setupAppearanceSubscriptions` wires onto `appearance.$schemeID`
/// (`dropFirst().removeDuplicates().debounce(for: .milliseconds(200),
/// scheduler: DispatchQueue.main)`) and observe its emissions directly, so the
/// debounce contract is verified without standing up a daemon connection.
///
/// Why `DispatchQueue.main` + condition-based waiting: a `RunLoop.main` Combine
/// scheduler fires its debounce `Timer` in `.default` mode, which only advances
/// while a `CFRunLoop` is actively spinning. Under `swift test` there is no
/// `NSApplication.run()` pumping the main run loop, so those timers fire
/// unreliably while the test is suspended in `Task.sleep` — the original flake.
/// `DispatchQueue.main` blocks are serviced by the main-actor executor
/// regardless, so the emission always lands; we then poll for it instead of
/// sleeping a fixed window and asserting blind.
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
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { debounceEmissions.append($0) }

        // Three changes with no suspension between them stay inside one debounce
        // window, so the operator must coalesce them into a single trailing emission.
        appearance.schemeID = "scheme-a"
        appearance.schemeID = "scheme-b"
        appearance.schemeID = "scheme-c"

        // Wait (condition-based) for the coalesced emission rather than sleeping a
        // fixed window then asserting — no wall-clock dependency.
        let landed = await poll { debounceEmissions.contains("scheme-c") }
        #expect(landed, "Debounced emission of the final scheme should land within the deadline")

        // The three rapid changes collapsed to exactly one emission of the last value;
        // the intermediate values were never emitted on their own.
        #expect(debounceEmissions == ["scheme-c"], "Rapid changes should coalesce to a single final emission")

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
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { debounceEmissions.append($0) }

        // First change: wait for its debounced emission to land.
        appearance.schemeID = "scheme-a"
        let first = await poll { debounceEmissions.count >= 1 }
        #expect(first, "First separated change should produce an emission")
        let countAfterFirst = debounceEmissions.count

        // Second change after the first window settled: must emit again.
        appearance.schemeID = "scheme-b"
        let second = await poll { debounceEmissions.count > countAfterFirst }
        #expect(second, "Second separated change should produce another emission")
        #expect(debounceEmissions.count > countAfterFirst, "Separated changes should produce multiple emissions")

        testSubscription.cancel()
    }
}

/// Polls `condition` on the main actor until it returns true or `timeout`
/// elapses, returning the final result. Used instead of a fixed `Task.sleep`
/// so the test proceeds the instant the asynchronous debounce emission arrives
/// and never depends on a wall-clock window. The `Task.sleep` suspension points
/// let `DispatchQueue.main` debounce blocks drain between checks.
@MainActor
private func poll(
    timeout: Duration = .seconds(5),
    interval: Duration = .milliseconds(10),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return condition()
}
