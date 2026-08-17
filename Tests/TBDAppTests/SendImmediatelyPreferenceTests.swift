import Testing
import Foundation
import SwiftUI
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
/// The resolver is the contract in assertable form; the shipped surfaces read
/// the key through `@AppStorage` instead. So the last three tests cover the
/// mechanism rather than the statement of it: `@AppStorage`'s resolution and
/// write-back are pinned to the resolver's answer on the same store, and the
/// modal's checkbox is checked to still be `@AppStorage`-backed.
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

    /// The shipped surfaces — the modal's checkbox and the Settings row — read
    /// the key through `@AppStorage`, never through `resolveSendImmediately`.
    /// So the three tests above prove a contract, and this one proves the
    /// mechanism actually in the binary satisfies it: for every one of the three
    /// states, against the same store, `AppStorage.wrappedValue` and the
    /// resolver must agree. A divergence in either direction reddens — SwiftUI
    /// changing how it resolves an absent key, or the resolver drifting away
    /// from what the views do.
    ///
    /// `AppStorage` is a property wrapper struct, so it can be built and read
    /// outside a `View` as long as the store is injected. It must be: the
    /// storeless form resolves against `UserDefaults.standard`, which on this
    /// unbundled executable is the developer's real `TBDApp.plist`.
    ///
    /// Both polarities of the shipped default are exercised for the absent
    /// case, for the same reason the resolver's own test does it — today's
    /// `false` would let a resolution that collapses absent into `false` pass by
    /// coincidence.
    ///
    /// Tier 1.
    @Test("@AppStorage resolves the key the way the contract says it does")
    func appStorageAgreesWithResolverAcrossAllThreeStates() {
        let suiteName = "send-immediately-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = QueuedPromptComposer.sendImmediatelyKey

        // Absent. Asserted against both shipped defaults, so the key genuinely
        // follows the default rather than matching today's `false` by accident.
        for shippedDefault in [false, true] {
            let storage = AppStorage(wrappedValue: shippedDefault, key, store: defaults)
            #expect(defaults.object(forKey: key) == nil)
            #expect(
                storage.wrappedValue
                    == QueuedPromptComposer.resolveSendImmediately(
                        defaults: defaults, shippedDefault: shippedDefault))
            #expect(storage.wrappedValue == shippedDefault)
        }

        // Chose off. A deliberate opt-out must survive a shipped default of
        // `true` on the `@AppStorage` side as well, which is where a collapsing
        // resolution would show up.
        defaults.set(false, forKey: key)
        let storedFalse = AppStorage(wrappedValue: true, key, store: defaults)
        #expect(
            storedFalse.wrappedValue
                == QueuedPromptComposer.resolveSendImmediately(
                    defaults: defaults, shippedDefault: true))
        #expect(!storedFalse.wrappedValue)

        // Chose on.
        defaults.set(true, forKey: key)
        let storedTrue = AppStorage(wrappedValue: false, key, store: defaults)
        #expect(
            storedTrue.wrappedValue
                == QueuedPromptComposer.resolveSendImmediately(
                    defaults: defaults, shippedDefault: false))
        #expect(storedTrue.wrappedValue)
    }

    /// Ticking the box has to persist, not just move the on-screen toggle —
    /// "remembered for future worktrees" is the whole feature, and the modal
    /// writes it the moment the box is ticked, even if the sheet is then
    /// dismissed with Escape. This asserts the write half of the same seam: a
    /// value set through `wrappedValue` lands in the store, and the resolver
    /// reads it back as a stored choice rather than as the absent case.
    ///
    /// Tier 1.
    @Test("writing through @AppStorage persists the choice to the store")
    func appStorageWriteReachesTheStore() {
        let suiteName = "send-immediately-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = QueuedPromptComposer.sendImmediatelyKey
        let storage = AppStorage(wrappedValue: false, key, store: defaults)
        #expect(defaults.object(forKey: key) == nil)

        storage.wrappedValue = true

        #expect(defaults.object(forKey: key) as? Bool == true)
        #expect(QueuedPromptComposer.resolveSendImmediately(defaults: defaults))
        // And back off — an opt-out is a stored choice too, not a return to
        // "never chose", or a later default flip would silently re-enable it.
        storage.wrappedValue = false
        #expect(defaults.object(forKey: key) as? Bool == false)
        #expect(
            !QueuedPromptComposer.resolveSendImmediately(defaults: defaults, shippedDefault: true))
    }

    /// The modal's checkbox must stay bound to the persisted key. Reverting
    /// `@AppStorage` to `@State` — the shape it had before this feature, and the
    /// shape a future merge conflict resolves back to most easily — would leave
    /// every assertion above passing while the box forgot the operator's answer
    /// the moment the sheet closed.
    ///
    /// The property wrapper's backing storage is reflectable, so the guard is
    /// the declared TYPE of the `_sendImmediately` child. Its `wrappedValue` is
    /// deliberately never read and the view is never rendered: this instance's
    /// `@AppStorage` has no injected store, so it resolves against
    /// `UserDefaults.standard` — the developer's real `TBDApp.plist` on this
    /// unbundled executable. Constructing the wrapper neither reads the key nor
    /// writes to that store; only touching `wrappedValue` would.
    ///
    /// Tier 1.
    @Test("the modal's checkbox is bound to the persisted key, not to view state")
    func modalCheckboxIsBackedByAppStorage() {
        let target = QueuedPromptTarget(
            placeholderID: UUID(), repoID: UUID(), worktreeName: "acme-feature")
        let modal = QueuedPromptModal(target: target)

        let backing = Mirror(reflecting: modal).children
            .first { $0.label == "_sendImmediately" }
        #expect(backing != nil, "QueuedPromptModal no longer has a sendImmediately property")
        if let backing {
            #expect(
                String(describing: type(of: backing.value)) == "AppStorage<Bool>",
                "expected @AppStorage-backed storage, found \(type(of: backing.value))")
        }
    }
}
