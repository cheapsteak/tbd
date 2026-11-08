import Foundation
import Testing
@testable import TBDApp
@testable import TBDGhosttyTerminal
import TestSupport

/// The "Thin strokes" setting in Settings → Terminal reaches libghostty terminals, as it reaches
/// SwiftTerm's font smoothing. With thin strokes on, libghostty draws its glyphs without stem
/// darkening; with them off, it draws them thickened. An open terminal follows a change the way it
/// follows a font change: through the engine's appearance subscription, onto a new glyph atlas.
/// Every store is an isolated suite; `.standard` is the developer's real plist.
@MainActor
@Suite("libghostty thin strokes", .fastPassBounded)
struct GhosttyThinStrokesTests {
    @Test("The libghostty appearance carries the Thin strokes setting", arguments: [true, false])
    func theAppearanceCarriesThinStrokes(thinStrokes: Bool) {
        withTestDefaults("GhosttyThinStrokes.Appearance") { defaults in
            let settings = AppearanceSettings(defaults: defaults)
            settings.thinStrokes = thinStrokes
            let carried = GhosttyAppearance(settings: settings).thinStrokes
            #expect(carried == thinStrokes, "Thin strokes \(thinStrokes) became \(carried) in the libghostty appearance")
        }
    }

    @Test("Turning Thin strokes off and on again changes an open libghostty terminal's stroke weight",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice))
    func togglingThinStrokesReachesAnOpenTerminal() async throws {
        let fixture = EngineUnderTest(kind: .ghostty, label: "GhosttyThinStrokes.Toggle")
        defer { fixture.tearDown() }
        let engine = try #require(fixture.engine as? GhosttyEngine,
                                  "the factory built \(fixture.engine.kind), not libghostty")
        let view = engine.terminalView
        try #require(fixture.appearance.thinStrokes, "the settings did not start with Thin strokes on")
        let startsThickened = view.renderContext.thicken
        #expect(!startsThickened, "with Thin strokes on, the terminal's glyph atlas is thickened")

        fixture.appearance.thinStrokes = false
        await EngineTestSupport.waitUntil(
            "turning Thin strokes off to thicken the terminal's glyphs",
            observed: { "thicken \(view.renderContext.thicken)" }
        ) { view.renderContext.thicken }

        fixture.appearance.thinStrokes = true
        await EngineTestSupport.waitUntil(
            "turning Thin strokes back on to stop thickening the terminal's glyphs",
            observed: { "thicken \(view.renderContext.thicken)" }
        ) { !view.renderContext.thicken }
    }
}
