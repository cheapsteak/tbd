import AppKit
import SwiftUI
import Testing
@testable import TBDApp

/// The transcript's peer colour is lavender at the brightness the amber had,
/// every reachable peer surface draws it, and the sidebar's attention amber is
/// untouched.
@MainActor
@Suite("PeerLavender")
struct PeerLavenderTests {

    private struct RGBA {
        var r: Double
        var g: Double
        var b: Double
        var a: Double
    }

    /// Resolves a (possibly dynamic) `NSColor` in one appearance; nil on failure
    /// so a resolution problem fails loudly instead of measuring black.
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

    private func linearized(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private func luminance(_ rgb: RGBA) -> Double {
        0.2126 * linearized(rgb.r) + 0.7152 * linearized(rgb.g) + 0.0722 * linearized(rgb.b)
    }

    /// Keep the brightness the owner asked to keep.
    private static let luminanceTolerance = 0.01

    /// Component tolerance on the 0...255 scale.
    private static let componentTolerance = 0.5

    private struct Case {
        let name: String
        let appearance: NSAppearance
        let lavender: (r: Double, g: Double, b: Double)
        let amber: (r: Double, g: Double, b: Double)
        let lavenderColor: NSColor
        let amberColor: NSColor
    }

    private func cases() throws -> [Case] {
        let aqua = try #require(NSAppearance(named: .aqua))
        let darkAqua = try #require(NSAppearance(named: .darkAqua))
        return [
            Case(name: "light", appearance: aqua, lavender: (156, 115, 208), amber: (183, 121, 31),
                 lavenderColor: PeerLavender.light, amberColor: AttentionAmber.light),
            Case(name: "dark", appearance: darkAqua, lavender: (180, 150, 220), amber: (210, 153, 34),
                 lavenderColor: PeerLavender.dark, amberColor: AttentionAmber.dark)
        ]
    }

    private func matches(_ rgba: RGBA, _ expected: (r: Double, g: Double, b: Double)) -> Bool {
        abs(rgba.r * 255 - expected.r) <= Self.componentTolerance
            && abs(rgba.g * 255 - expected.g) <= Self.componentTolerance
            && abs(rgba.b * 255 - expected.b) <= Self.componentTolerance
    }

    @Test("lavender has the luminance of the amber it sits beside, in both appearances")
    func luminanceMatchesAmber() throws {
        for c in try cases() {
            let lavender = luminance(try #require(srgb(c.lavenderColor, in: c.appearance)))
            let amber = luminance(try #require(srgb(c.amberColor, in: c.appearance)))
            #expect(
                abs(lavender - amber) <= Self.luminanceTolerance,
                "\(c.name): lavender \(lavender) vs amber \(amber)"
            )
        }
    }

    @Test("lavender resolves to the exact sRGB values")
    func exactValues() throws {
        let aqua = try #require(NSAppearance(named: .aqua))
        let darkAqua = try #require(NSAppearance(named: .darkAqua))
        let light = try #require(srgb(PeerLavender.light, in: aqua))
        let dark = try #require(srgb(PeerLavender.dark, in: darkAqua))
        #expect(matches(light, (156, 115, 208)))
        #expect(matches(dark, (180, 150, 220)))
    }

    @Test("every reachable peer surface draws PeerLavender, not the amber")
    func peerSurfacesResolveToLavender() throws {
        let inactiveAlpha = Double(PromptRailNotchStyle.inactivePeerAlpha)
        let tintAlpha = Double(PeerLavender.bubbleTintAlpha)
        let kind = PromptOutlineEntry.Kind.peer(sender: "acme")
        for c in try cases() {
            let surfaces: [(String, NSColor, Double)] = [
                ("active notch", PromptRailNotchStyle.color(for: kind, active: true), 1),
                ("inactive notch", PromptRailNotchStyle.color(for: kind, active: false), inactiveAlpha),
                ("bubble background", TranscriptBubbleGeometry.backgroundColor(for: .peer), tintAlpha)
            ]
            for (label, color, alpha) in surfaces {
                let got = try #require(srgb(color, in: c.appearance), "\(label) did not resolve in \(c.name)")
                #expect(matches(got, c.lavender), "\(c.name) \(label): not lavender")
                #expect(!matches(got, c.amber), "\(c.name) \(label): is the amber")
                #expect(abs(got.a - alpha) < 0.005, "\(c.name) \(label): alpha \(got.a), expected \(alpha)")
            }
        }
    }

    @Test("the sidebar attention colour is still the amber")
    func sidebarAttentionUnchanged() throws {
        for c in try cases() {
            let sidebar = NSColor(SuffixRowIndicator.attention.color)
            let got = try #require(srgb(sidebar, in: c.appearance), "sidebar attention did not resolve in \(c.name)")
            #expect(matches(got, c.amber), "\(c.name): sidebar attention changed")
            let amber = try #require(srgb(c.amberColor, in: c.appearance))
            #expect(matches(amber, c.amber), "\(c.name): AttentionAmber changed")
        }
    }
}
