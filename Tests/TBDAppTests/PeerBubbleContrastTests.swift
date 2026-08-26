import AppKit
import SwiftUI
import Testing
@testable import TBDApp

/// WCAG contrast for the amber tint a peer-message bubble carries.
///
/// A 15%-alpha tint has no contrast of its own — it composites against whatever
/// sits behind it — so every figure here is computed from the COMPOSITED bubble
/// colour rather than from the swatch, and every assertion is on a computed ratio
/// rather than on a hex string. A later change to the amber, to the pane
/// background, or to a foreground colour therefore reddens this suite instead of
/// degrading legibility quietly.
///
/// Two requirements are asserted, and they are deliberately different in kind:
///
/// - **Body text and inline code clear AA (4.5:1) on the peer bubble**, in both
///   appearances. This is an absolute floor.
/// - **Link and secondary text are no worse on a peer bubble than on the
///   accent-tinted user bubble.** Those two foregrounds sit below AA on *every*
///   bubble in the transcript — a pre-existing condition of the link colour, not
///   something the amber introduces — so the amber is held to parity with what
///   ships today rather than to a floor it cannot reach alone. Comparing computed
///   ratios (rather than pinning a number) keeps the comparison meaningful if
///   either tint changes.
@MainActor
@Suite("PeerBubbleContrast")
struct PeerBubbleContrastTests {

    // MARK: - Colour arithmetic

    /// An opaque sRGB triple, components 0...1.
    private struct RGB {
        var r: Double
        var g: Double
        var b: Double
    }

    /// An sRGB colour with alpha, components 0...1.
    private struct RGBA {
        var r: Double
        var g: Double
        var b: Double
        var a: Double
    }

    /// `top` composited over the opaque `bottom` (source-over, straight alpha).
    private func over(_ top: RGBA, _ bottom: RGB) -> RGB {
        RGB(
            r: top.a * top.r + (1 - top.a) * bottom.r,
            g: top.a * top.g + (1 - top.a) * bottom.g,
            b: top.a * top.b + (1 - top.a) * bottom.b
        )
    }

