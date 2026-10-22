import Foundation
import Testing

@testable import TBDApp

/// Storage contract for the "Send clicks and drags to apps that use the
/// mouse" flag. Three states, and the one that matters is `nil`: graduation is
/// meant to be a one-line change to `forwardMouseToAppsDefault` that reaches
/// everyone who never touched the toggle *without* overriding anyone who
/// deliberately turned it off. That only holds if "nobody chose" is
/// distinguishable from an explicit `false`, which a `bool(forKey:)` read
/// would destroy.
///
/// Tier 1: in-process `UserDefaults` suites only, never `.standard` — on this
/// unbundled executable that is the developer's real plist.
@MainActor
@Suite("forwardMouseToAppsEnabled setting")
struct ForwardMouseToAppsSettingTests {
    @Test("ships off — changing where a plain drag goes soaks behind a flag first")
    func shipsOff() {
        #expect(AppState.forwardMouseToAppsDefault == false)
    }

    @Test("an unset key reads the shipped default")
    func unsetKeyReadsShippedDefault() {
        let suiteName = "forward-mouse-unset-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults.object(forKey: AppState.forwardMouseToAppsKey) == nil)
        #expect(
            AppState.forwardMouseToAppsEnabled(defaults: defaults)
                == AppState.forwardMouseToAppsDefault)
    }

    @Test("both explicit values round-trip through the read")
    func explicitValuesRoundTrip() {
        let suiteName = "forward-mouse-explicit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: AppState.forwardMouseToAppsKey)
        #expect(AppState.forwardMouseToAppsEnabled(defaults: defaults))
        defaults.set(false, forKey: AppState.forwardMouseToAppsKey)
        #expect(!AppState.forwardMouseToAppsEnabled(defaults: defaults))
    }

    /// The graduation rehearsal: flip the shipped default to `true` and check
    /// that only the untouched state follows it.
    @Test("an explicit false survives a change to the default constant; nil follows it")
    func explicitFalseSurvivesDefaultFlipNilFollows() {
        #expect(!AppState.forwardMouseToAppsEnabled(stored: false, shippedDefault: true))
        #expect(AppState.forwardMouseToAppsEnabled(stored: nil, shippedDefault: true))
        #expect(AppState.forwardMouseToAppsEnabled(stored: true, shippedDefault: false))
        #expect(!AppState.forwardMouseToAppsEnabled(stored: nil, shippedDefault: false))
    }

    /// A SwiftUI view's `@AppStorage` cannot be inspected headlessly, so this
    /// pins the copy the view renders (it reads these same statics) instead.
    @Test("the Settings toggle uses the agreed title and subtitle")
    func settingsToggleCopy() {
        #expect(
            TerminalSettingsView.forwardMouseToAppsTitle
                == "Send clicks and drags to apps that use the mouse")
        #expect(
            TerminalSettingsView.forwardMouseToAppsSubtitle
                == "Option- or Shift-drag still selects text in TBD.")
    }
}
