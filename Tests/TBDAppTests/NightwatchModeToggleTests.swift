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
        #expect(NightwatchModePresentation.isEnabled(.off, holderOn: true))
        #expect(!NightwatchModePresentation.isEnabled(.daywatch, holderOn: true))
        #expect(!NightwatchModePresentation.isEnabled(.nightwatch, holderOn: true))
    }

    @Test(arguments: NightwatchMode.allCases)
    func holderOffEnablesEveryMode(mode: NightwatchMode) {
        #expect(NightwatchModePresentation.isEnabled(mode, holderOn: false))
    }

    @Test func disabledHelpIsTheSharedRefusal() {
        #expect(NightwatchModePresentation.disabledHelp == NightwatchHolderGate.modeRefusal)
        #expect(NightwatchModePresentation.effectiveHelp(.nightwatch, holderOn: true) == NightwatchHolderGate.modeRefusal)
        #expect(NightwatchModePresentation.effectiveHelp(.nightwatch, holderOn: false) == NightwatchModePresentation.help(.nightwatch))
        #expect(NightwatchModePresentation.effectiveHelp(.off, holderOn: true) == NightwatchModePresentation.help(.off))
    }

    /// The controls read the daemon's effective holder flag; unfetched
    /// capabilities read as holder off rather than disabling the modes.
    @MainActor
    @Test func nightwatchHolderOnFollowsDaemonCapabilities() {
        let name = "tbd-nightwatch-holder-gate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let state = AppState(userDefaults: defaults)

        #expect(state.daemonCapabilities == nil)
        #expect(!state.nightwatchHolderOn)
        state.daemonCapabilities = DaemonCapabilitiesResult(
            controlModeEnabled: false, ptyHolderEnabled: true, ptyHolderSupported: true)
        #expect(state.nightwatchHolderOn)
        state.daemonCapabilities = DaemonCapabilitiesResult(
            controlModeEnabled: false, ptyHolderEnabled: false, ptyHolderSupported: true)
        #expect(!state.nightwatchHolderOn)
    }

    /// The Settings help carries the deprecation sentence regardless of the
    /// holder flag.
    @MainActor
    @Test func settingsHelpCarriesTheDeprecationNotice() {
        #expect(AppState.nightwatchSettingsHelp.hasSuffix(NightwatchHolderGate.deprecationNotice))
        #expect(AppState.nightwatchSettingsHelp.hasPrefix("An autonomous fleet babysitter."))
    }
}
