import Foundation
import Testing

@testable import TBDApp
import TBDShared

@Suite("NightwatchModePresentation")
struct NightwatchModePresentationTests {
    @Test func orderedCoversEveryModeInDisplayOrder() {
        #expect(NightwatchModePresentation.ordered == [.off, .daywatch, .nightwatch])
        // Guard against a new NightwatchMode case being added without a segment.
        #expect(Set(NightwatchModePresentation.ordered) == Set(NightwatchMode.allCases))
    }

    @Test(arguments: [
        (NightwatchMode.off, "Off"),
        (.daywatch, "Day"),
        (.nightwatch, "Night"),
    ])
    func labelPerMode(mode: NightwatchMode, expected: String) {
        #expect(NightwatchModePresentation.label(mode) == expected)
    }

    @Test func glyphMatchesMenuBarVocabulary() {
        #expect(NightwatchModePresentation.glyph(.off) == nil)
        #expect(NightwatchModePresentation.glyph(.daywatch) == "◐")
        #expect(NightwatchModePresentation.glyph(.nightwatch) == "🌙")
    }

    @Test func glyphLabelPrependsGlyphWhenPresent() {
        #expect(NightwatchModePresentation.glyphLabel(.off) == "Off")
        #expect(NightwatchModePresentation.glyphLabel(.daywatch) == "◐ Day")
        #expect(NightwatchModePresentation.glyphLabel(.nightwatch) == "🌙 Night")
    }

    @Test func helpExplainsEachMode() {
        #expect(NightwatchModePresentation.help(.off).contains("not watching"))
        #expect(NightwatchModePresentation.help(.daywatch).contains("while you're around"))
        #expect(NightwatchModePresentation.help(.nightwatch).contains("while you're away"))
    }

    /// The control highlights exactly the segment matching the active mode — for
    /// each possible `nightwatchMode` value, only its own segment reads active.
    @Test(arguments: NightwatchMode.allCases)
    func exactlyOneSegmentActivePerMode(current: NightwatchMode) {
        let active = NightwatchModePresentation.ordered.filter {
            NightwatchModePresentation.isActive(segment: $0, current: current)
        }
        #expect(active == [current])
    }

    // MARK: - The pty-holder gate

    /// With the holder on, only the watch modes are refused; `.off` stays
    /// reachable so a user can always leave a mode.
    @Test func holderOnDisablesOnlyTheWatchModes() {
        #expect(NightwatchModePresentation.isEnabled(.off, holderBlocking: true))
        #expect(!NightwatchModePresentation.isEnabled(.daywatch, holderBlocking: true))
        #expect(!NightwatchModePresentation.isEnabled(.nightwatch, holderBlocking: true))
    }

    @Test(arguments: NightwatchMode.allCases)
    func holderOffEnablesEveryMode(mode: NightwatchMode) {
        #expect(NightwatchModePresentation.isEnabled(mode, holderBlocking: false))
    }

    @Test func disabledHelpIsTheSharedRefusal() {
        #expect(NightwatchModePresentation.disabledHelp == NightwatchHolderGate.modeRefusal)
        #expect(NightwatchModePresentation.effectiveHelp(.nightwatch, holderBlocking: true)
            == NightwatchHolderGate.modeRefusal)
        #expect(NightwatchModePresentation.effectiveHelp(.nightwatch, holderBlocking: false)
            == NightwatchModePresentation.help(.nightwatch))
        #expect(NightwatchModePresentation.effectiveHelp(.off, holderBlocking: true)
            == NightwatchModePresentation.help(.off))
    }

    /// The controls read both halves of the hazard; unfetched capabilities
    /// read as not blocking rather than disabling the modes.
    ///
    /// The third case is the one the graduated default makes ordinary and the
    /// one a single-term implementation gets wrong: flag on, no `TBDHolder`
    /// helper. No holder-backed session can be spawned there, so the watch
    /// modes must stay selectable.
    @MainActor
    @Test func holderBlocksWatchModesFollowsDaemonCapabilities() {
        let name = "tbd-nightwatch-holder-gate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let state = AppState(userDefaults: defaults)

        #expect(state.daemonCapabilities == nil)
        #expect(!state.holderBlocksWatchModes)
        state.daemonCapabilities = DaemonCapabilitiesResult(
            controlModeEnabled: false, ptyHolderEnabled: true, ptyHolderSupported: true)
        #expect(state.holderBlocksWatchModes)
        state.daemonCapabilities = DaemonCapabilitiesResult(
            controlModeEnabled: false, ptyHolderEnabled: true, ptyHolderSupported: false)
        #expect(!state.holderBlocksWatchModes,
                "no helper means no holder session, so the watch modes stay selectable")
        state.daemonCapabilities = DaemonCapabilitiesResult(
            controlModeEnabled: false, ptyHolderEnabled: false, ptyHolderSupported: true)
        #expect(!state.holderBlocksWatchModes)
    }

    /// Version skew: a newer app against a daemon that predates the flag.
    /// Neither field arrives, both decode false, and the watch modes that
    /// daemon can still run stay selectable. Resolving the absent `enabled`
    /// through the graduated default would disable them instead.
    @MainActor
    @Test func aDaemonPredatingTheFlagDoesNotBlockTheWatchModes() throws {
        let json = Data(#"{"controlModeEnabled":true,"controlModeSupported":false}"#.utf8)
        let capabilities = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: json)
        #expect(capabilities.ptyHolderEnabled == false)
        #expect(capabilities.ptyHolderSupported == false)

        let name = "tbd-nightwatch-holder-skew-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let state = AppState(userDefaults: defaults)
        state.daemonCapabilities = capabilities

        #expect(!state.holderBlocksWatchModes)
        for mode in NightwatchMode.allCases {
            #expect(NightwatchModePresentation.isEnabled(
                mode, holderBlocking: state.holderBlocksWatchModes))
        }
    }

    /// The Settings help carries the deprecation sentence regardless of the
    /// holder flag.
    @MainActor
    @Test func settingsHelpCarriesTheDeprecationNotice() {
        #expect(AppState.nightwatchSettingsHelp.hasSuffix(NightwatchHolderGate.deprecationNotice))
        #expect(AppState.nightwatchSettingsHelp.hasPrefix("An autonomous fleet babysitter."))
    }
}
