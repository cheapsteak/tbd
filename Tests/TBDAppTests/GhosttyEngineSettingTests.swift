import Foundation
import Observation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// The "Use the libghostty terminal engine" toggle in Settings → Terminal →
/// Experimental, driven through the binding the view hands it,
/// `TerminalSettingsView.ghosttyEngineBinding(_:)`.
///
/// The toggle has to write the store its AppState was built with, because the
/// tabs' engine labels, the Terminal menu, every holder panel and every local
/// PTY read the flag from there. Turning it off has to store an explicit
/// `false`, so the choice holds when `AppState.ghosttyTerminalEngineDefault`
/// changes. Every store is an isolated suite; `.standard` is the developer's
/// real plist, so no test reads or writes it. Tier 1, apart from one bounded
/// wait for the key-value observation of a write made outside the toggle.
/// Design: `docs/specs/2026-11-07-libghostty-terminal-engine-design.md`.
@MainActor
@Suite("libghostty engine setting", .fastPassBounded)
struct GhosttyEngineSettingTests {
    private static let key = AppState.useGhosttyTerminalEngineKey

    /// The view's own binding, so a change to how the view binds its toggle
    /// is a change to what these tests drive.
    private static func toggle(_ state: AppState) -> Binding<Bool> {
        TerminalSettingsView.ghosttyEngineBinding(state)
    }

    @Test("Turning the toggle on stores true in the AppState's own store, and turning it off stores an explicit false that holds against a later default")
    func toggleWritesTheFlagKey() {
        withTestDefaults("GhosttyEngineSetting.Writes") { defaults in
            let state = AppState(userDefaults: defaults)
            let toggle = Self.toggle(state)
            let before = defaults.object(forKey: Self.key)
            #expect(before == nil, "a fresh store already held the key")

            toggle.wrappedValue = true
            let storedOn: Bool? = defaults.object(forKey: Self.key) as? Bool
            let expectedOn: Bool? = true
            #expect(storedOn == expectedOn, "turning the toggle on stored \(String(describing: storedOn))")
            let shownOn = toggle.wrappedValue
            #expect(shownOn, "the toggle did not read back on")
            let mirrorOn = state.ghosttyTerminalEngineFlag
            #expect(mirrorOn, "the flag the tabs and the Terminal menu read stayed off")

            toggle.wrappedValue = false
            let keyPresent = defaults.object(forKey: Self.key) != nil
            #expect(keyPresent, "turning the toggle off removed the key")
            let storedOff: Bool? = defaults.object(forKey: Self.key) as? Bool
            let expectedOff: Bool? = false
            #expect(storedOff == expectedOff, "turning the toggle off stored \(String(describing: storedOff))")
            let shownOff = toggle.wrappedValue
            #expect(!shownOff, "the toggle did not read back off")
            let mirrorOff = state.ghosttyTerminalEngineFlag
            #expect(!mirrorOff, "the flag the tabs and the Terminal menu read stayed on")

            // A removed key would follow a default that graduates to true; an
            // explicit false keeps the choice.
            let afterGraduation = AppState.ghosttyTerminalEngineEnabled(defaults: defaults, shippedDefault: true)
            #expect(!afterGraduation, "the stored off did not hold against a default of on")
        }
    }

    @Test("The toggle shows the three-state read: an unset key shows the default, which is off, and a stored true or false shows as stored")
    func toggleReflectsTheThreeStateRead() {
        for stored in [nil, true, false] as [Bool?] {
            withTestDefaults("GhosttyEngineSetting.Reads") { defaults in
                if let stored {
                    defaults.set(stored, forKey: Self.key)
                }
                let state = AppState(userDefaults: defaults)
                let shown = Self.toggle(state).wrappedValue
                let expected: Bool = stored ?? AppState.ghosttyTerminalEngineDefault
                #expect(shown == expected, "stored \(String(describing: stored)) showed the toggle \(shown ? "on" : "off")")
                if stored == nil {
                    #expect(!shown, "an unset key showed the toggle on, but the engine ships off")
                }
            }
        }
    }

