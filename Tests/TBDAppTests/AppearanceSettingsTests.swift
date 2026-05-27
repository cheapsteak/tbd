import Foundation
import Testing
import SwiftTerm
@testable import TBDApp

@MainActor
@Suite("AppearanceSettings")
struct AppearanceSettingsTests {
    /// Run a body with an isolated UserDefaults suite so we never touch
    /// the live `TBDApp.plist` (see Tests/TBDAppTests/AutoSuspendPreferenceTests.swift).
    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "TBDAppTests.Appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test("fresh init has tango as the default scheme")
    func freshInitDefaults() {
        withIsolatedDefaults { defaults in
            let settings = AppearanceSettings(defaults: defaults)
            #expect(settings.schemeID == "tango")
            #expect(settings.fontName == "Monaco")
            #expect(settings.fontSize == 12.0)
            #expect(settings.cursorStyle == .blinkBlock)
            #expect(settings.thinStrokes == true)
        }
    }

    @Test("fresh init has thinStrokes enabled by default")
    func freshInitThinStrokes() {
        withIsolatedDefaults { defaults in
            let settings = AppearanceSettings(defaults: defaults)
            #expect(settings.thinStrokes == true)
        }
    }

    @Test("thinStrokes round-trips")
    func roundTripThinStrokes() {
        withIsolatedDefaults { defaults in
            let settings = AppearanceSettings(defaults: defaults)
            settings.thinStrokes = false
            let reloaded = AppearanceSettings(defaults: defaults)
            #expect(reloaded.thinStrokes == false)
        }
    }

    @Test("setting properties persists to UserDefaults")
    func roundTripFont() {
        withIsolatedDefaults { defaults in
            let settings = AppearanceSettings(defaults: defaults)
            settings.fontName = "Menlo"
            settings.fontSize = 14
            settings.schemeID = "dracula"
            settings.cursorStyle = .steadyUnderline

            let reloaded = AppearanceSettings(defaults: defaults)
            #expect(reloaded.fontName == "Menlo")
            #expect(reloaded.fontSize == 14)
            #expect(reloaded.schemeID == "dracula")
            #expect(reloaded.cursorStyle == .steadyUnderline)
        }
    }

    @Test("invalid font size falls back to default")
    func fallbackFontSize() {
        withIsolatedDefaults { defaults in
            defaults.set(0.0, forKey: "terminal.font.size")
            let settings = AppearanceSettings(defaults: defaults)
            #expect(settings.fontSize == 12.0)
        }
    }

    @Test("unknown cursor style raw value falls back to blinkBlock")
    func fallbackCursorStyle() {
        withIsolatedDefaults { defaults in
            defaults.set("not-a-real-style", forKey: "terminal.cursor.style")
            let settings = AppearanceSettings(defaults: defaults)
            #expect(settings.cursorStyle == .blinkBlock)
        }
    }

    @Test("unknown scheme id is normalized to the default at init")
    func normalizeSchemeID() {
        withIsolatedDefaults { defaults in
            defaults.set("bogus-scheme", forKey: "terminal.scheme.id")
            let settings = AppearanceSettings(defaults: defaults)
            #expect(settings.schemeID == "tango")
        }
    }

    @Test("user theme id is preserved at init when a matching JSON file exists")
    func preservesUserThemeIDWithMatchingFile() throws {
        // Regression test: init used to reject any non-bundled id, which
        // silently clobbered legitimate user-theme selections back to Tango
        // on every relaunch (the on-disk file load races init).
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-appearance-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("TBD_HOME", home.path, 1)
        defer {
            try? FileManager.default.removeItem(at: home)
            unsetenv("TBD_HOME")
        }
        let themesDir = home.appendingPathComponent("terminal-themes")
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        // Contents don't need to be a valid theme — init only checks file existence.
        try Data().write(to: themesDir.appendingPathComponent("my-theme.json"))

        withIsolatedDefaults { defaults in
            defaults.set("my-theme", forKey: "terminal.scheme.id")
            let settings = AppearanceSettings(defaults: defaults)
            #expect(settings.schemeID == "my-theme")
        }
    }

