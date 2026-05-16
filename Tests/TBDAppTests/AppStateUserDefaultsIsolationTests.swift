import Foundation
import Testing
@testable import TBDApp

/// Regression coverage for the UserDefaults-isolation invariant that PR #133
/// established and this PR completes: when `AppState` is constructed with a
/// non-`.standard` UserDefaults, NO path through the state's persistence code
/// may touch `.standard`.
///
/// TBDApp ships as an unbundled SPM executable, so `.standard` is the running
/// developer's real `TBDApp.plist`. A leak here clobbers their live UI
/// preferences mid-test (dockRatio, layouts).
@MainActor
@Suite("AppState UserDefaults isolation")
struct AppStateUserDefaultsIsolationTests {
    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "TBDAppTests.AppStateIsolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test("dockRatio writes go to the injected suite, not .standard")
    func dockRatioWritesGoToInjectedSuite() {
        withIsolatedDefaults { defaults in
            let priorStandard = UserDefaults.standard.object(forKey: "com.tbd.app.dockRatio")
            defer {
                if let priorStandard {
                    UserDefaults.standard.set(priorStandard, forKey: "com.tbd.app.dockRatio")
                } else {
                    UserDefaults.standard.removeObject(forKey: "com.tbd.app.dockRatio")
                }
            }

            let state = AppState(userDefaults: defaults)
            state.dockRatio = 0.42

            #expect(defaults.object(forKey: "com.tbd.app.dockRatio") as? Double == 0.42)
            // Critical invariant — must NOT mutate the developer's plist.
            #expect(UserDefaults.standard.object(forKey: "com.tbd.app.dockRatio") as? Double != 0.42)
        }
    }

    @Test("layout persistence reads + writes from the injected suite")
    func layoutPersistenceUsesInjectedSuite() {
        withIsolatedDefaults { defaults in
            // Seed the injected suite, construct AppState — restoreLayouts
            // must read from `defaults`, not from `.standard`.
            let seededID = UUID()
            let seeded: [UUID: LayoutNode] = [seededID: .pane(.terminal(terminalID: UUID()))]
            let data = try? JSONEncoder().encode(seeded)
            #expect(data != nil)
            defaults.set(data, forKey: "com.tbd.app.layouts")

            let state = AppState(userDefaults: defaults)
            #expect(state.layouts.keys.contains(seededID))
        }
    }

    @Test("init reads dockRatio from the injected suite")
    func initReadsFromInjectedSuite() {
        withIsolatedDefaults { defaults in
            defaults.set(0.55, forKey: "com.tbd.app.dockRatio")

            let state = AppState(userDefaults: defaults)
            #expect(state.dockRatio == 0.55)
        }
    }
}
