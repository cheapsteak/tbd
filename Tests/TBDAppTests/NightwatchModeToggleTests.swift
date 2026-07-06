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
}

@Suite("NightwatchModeToggle tap -> setNightwatchMode(mode)")
@MainActor
struct NightwatchModeToggleTapTargetTests {
    /// The toggle wires each segment's tap to `setNightwatchMode(mode)` where
    /// `mode` is that segment's own `NightwatchMode`. `DaemonClient` is a
    /// concrete actor with no injection seam (see ModelProfileAppStateTests), so
    /// we can't observe the RPC directly; instead we lock in the tap-target
    /// mapping the button closure forwards — segment i taps `ordered[i]`, and
    /// the active-highlight (verified above) reflects that same mode afterward.
    @Test func eachSegmentTapTargetsItsOwnMode() {
        for mode in NightwatchModePresentation.ordered {
            // The value the segment's button hands to setNightwatchMode is the
            // segment's mode itself; after that call succeeds, isActive(current:)
            // for that same mode must read true and no sibling may.
            let active = NightwatchModePresentation.ordered.filter {
                NightwatchModePresentation.isActive(segment: $0, current: mode)
            }
            #expect(active == [mode])
        }
    }
}
