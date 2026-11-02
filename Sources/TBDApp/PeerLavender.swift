import AppKit
import SwiftUI

/// The transcript's peer-message colour, in its two appearances: the prompt
/// rail's notches, the card's dashes and text, and a peer bubble's glyph and tint.
///
/// Each appearance matches the WCAG relative luminance of the sidebar's
/// `AttentionAmber` (light 0.2388 vs 0.2384; dark 0.3668 vs 0.3660), so a peer
/// message reads at the same brightness as that amber while carrying a different
/// hue: lavender says *not you*, amber says *this wants your eye*.
///
/// Declared as computed properties rather than stored constants: `NSColor` is not
/// `Sendable`, so a `static let` of one is not expressible under the strict
/// concurrency this package builds with, and minting the colour per read costs
/// nothing at these call rates.
enum PeerLavender {
    /// sRGB 156, 115, 208 (#9C73D0) — the light-appearance lavender.
    static var light: NSColor {
        NSColor(srgbRed: 156 / 255, green: 115 / 255, blue: 208 / 255, alpha: 1)
    }

    /// sRGB 180, 150, 220 (#B496DC) — the dark-appearance lavender.
    static var dark: NSColor {
        NSColor(srgbRed: 180 / 255, green: 150 / 255, blue: 220 / 255, alpha: 1)
    }

    /// Alpha a transcript bubble tints with. The same 15% the accent-tinted user
    /// bubble uses, so a peer bubble and a user bubble differ in hue alone.
    static let bubbleTintAlpha: CGFloat = 0.15

    /// The pair resolved per appearance, fully opaque — the form a glyph or a
    /// label wants.
    static var color: Color { adaptiveColor(light: light, dark: dark) }

    /// The pair resolved per appearance at `alpha`.
    ///
    /// Mirrors `adaptiveColor(light:dark:)` but stays in AppKit, because the
    /// table-backed transcript paints its bubble with an `NSColor` fill and never
    /// goes through SwiftUI.
    static func nsColor(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let base = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return base.withAlphaComponent(alpha)
        }
    }

    /// The peer-bubble tint for the AppKit render site.
    static var bubbleTint: NSColor { nsColor(alpha: bubbleTintAlpha) }

    /// The peer-bubble tint for the SwiftUI render site. Same colour, same alpha.
    static var bubbleTintColor: Color { Color(nsColor: bubbleTint) }
}
