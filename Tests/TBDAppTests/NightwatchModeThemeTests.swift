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
        let cgColor = color?.cgColor
        #expect(cgColor != nil)
    }

    @Test("tintColor for .nightwatch mode returns cool indigo")
    func tintColorNightwatch() {
        let color = tintColor(for: .nightwatch)
        #expect(color != nil)
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

    @Test("resolvedTint returns color when experimental is enabled and mode has tint")
    func resolvedTintReturnsColorWhenExperimentalEnabled() {
        let tint = NightwatchModeTintModifier.resolvedTint(mode: .daywatch, experimentalEnabled: true)
        #expect(tint != nil)

        let nightwatchTint = NightwatchModeTintModifier.resolvedTint(mode: .nightwatch, experimentalEnabled: true)
        #expect(nightwatchTint != nil)
    }

    @Test("resolvedTint returns nil when experimental is disabled")
    func resolvedTintReturnsNilWhenExperimentalDisabled() {
        let offTint = NightwatchModeTintModifier.resolvedTint(mode: .off, experimentalEnabled: false)
        #expect(offTint == nil)

        let daywatchTint = NightwatchModeTintModifier.resolvedTint(mode: .daywatch, experimentalEnabled: false)
        #expect(daywatchTint == nil)

        let nightwatchTint = NightwatchModeTintModifier.resolvedTint(mode: .nightwatch, experimentalEnabled: false)
        #expect(nightwatchTint == nil)
    }

    @Test("resolvedTint returns nil for .off mode regardless of experimental flag")
    func resolvedTintReturnsNilForOffMode() {
        let offTintEnabled = NightwatchModeTintModifier.resolvedTint(mode: .off, experimentalEnabled: true)
        #expect(offTintEnabled == nil)

        let offTintDisabled = NightwatchModeTintModifier.resolvedTint(mode: .off, experimentalEnabled: false)
        #expect(offTintDisabled == nil)
    }
}
