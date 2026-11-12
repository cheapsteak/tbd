import Foundation
import Testing
@testable import TBDApp
@testable import TBDGhosttyTerminal
import TestSupport

/// A libghostty terminal paints selected text in the theme's selection colour, as SwiftTerm does,
/// and an open terminal follows a theme change. Without it every theme got a white tint at 20%,
/// which a light theme's background hides. Every store is an isolated suite; `.standard` is the
/// developer's real plist.
@MainActor
@Suite("libghostty selection colour", .fastPassBounded)
struct GhosttySelectionColorTests {
    /// Flexoki Light's `selection`, `rgb(240, 235, 220)` in `ColorSchemes.flexokiLight`.
    private static let flexokiSelection = GhosttyAppearance.RGB(r: 240, g: 235, b: 220)
    /// The same colour packed for the shaders, `r | g << 8 | b << 16 | 0xFF << 24`.
    private static let flexokiSelectionPacked: UInt32 = 0xFFDC_EBF0

    @Test("The libghostty appearance carries a light scheme's selection colour")
    func theAppearanceCarriesTheSchemesSelection() {
        withTestDefaults("GhosttySelectionColor.Appearance") { defaults in
            let settings = AppearanceSettings(defaults: defaults)
            settings.schemeID = "flexoki-light"
            let appearance = GhosttyAppearance(settings: settings)
            let carried = appearance.selection
            #expect(carried == Self.flexokiSelection,
                    "Flexoki Light's selection became \(String(describing: carried)) in the libghostty appearance")
            let tint = appearance.selectionTint
            #expect(tint == Self.flexokiSelectionPacked,
                    "Flexoki Light's selection tint is \(String(tint, radix: 16)), not \(String(Self.flexokiSelectionPacked, radix: 16))")
        }
    }

    @Test("Switching to a light theme gives an open libghostty terminal that theme's selection colour",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice))
    func switchingThemesReachesAnOpenTerminal() async throws {
        let fixture = EngineUnderTest(kind: .ghostty, label: "GhosttySelectionColor.Switch")
        defer { fixture.tearDown() }
        let engine = try #require(fixture.engine as? GhosttyEngine,
                                  "the factory built \(fixture.engine.kind), not libghostty")
        let view = engine.terminalView
        try #require(fixture.appearance.schemeID != "flexoki-light",
                     "the settings already started on Flexoki Light")
        let opened = view.surface.selectionColor
        #expect(opened != FrameBuilder.defaultSelectionColor,
                "the terminal opened with the default white tint, not its theme's selection colour")

        fixture.appearance.schemeID = "flexoki-light"
        await EngineTestSupport.waitUntil(
            "switching to Flexoki Light to give the open terminal its selection colour",
            observed: { "selection tint \(String(view.surface.selectionColor, radix: 16))" }
        ) { view.surface.selectionColor == Self.flexokiSelectionPacked }
    }
}