    /// sRGB → linear, per the WCAG 2.x definition.
    private func linearized(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private func luminance(_ rgb: RGB) -> Double {
        0.2126 * linearized(rgb.r) + 0.7152 * linearized(rgb.g) + 0.0722 * linearized(rgb.b)
    }

    /// WCAG relative-contrast ratio between two opaque colours.
    private func contrast(_ lhs: RGB, _ rhs: RGB) -> Double {
        let (x, y) = (luminance(lhs), luminance(rhs))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Resolves a (possibly dynamic) `NSColor` in one appearance and reads its
    /// sRGB components. Returns nil rather than a plausible-looking black if the
    /// conversion fails, so a resolution problem fails the test loudly instead of
    /// silently measuring the wrong colour.
    private func srgb(_ color: NSColor, in appearance: NSAppearance) -> RGBA? {
        var resolved: RGBA?
        appearance.performAsCurrentDrawingAppearance {
            guard let converted = color.usingColorSpace(.sRGB) else { return }
            resolved = RGBA(
                r: Double(converted.redComponent),
                g: Double(converted.greenComponent),
                b: Double(converted.blueComponent),
                a: Double(converted.alphaComponent)
            )
        }
        return resolved
    }

    // MARK: - Fixtures

    /// WCAG AA floor for normal-size text.
    private static let aaFloor = 4.5

    /// Slack on the design's recorded body-text figures. Wider than the
    /// inline-code slack because `labelColor` is a system semantic colour whose
    /// exact alpha is an implementation detail we do not pin; the load-bearing
    /// assertion for body text is `aaFloor`, which it clears by a wide margin.
    private static let bodyAnchorSlack = 2.0

    /// Slack on the recorded inline-code figures. Tight, because
    /// `chatBubbleInlineCode` is an app-owned opaque pair.
    private static let inlineCodeAnchorSlack = 1.0

    /// How much worse a peer bubble may measure than the user bubble before the
    /// parity requirement is considered broken. The design measured the gap at
    /// roughly a tenth of a ratio point; the slack here also absorbs the fact that
    /// the user bubble's tint is the SYSTEM accent colour, which the machine
    /// running the test chooses and which shifts that side of the comparison.
    private static let paritySlack = 0.75

    /// The transcript pane's ground behind a bubble, per appearance. Fixed rather
    /// than resolved from a live view so the composite is reproducible anywhere.
    private static let paneLight = RGB(r: 1, g: 1, b: 1)
    private static let paneDark = RGB(r: 30.0 / 255, g: 30.0 / 255, b: 30.0 / 255)

    private struct AppearanceCase {
        let name: String
        let appearance: NSAppearance
        let pane: RGB
        /// Body-text ratio the design records for this appearance.
        let bodyAnchor: Double
        /// Inline-code ratio the design records for this appearance.
        let inlineCodeAnchor: Double
    }

    private func appearanceCases() throws -> [AppearanceCase] {
        let aqua = try #require(NSAppearance(named: .aqua))
        let darkAqua = try #require(NSAppearance(named: .darkAqua))
        return [
            AppearanceCase(
                name: "light",
                appearance: aqua,
                pane: Self.paneLight,
                bodyAnchor: 12.8,
                inlineCodeAnchor: 5.8
            ),
            AppearanceCase(
                name: "dark",
                appearance: darkAqua,
                pane: Self.paneDark,
                bodyAnchor: 10.7,
                inlineCodeAnchor: 6.3
            )
        ]
    }

    /// The amber tint the peer bubble actually paints, composited over the pane.
    private func peerBubble(_ appearanceCase: AppearanceCase) throws -> RGB {
        let tint = try #require(
            srgb(AttentionAmber.bubbleTint, in: appearanceCase.appearance),
            "amber tint did not resolve in \(appearanceCase.name)"
        )
        return over(tint, appearanceCase.pane)
    }

    /// Today's accent-tinted user bubble, composited over the same pane. The
    /// accent is resolved live and the 15% alpha applied here, because
    /// `withAlphaComponent` on a catalog colour is not reliably preserved through
    /// an sRGB conversion.
    private func userBubble(_ appearanceCase: AppearanceCase) throws -> RGB {
        var tint = try #require(
            srgb(.controlAccentColor, in: appearanceCase.appearance),
            "accent colour did not resolve in \(appearanceCase.name)"
        )
        tint.a = Double(AttentionAmber.bubbleTintAlpha)
        return over(tint, appearanceCase.pane)
    }

