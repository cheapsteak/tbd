import Testing
import Foundation
@testable import TBDApp

/// The three states `QueuedPromptComposer.resolveSendImmediately` must keep
/// distinct (`docs/specs/2026-08-16-send-immediately-preference-design.md`):
/// never chose, chose off, chose on. `UserDefaults.bool(forKey:)` collapses the
/// first two into `false`, which is the destroyed distinction that made
/// `auto_hibernate_enabled` unflippable on the daemon side — so the absent case
/// is asserted against an explicitly-supplied shipped default rather than
/// against the constant, which today happens to be `false` and would let a
/// collapsing resolver pass by coincidence.
///
/// Tier 1. Each test gets its own `UserDefaults(suiteName:)` and tears it down;
/// `UserDefaults.standard` on this unbundled executable is the developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("Send immediately preference")
struct SendImmediatelyPreferenceTests {
    @Test("an absent key follows the shipped default, whatever it is")
    func absentKeyResolvesToShippedDefault() {
        let suiteName = "send-immediately-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults.object(forKey: QueuedPromptComposer.sendImmediatelyKey) == nil)
        #expect(
            QueuedPromptComposer.resolveSendImmediately(defaults: defaults)
                == QueuedPromptComposer.sendImmediatelyDefault)
        // The discriminating pair: absent must follow the default in BOTH
        // directions. A `defaults.bool(forKey:)` resolver fails the `true` arm.
        #expect(
            QueuedPromptComposer.resolveSendImmediately(defaults: defaults, shippedDefault: true))
        #expect(
            !QueuedPromptComposer.resolveSendImmediately(defaults: defaults, shippedDefault: false))
    }

    @Test("an explicit false is a stored choice, not the absent case")
    func explicitFalseIsDistinctFromAbsent() {
        let suiteName = "send-immediately-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: QueuedPromptComposer.sendImmediatelyKey)

        #expect(defaults.object(forKey: QueuedPromptComposer.sendImmediatelyKey) != nil)
        #expect(!QueuedPromptComposer.resolveSendImmediately(defaults: defaults))
        // A deliberate opt-out must survive a future flip of the shipped
        // default, so this is asserted against `true` rather than against the
        // constant.
        #expect(
            !QueuedPromptComposer.resolveSendImmediately(defaults: defaults, shippedDefault: true))
    }

    @Test("an explicit true reads true")
    func explicitTrueReadsTrue() {
        let suiteName = "send-immediately-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: QueuedPromptComposer.sendImmediatelyKey)

        #expect(QueuedPromptComposer.resolveSendImmediately(defaults: defaults))
        #expect(
            QueuedPromptComposer.resolveSendImmediately(defaults: defaults, shippedDefault: false))
    }
}
