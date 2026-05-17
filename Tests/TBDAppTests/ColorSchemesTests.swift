import Testing
@testable import TBDApp

@Suite("ColorSchemes")
struct ColorSchemesTests {
    @Test("bundled list is non-empty and contains tbd-default and tango")
    func bundledContainsCore() {
        let ids = ColorSchemes.bundled.map(\.id)
        #expect(ids.contains("tbd-default"))
        #expect(ids.contains("tango"))
    }

    @Test("every bundled scheme has exactly 16 ANSI colors")
    func ansiCount() {
        for scheme in ColorSchemes.bundled {
            #expect(scheme.ansi.count == 16, "scheme \(scheme.id) has \(scheme.ansi.count) ANSI colors")
        }
    }

    @Test("bundled IDs are unique")
    func uniqueIDs() {
        let ids = ColorSchemes.bundled.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("scheme(forID:) returns the requested scheme")
    func lookupFound() {
        let scheme = ColorSchemes.scheme(forID: "tango")
        #expect(scheme.id == "tango")
    }

    @Test("scheme(forID:) returns tbd-default when looked up by its id")
    func lookupDefault() {
        let scheme = ColorSchemes.scheme(forID: "tbd-default")
        #expect(scheme.id == "tbd-default")
    }

    @Test("scheme(forID:) falls back to tbd-default on unknown id")
    func lookupFallback() {
        let scheme = ColorSchemes.scheme(forID: "this-does-not-exist")
        #expect(scheme.id == "tbd-default")
    }
}
