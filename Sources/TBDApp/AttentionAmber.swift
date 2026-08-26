import AppKit
import SwiftUI

/// The app's single `attention` amber, in its two appearances.
///
/// `#B7791F` reads on the light window ground (~`#F1F1F1`); GitHub's
/// `attention.fg` `#D29922` reads on the dark one (~`#1E1E1E`). Anything that
/// wants to say *this wants your eye* — the sidebar's attention glyph, the amber
/// tint on a peer-message transcript bubble — draws the pair from here, so the
/// product carries one amber rather than several that nearly match.
///
/// Declared as computed properties rather than stored constants: `NSColor` is not
/// `Sendable`, so a `static let` of one is not expressible under the strict
/// concurrency this package builds with, and minting the colour per read costs
/// nothing at these call rates.
enum AttentionAmber {
    /// sRGB 183, 121, 31 — the light-appearance amber.
    static var light: NSColor {
        NSColor(srgbRed: 183 / 255, green: 121 / 255, blue: 31 / 255, alpha: 1)
    }

    /// sRGB 210, 153, 34 — GitHub `attention.fg`, the dark-appearance amber.
    static var dark: NSColor {
        NSColor(srgbRed: 210 / 255, green: 153 / 255, blue: 34 / 255, alpha: 1)
    }

    /// Alpha a transcript bubble tints with. The same 15% the accent-tinted user
    /// bubble uses, so a peer bubble and a user bubble differ in hue alone.
    static let bubbleTintAlpha: CGFloat = 0.15

    /// The pair resolved per appearance, fully opaque — the form a glyph or a
    /// label wants. `RowStatusIndicator`'s `.attention` case and
    /// `PRStatusPresentation`'s dark swatch still spell these numbers out inline;
    /// folding them onto this property is a mechanical follow-up.
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