    /// Contrast of `foreground` (composited, so its own alpha counts) against a
    /// composited bubble colour.
    private func ratio(
        of foreground: NSColor,
        on bubble: RGB,
        in appearanceCase: AppearanceCase
    ) throws -> Double {
        let fg = try #require(
            srgb(foreground, in: appearanceCase.appearance),
            "foreground did not resolve in \(appearanceCase.name)"
        )
        return contrast(over(fg, bubble), bubble)
    }

    /// The transcript's inline-code foreground, as an `NSColor` so it can be
    /// resolved per appearance.
    private var inlineCodeColor: NSColor { NSColor(Color.chatBubbleInlineCode) }

    // MARK: - Tests

    @Test("the peer tint is the amber pair at the same 15% alpha the accent tint uses")
    func tintAlphaMatchesTheAccentTint() throws {
        for appearanceCase in try appearanceCases() {
            let tint = try #require(srgb(AttentionAmber.bubbleTint, in: appearanceCase.appearance))
            #expect(
                abs(tint.a - Double(AttentionAmber.bubbleTintAlpha)) < 0.005,
                "\(appearanceCase.name): tint alpha \(tint.a), expected \(AttentionAmber.bubbleTintAlpha)"
            )
        }
    }

    @Test("the amber resolves to a different colour in each appearance")
    func amberIsAppearanceDependent() throws {
        let cases = try appearanceCases()
        let light = try #require(srgb(AttentionAmber.bubbleTint, in: cases[0].appearance))
        let dark = try #require(srgb(AttentionAmber.bubbleTint, in: cases[1].appearance))
        let distance = abs(light.r - dark.r) + abs(light.g - dark.g) + abs(light.b - dark.b)
        // A collapsed dynamic colour would measure the SAME swatch twice and make
        // every ratio below meaningless while still passing.
        #expect(distance > 0.02, "amber resolved identically in both appearances (distance \(distance))")
    }

    @Test("the inline-code foreground resolves to a different colour in each appearance")
    func inlineCodeIsAppearanceDependent() throws {
        let cases = try appearanceCases()
        let light = try #require(srgb(inlineCodeColor, in: cases[0].appearance))
        let dark = try #require(srgb(inlineCodeColor, in: cases[1].appearance))
        let distance = abs(light.r - dark.r) + abs(light.g - dark.g) + abs(light.b - dark.b)
        #expect(distance > 0.02, "inline-code colour resolved identically in both appearances")
    }

    @Test("body text clears WCAG AA on the peer bubble in both appearances")
    func bodyTextClearsAA() throws {
        for appearanceCase in try appearanceCases() {
            let bubble = try peerBubble(appearanceCase)
            let measured = try ratio(of: .labelColor, on: bubble, in: appearanceCase)
            #expect(
                measured >= Self.aaFloor,
                "\(appearanceCase.name): body text measured \(measured):1, below the \(Self.aaFloor):1 floor"
            )
            #expect(
                abs(measured - appearanceCase.bodyAnchor) <= Self.bodyAnchorSlack,
                "\(appearanceCase.name): body text measured \(measured):1, far from the recorded \(appearanceCase.bodyAnchor):1"
            )
        }
    }

    @Test("inline code clears WCAG AA on the peer bubble in both appearances")
    func inlineCodeClearsAA() throws {
        for appearanceCase in try appearanceCases() {
            let bubble = try peerBubble(appearanceCase)
            let measured = try ratio(of: inlineCodeColor, on: bubble, in: appearanceCase)
            #expect(
                measured >= Self.aaFloor,
                "\(appearanceCase.name): inline code measured \(measured):1, below the \(Self.aaFloor):1 floor"
            )
            #expect(
                abs(measured - appearanceCase.inlineCodeAnchor) <= Self.inlineCodeAnchorSlack,
                "\(appearanceCase.name): inline code measured \(measured):1, far from the recorded \(appearanceCase.inlineCodeAnchor):1"
            )
        }
    }

    @Test("link text is no worse on a peer bubble than on a user bubble")
    func linkTextIsNoWorseThanOnAUserBubble() throws {
        for appearanceCase in try appearanceCases() {
            let peer = try ratio(of: .linkColor, on: peerBubble(appearanceCase), in: appearanceCase)
            let user = try ratio(of: .linkColor, on: userBubble(appearanceCase), in: appearanceCase)
            #expect(
                peer >= user - Self.paritySlack,
                "\(appearanceCase.name): link measures \(peer):1 on the peer bubble versus \(user):1 on the user bubble"
            )
        }
    }

    @Test("secondary text is no worse on a peer bubble than on a user bubble")
    func secondaryTextIsNoWorseThanOnAUserBubble() throws {
        for appearanceCase in try appearanceCases() {
            let peer = try ratio(of: .secondaryLabelColor, on: peerBubble(appearanceCase), in: appearanceCase)
            let user = try ratio(of: .secondaryLabelColor, on: userBubble(appearanceCase), in: appearanceCase)
            #expect(
                peer >= user - Self.paritySlack,
                "\(appearanceCase.name): secondary text measures \(peer):1 on the peer bubble versus \(user):1 on the user bubble"
            )
        }
    }
}