    /// What redraws the toggle: reading it registers with Observation, so a
    /// write to the store from outside the toggle, as `defaults write` makes,
    /// reaches a Settings window already open. A getter that read the store
    /// instead of the observed mirror would show the right value and never
    /// redraw.
    @Test("Reading the toggle is observation-tracked, so a write to the store from outside the toggle redraws it")
    func toggleRedrawsOnAWriteFromOutside() async {
        await withTestDefaults("GhosttyEngineSetting.Tracked") { defaults in
            let state = AppState(userDefaults: defaults)
            let unset = Self.toggle(state).wrappedValue
            #expect(!unset, "a fresh store showed the toggle on")

            let redrawn = HolderTestLatch()
            withObservationTracking {
                _ = Self.toggle(state).wrappedValue
            } onChange: {
                redrawn.set()
            }
            defaults.set(true, forKey: Self.key)
            await EngineTestSupport.waitUntil(
                "the toggle to redraw after the key was set outside it",
                observed: { "redrawn \(redrawn.isSet), toggle shows \(Self.toggle(state).wrappedValue)" }
            ) {
                redrawn.isSet
            }
            let wasRedrawn = redrawn.isSet
            #expect(wasRedrawn, "setting the key outside the toggle did not redraw a view that read it")
            let shown = Self.toggle(state).wrappedValue
            #expect(shown, "the toggle did not show the key set outside it")
        }
    }

    /// A remote attach terminal is a local PTY, which reads the flag from the
    /// pager's AppState rather than from `.standard`. Driven from the toggle
    /// through `RemoteAttachPager.makeTerminalView` to the engine the terminal
    /// host asks the factory for, without making its view, so nothing spawns.
    @Test("A remote attach terminal asks for the engine the toggle chose, read from the store its AppState was built with")
    func remoteAttachTerminalFollowsTheToggle() {
        withTestDefaults("GhosttyEngineSetting.RemoteAttach") { defaults in
            let state = AppState(userDefaults: defaults)
            let appearance = AppearanceSettings(defaults: defaults)
            let mountKey = RemoteAttachMountKey(
                selection: RemoteSessionSelection(provider: "acme", sessionID: "s1"), generation: 0)
            let config = RemoteProviderConfig(name: "acme", exec: "/usr/bin/true")

            for enabled in [true, false] {
                Self.toggle(state).wrappedValue = enabled
                let attach = RemoteAttachPager.makeTerminalView(for: mountKey, provider: config, appState: state)
                let requested: TerminalEngineKind = attach.representable(appearance: appearance).requestedEngineKind
                let expected: TerminalEngineKind = enabled ? .ghostty : .swiftTerm
                #expect(requested == expected, "with the toggle \(enabled ? "on" : "off"), a remote attach terminal asked for \(requested)")
            }
        }
    }

    /// Stands in for "not `.standard`" without touching `.standard`: two
    /// AppStates on two stores share nothing through the toggle, and the write
    /// lands in the AppState's own domain, where a relaunch reads it. A toggle
    /// that wrote one shared store would show through the other AppState.
    @Test("The toggle writes its AppState's own store and no other: a second AppState on a second store neither sees the write nor shares its own")
    func toggleWritesOnlyTheAppStatesOwnStore() {
        let mine = TestDefaultsSuite("GhosttyEngineSetting.Mine")
        let other = TestDefaultsSuite("GhosttyEngineSetting.Other")
        defer {
            mine.tearDown()
            other.tearDown()
        }
        let state = AppState(userDefaults: mine.defaults)
        let bystander = AppState(userDefaults: other.defaults)

        Self.toggle(state).wrappedValue = true

        let reopened = mine.reopen()
        let persisted: Bool? = reopened.object(forKey: Self.key) as? Bool
        let expectedOn: Bool? = true
        #expect(persisted == expectedOn, "the AppState's domain held \(String(describing: persisted)) after the toggle went on")
        let relaunchedShown = Self.toggle(AppState(userDefaults: reopened)).wrappedValue
        #expect(relaunchedShown, "an AppState rebuilt on the same domain showed the toggle off")

        let otherBefore = other.defaults.object(forKey: Self.key)
        #expect(otherBefore == nil, "the other store got the key from this AppState's toggle")
        let bystanderShown = Self.toggle(bystander).wrappedValue
        #expect(!bystanderShown, "the other AppState's toggle went on with this one")
        let bystanderMirror = bystander.ghosttyTerminalEngineFlag
        #expect(!bystanderMirror, "the other AppState's tabs and menu saw this AppState's flag")

        Self.toggle(bystander).wrappedValue = false

        let otherStored: Bool? = other.defaults.object(forKey: Self.key) as? Bool
        let expectedOff: Bool? = false
        #expect(otherStored == expectedOff, "the other AppState's toggle stored \(String(describing: otherStored))")
        let mineStored: Bool? = mine.defaults.object(forKey: Self.key) as? Bool
        #expect(mineStored == expectedOn, "the other AppState's off reached this store: \(String(describing: mineStored))")
        let stillShown = Self.toggle(state).wrappedValue
        #expect(stillShown, "the other AppState's off turned this toggle off")
    }
}
