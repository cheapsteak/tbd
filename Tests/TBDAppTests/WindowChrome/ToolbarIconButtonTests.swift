import AppKit
import Testing
@testable import TBDApp

// Tier 1: pure values and a button made in memory, with no window and no
// waits.

/// `ToolbarIconButton`, the toolbar's icon button that draws its own hover
/// and pressed square over its whole frame. Spec:
/// docs/specs/2026-11-01-appkit-window-chrome-design.md, "Compact buttons".
@MainActor
@Suite("Toolbar icon button")
struct ToolbarIconButtonTests {
    /// The square's colour in every state: none while disabled, whatever
    /// else holds; none at rest; the hover colour while hovered; the pressed
    /// colour while pressed, which wins over hovered. The two colours differ,
    /// so pressed reads darker than hovered.
    @Test func highlightFillFollowsTheState() {
        let hover = NSColor.quaternaryLabelColor
        let pressed = ToolbarIconButton.pressedFill
        let cases: [(hovered: Bool, pressed: Bool, enabled: Bool, expected: NSColor?)] = [
            (hovered: false, pressed: false, enabled: false, expected: nil),
            (hovered: true, pressed: false, enabled: false, expected: nil),
            (hovered: false, pressed: true, enabled: false, expected: nil),
            (hovered: true, pressed: true, enabled: false, expected: nil),
            (hovered: false, pressed: false, enabled: true, expected: nil),
            (hovered: true, pressed: false, enabled: true, expected: hover),
            (hovered: false, pressed: true, enabled: true, expected: pressed),
            (hovered: true, pressed: true, enabled: true, expected: pressed),
        ]
        for state in cases {
            let fill = ToolbarIconButton.highlightFill(
                isHovered: state.hovered, isPressed: state.pressed, isEnabled: state.enabled)
            let expected = state.expected
            #expect(
                fill == expected,
                "hovered \(state.hovered), pressed \(state.pressed), enabled \(state.enabled)")
        }
        let hoverFill = ToolbarIconButton.hoverFill
        #expect(hoverFill == hover)
        let distinct = pressed != hover
        #expect(distinct)
    }

    /// A new button is borderless, so its hit area is its frame, untitled,
    /// image-only and unscaled, and keeps the frame it was made with.
    @Test func aNewButtonIsBorderlessAndImageOnly() {
        let frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        let button = ToolbarIconButton(frame: frame)
        #expect(button.isBordered == false)
        #expect(button.title.isEmpty)
        #expect(button.imagePosition == .imageOnly)
        #expect(button.imageScaling == .scaleNone)
        let made = button.frame
        #expect(made == frame)
    }
}
