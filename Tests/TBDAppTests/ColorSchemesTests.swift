import Testing
import SwiftTerm
@testable import TBDApp

@MainActor
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

    @Test("scheme(forID:) finds tbd-default by its own id (not the fallback path)")
    func lookupTBDDefaultByID() {
        let scheme = ColorSchemes.scheme(forID: "tbd-default")
        #expect(scheme.id == "tbd-default")
    }

    @Test("scheme(forID:) falls back to defaultScheme on unknown id")
    func lookupFallback() {
        let scheme = ColorSchemes.scheme(forID: "this-does-not-exist")
        #expect(scheme.id == ColorSchemes.defaultScheme.id)
    }

    @Test("bundled contains exactly 15 schemes with expected IDs")
    func bundledCount() {
        let ids = Set(ColorSchemes.bundled.map(\.id))
        let expected: Set<String> = [
            "tbd-default", "tango", "solarized-dark", "tomorrow-night",
            "dracula", "nord", "one-dark", "gruvbox-dark",
            "solarized-light", "github-light", "catppuccin-latte", "gruvbox-light",
            "rose-pine-dawn", "flexoki-light", "tokyo-night-day",
        ]
        #expect(ids == expected)
    }

    @Test("scheme(forID:) returns a user theme when bundled has no match")
    func resolvesUserTheme() {
        let store = ThemeStore()
        let userScheme = TerminalColorScheme(
            id: "my-user-theme", displayName: "Mine",
            ansi: Array(repeating: SwiftTerm.Color(red: 0, green: 0, blue: 0), count: 16),
            foreground: SwiftTerm.Color(red: 65535, green: 65535, blue: 65535),
            background: SwiftTerm.Color(red: 0, green: 0, blue: 0),
            cursor: SwiftTerm.Color(red: 65535, green: 65535, blue: 65535),
            selection: SwiftTerm.Color(red: 20000, green: 20000, blue: 20000)
        )
        store.injectForTest(userThemes: [userScheme])
        let resolved = ColorSchemes.scheme(forID: "my-user-theme", store: store)
        #expect(resolved.id == "my-user-theme")
    }

    @Test("bundled wins on id collision with a user theme")
    func bundledWinsOnCollision() {
        let store = ThemeStore()
        let conflicting = TerminalColorScheme(
            id: "gruvbox-dark", displayName: "Hijack",
            ansi: Array(repeating: SwiftTerm.Color(red: 65535, green: 0, blue: 0), count: 16),
            foreground: SwiftTerm.Color(red: 65535, green: 0, blue: 0),
            background: SwiftTerm.Color(red: 65535, green: 0, blue: 0),
            cursor: SwiftTerm.Color(red: 65535, green: 0, blue: 0),
            selection: SwiftTerm.Color(red: 65535, green: 0, blue: 0)
        )
        store.injectForTest(userThemes: [conflicting])
        let resolved = ColorSchemes.scheme(forID: "gruvbox-dark", store: store)
        #expect(resolved.displayName == "Gruvbox Dark")
    }

    @Test("scheme(forID:) falls back to default when neither bundled nor user has a match")
    func fallsBackToDefault() {
        let resolved = ColorSchemes.scheme(forID: "nonexistent-9999")
        #expect(resolved.id == ColorSchemes.defaultScheme.id)
    }
}
