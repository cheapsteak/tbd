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
}
