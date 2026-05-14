import Foundation
import Testing
@testable import TBDApp

/// Regression guard for the pre-existing bug where `AppState.init()`
/// unconditionally spawned a daemon-subscription Task. Each per-test
/// `AppState()` would leak a Task blocked in a synchronous `recv()`,
/// saturating the Swift cooperative thread pool and deadlocking
/// `swift test` once enough `AppState`s had been constructed.
///
/// The fix gates the auto-connect on whether the process is a test
/// harness (presence of a `.xctest` argument). This test verifies the
/// gate fires here: constructing many `AppState`s must not block, and
/// `isConnected` must stay false because no connect Task ran.
@MainActor
@Suite("AppState test-mode guard")
struct AppStateTestModeGuardTests {
    @Test("init does not auto-connect when running under swift test")
    func initSkipsAutoConnectInTests() async {
        // If the guard regressed, each construction would spawn a Task
        // blocked in recv() and this loop would eventually deadlock the
        // cooperative thread pool. 32 is well above the typical pool
        // size on Apple Silicon, so saturation would show up here.
        var instances: [AppState] = []
        for _ in 0..<32 {
            instances.append(AppState())
        }

        // Give any (unwanted) connect Task a chance to run; with the
        // guard in place there's nothing to wait for.
        try? await Task.sleep(nanoseconds: 50_000_000)

        for appState in instances {
            #expect(appState.isConnected == false)
            #expect(appState.isInitialStateLoaded == false)
        }
    }
}