    @Test("computed font falls back to system mono when fontName is bogus")
    func fallbackFontResolution() {
        withIsolatedDefaults { defaults in
            let settings = AppearanceSettings(defaults: defaults)
            settings.fontName = "NotARealFontNameXYZ"
            settings.fontSize = 13
            #expect(settings.font.pointSize == 13)
            // Should resolve to system mono, not nil.
            #expect(settings.font.fontName.lowercased().contains("mono") ||
                    settings.font.fontName.lowercased().contains("sf"))
        }
    }

    @Test("colorFgBg for light schemes returns 0;15 (black fg, white bg)")
    func colorFgBgLight() {
        // Test with solarized-light which has a light background
        let scheme = ColorSchemes.scheme(forID: "solarized-light")
        let colorFgBg = AppearanceSettings.colorFgBg(for: scheme)
        #expect(colorFgBg == "0;15")
    }

    @Test("colorFgBg for dark schemes returns 15;0 (white fg, black bg)")
    func colorFgBgDark() {
        // Test with solarized-dark which has a dark background
        let scheme = ColorSchemes.scheme(forID: "solarized-dark")
        let colorFgBg = AppearanceSettings.colorFgBg(for: scheme)
        #expect(colorFgBg == "15;0")
    }

    @Test("colorFgBg for default tango scheme returns 15;0 (dark bg)")
    func colorFgBgDefaultTango() {
        // Tango has rgb(0,0,0) background (luminance 0)
        let scheme = ColorSchemes.defaultScheme
        let colorFgBg = AppearanceSettings.colorFgBg(for: scheme)
        #expect(colorFgBg == "15;0")
    }

    @Test("colorFgBg for github-light returns 0;15 (light bg)")
    func colorFgBgGithubLight() {
        let scheme = ColorSchemes.scheme(forID: "github-light")
        let colorFgBg = AppearanceSettings.colorFgBg(for: scheme)
        #expect(colorFgBg == "0;15")
    }

    @Test("colorFgBg for nord returns 15;0 (dark bg)")
    func colorFgBgNord() {
        let scheme = ColorSchemes.scheme(forID: "nord")
        let colorFgBg = AppearanceSettings.colorFgBg(for: scheme)
        #expect(colorFgBg == "15;0")
    }

    @Test("currentColorFgBg property returns correct value for current scheme")
    func currentColorFgBgProperty() {
        withIsolatedDefaults { defaults in
            let settings = AppearanceSettings(defaults: defaults)
            settings.schemeID = "github-light"
            let value = settings.currentColorFgBg
            #expect(value == "0;15")

            settings.schemeID = "nord"
            let darkValue = settings.currentColorFgBg
            #expect(darkValue == "15;0")
        }
    }

    @Test("currentColorFgBg uses user-theme bg luminance when a user theme is active")
    func currentColorFgBgForUserTheme() throws {
        let suiteName = "tbd.test.fgbg-user.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThemeStore()
        let lightUser = TerminalColorScheme(
            id: "light-user", displayName: "Light U",
            ansi: Array(repeating: SwiftTerm.Color(red: 0, green: 0, blue: 0), count: 16),
            foreground: SwiftTerm.Color(red: 0, green: 0, blue: 0),
            background: SwiftTerm.Color(red: 65535, green: 65535, blue: 65535),
            cursor: SwiftTerm.Color(red: 0, green: 0, blue: 0),
            selection: SwiftTerm.Color(red: 32000, green: 32000, blue: 32000)
        )
        store.injectForTest(userThemes: [lightUser])

        let appearance = AppearanceSettings(defaults: defaults)
        appearance.themeStore = store
        appearance.schemeID = "light-user"
        #expect(appearance.currentColorFgBg == "0;15")
    }
}
