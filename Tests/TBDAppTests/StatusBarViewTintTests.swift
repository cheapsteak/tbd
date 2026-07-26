import Foundation
import Testing
import SwiftUI
@testable import TBDApp
@testable import TBDShared

/// Tier 1. `statusBarTint` gates the bottom bar's nightwatch/daywatch tint on
/// two independent conditions — the experimental opt-in and the mode — so all
/// six combinations are covered per the repo's branch-coverage convention.
@Suite("StatusBarView tint")
struct StatusBarViewTintTests {
    // MARK: - Experimental flag OFF: no tint in any mode

    @Test("no tint when experimental is off and mode is .off")
    func tintExperimentalOffModeOff() {
        #expect(StatusBarView.statusBarTint(mode: .off, experimentalEnabled: false) == nil)
    }

    @Test("no tint when experimental is off and mode is .daywatch")
    func tintExperimentalOffModeDaywatch() {
        #expect(StatusBarView.statusBarTint(mode: .daywatch, experimentalEnabled: false) == nil)
    }

    @Test("no tint when experimental is off and mode is .nightwatch")
    func tintExperimentalOffModeNightwatch() {
        #expect(StatusBarView.statusBarTint(mode: .nightwatch, experimentalEnabled: false) == nil)
    }

    // MARK: - Experimental flag ON: tint follows the mode

    @Test("no tint when experimental is on but mode is .off")
    func tintExperimentalOnModeOff() {
        #expect(StatusBarView.statusBarTint(mode: .off, experimentalEnabled: true) == nil)
    }

    @Test("daywatch tint when experimental is on and mode is .daywatch")
    func tintExperimentalOnModeDaywatch() {
        let tint = StatusBarView.statusBarTint(mode: .daywatch, experimentalEnabled: true)
        #expect(tint != nil)
        #expect(tint == tintColor(for: .daywatch))
    }

    @Test("nightwatch tint when experimental is on and mode is .nightwatch")
    func tintExperimentalOnModeNightwatch() {
        let tint = StatusBarView.statusBarTint(mode: .nightwatch, experimentalEnabled: true)
        #expect(tint != nil)
        #expect(tint == tintColor(for: .nightwatch))
    }

    @Test("daywatch and nightwatch bar tints are distinguishable")
    func tintDiffersPerMode() {
        let daywatch = StatusBarView.statusBarTint(mode: .daywatch, experimentalEnabled: true)
        let nightwatch = StatusBarView.statusBarTint(mode: .nightwatch, experimentalEnabled: true)
        #expect(daywatch != nightwatch)
    }

    /// The tint sits behind the bar's `.primary`/`.secondary` text, so the
    /// opacity has to stay low enough that neither appearance loses contrast.
    @Test("tint opacity stays in the legible band")
    func tintOpacityIsSubtle() {
        #expect(StatusBarView.tintOpacity > 0)
        #expect(StatusBarView.tintOpacity <= 0.25)
    }
}
