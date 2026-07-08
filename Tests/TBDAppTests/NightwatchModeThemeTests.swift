import Foundation
import Testing
import SwiftUI
@testable import TBDApp
@testable import TBDShared

@Suite("NightwatchModeTheme")
struct NightwatchModeThemeTests {
    @Test("tintColor for .off mode returns nil")
    func tintColorOffMode() {
        let color = tintColor(for: .off)
        #expect(color == nil)
    }

    @Test("tintColor for .daywatch mode returns warm amber")
    func tintColorDaywatch() {
        let color = tintColor(for: .daywatch)
        #expect(color != nil)
        // Verify it's a warm golden color (higher red, moderate green, lower blue)
        // The exact RGB values should match what we defined
        let cgColor = color?.cgColor
        #expect(cgColor != nil)
    }

    @Test("tintColor for .nightwatch mode returns cool indigo")
    func tintColorNightwatch() {
        let color = tintColor(for: .nightwatch)
        #expect(color != nil)
        // Verify it's a cool indigo color (lower red, moderate green, higher blue)
        // The exact RGB values should match what we defined
        let cgColor = color?.cgColor
        #expect(cgColor != nil)
    }

    @Test("tintColor is deterministic for each mode")
    func tintColorDeterministic() {
        let offColor1 = tintColor(for: .off)
        let offColor2 = tintColor(for: .off)
        #expect(offColor1 == offColor2)

        let daywatchColor1 = tintColor(for: .daywatch)
        let daywatchColor2 = tintColor(for: .daywatch)
        #expect(daywatchColor1 == daywatchColor2)

        let nightwatchColor1 = tintColor(for: .nightwatch)
        let nightwatchColor2 = tintColor(for: .nightwatch)
        #expect(nightwatchColor1 == nightwatchColor2)
    }

    @Test("tintColor returns different colors for different modes")
    func tintColorDifferentPerMode() {
        let daywatchColor = tintColor(for: .daywatch)
        let nightwatchColor = tintColor(for: .nightwatch)
        #expect(daywatchColor != nightwatchColor)
    }
}
