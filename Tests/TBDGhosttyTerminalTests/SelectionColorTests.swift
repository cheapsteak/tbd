import AppKit
import Foundation
import Metal
import TBDGhosttyShaderTypes
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// A selected cell takes the appearance's selection colour as its background, as SwiftTerm paints
/// it, and a new appearance repaints it. Without the selection colour every theme got the frame
/// builder's white tint, which a light theme's background hides. The frame tests build without a
/// GPU; the view test needs one to make a view.
@Suite(.fastPassBounded)
@MainActor
struct SelectionColorTests {
    /// Flexoki Light's selection colour, `rgb(240, 235, 220)`.
    private static let lightSelection = GhosttyAppearance.RGB(r: 240, g: 235, b: 220)
    /// `lightSelection` packed for the shaders, `r | g << 8 | b << 16 | 0xFF << 24`, written out so
    /// a wrong byte order or a missing alpha shows.
    private static let lightSelectionPacked: UInt32 = 0xFFDC_EBF0
    /// A second selection colour, for the change.
    private static let otherSelection = GhosttyAppearance.RGB(r: 0x12, g: 0x34, b: 0x56)
    private static let otherSelectionPacked: UInt32 = 0xFF56_3412

    /// A light appearance, Flexoki Light's colours, with `selection` as its selection colour.
    private static func lightAppearance(selection: GhosttyAppearance.RGB?) -> GhosttyAppearance {
        GhosttyAppearance(
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            foreground: .init(r: 16, g: 15, b: 15),
            background: .init(r: 255, g: 252, b: 240),
            cursor: .init(r: 16, g: 15, b: 15),
            selection: selection)
    }

    /// An appearance's selection colour reaches the builder opaque, so it replaces the cell's
    /// background; one with no selection colour keeps the default tint.
    @Test func theSelectionTintIsTheSelectionColourOpaque() {
        let tint = Self.lightAppearance(selection: Self.lightSelection).selectionTint
        #expect(tint == Self.lightSelectionPacked,
                "the selection tint is \(hex(tint)), not \(hex(Self.lightSelectionPacked))")
        let fallback = Self.lightAppearance(selection: nil).selectionTint
        #expect(fallback == FrameBuilder.defaultSelectionColor,
                "with no selection colour the tint is \(hex(fallback)), not the default")
    }

    /// A selected cell's background is exactly the selection colour, not white at 20% over the
    /// light background, which is all but the background itself.
    @Test func aSelectedCellsBackgroundIsTheSelectionColour() throws {
        let tint = Self.lightAppearance(selection: Self.lightSelection).selectionTint
        try withSelectedFrame(selectionTint: tint) { surface, _ in
            let cell = surface.backgroundCells[0].color
            #expect(cell == Self.lightSelectionPacked,
                    "the selected cell's background is \(hex(cell)), not the selection colour \(hex(Self.lightSelectionPacked))")
        }
    }

    /// A new selection colour repaints a selection already on screen. libghostty does not know the
    /// colour, so nothing in the terminal is dirty: the builder has to rebuild every row itself.
    @Test func aNewSelectionColourRepaintsTheSelectedCells() throws {
        let tint = Self.lightAppearance(selection: Self.lightSelection).selectionTint
        try withSelectedFrame(selectionTint: tint) { surface, builder in
            surface.selectionColor = Self.lightAppearance(selection: Self.otherSelection).selectionTint
            let update = try builder.update(surface)
            let cell = surface.backgroundCells[0].color
            #expect(cell == Self.otherSelectionPacked,
                    "after the change the selected cell's background is \(hex(cell)), not \(hex(Self.otherSelectionPacked))")
            #expect(update.dirty == .full, "the change was a \(update.dirty) frame, not a full rebuild")
        }
    }

    /// The view hands its surface the selection colour of the appearance it is made with, and of
    /// each appearance applied later, so a theme change reaches an open terminal.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func theViewGivesItsSurfaceEachAppearancesSelectionColour() throws {
        let terminal = try GhosttyTerminal(cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        let view = try GhosttyTerminalView(
            terminal: terminal, appearance: Self.lightAppearance(selection: Self.lightSelection))
        let atInit = view.surface.selectionColor
        #expect(atInit == Self.lightSelectionPacked,
                "the new view's selection tint is \(hex(atInit)), not \(hex(Self.lightSelectionPacked))")

        view.apply(Self.lightAppearance(selection: Self.otherSelection))
        let afterChange = view.surface.selectionColor
        #expect(afterChange == Self.otherSelectionPacked,
                "after a new appearance the selection tint is \(hex(afterChange)), not \(hex(Self.otherSelectionPacked))")

        view.apply(Self.lightAppearance(selection: nil))
        let afterClearing = view.surface.selectionColor
        #expect(afterClearing == FrameBuilder.defaultSelectionColor,
                "with no selection colour the tint is \(hex(afterClearing)), not the default")
    }

    /// Builds the first frame of a 10×3 terminal holding "hello", with everything selected and
    /// `selectionTint` on the surface, without a GPU, and hands `body` the surface and its builder.
    private func withSelectedFrame(
        selectionTint: UInt32, _ body: (TerminalSurface, FrameBuilder) throws -> Void
    ) throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let builder = FrameBuilder(glyphCache: GlyphCache(fontSet: FontSet(font: font, scale: 2), device: nil))
        let terminal = try GhosttyTerminal(cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        terminal.feed(text: "hello")
        let selected = terminal.selectAll()
        try #require(selected, "Select All selected nothing")
        let surface = TerminalSurface()
        surface.selectionColor = selectionTint
        try surface.attach(terminal)
        try builder.update(surface)
        try #require(!surface.backgroundCells.isEmpty, "the first frame built no background cells")
        try body(surface, builder)
    }
}

private func hex(_ color: UInt32) -> String {
    "0x" + String(color, radix: 16, uppercase: true)
}
