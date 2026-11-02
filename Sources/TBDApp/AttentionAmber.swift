import AppKit
import SwiftUI

/// The app's single `attention` amber, in its two appearances.
///
/// `#B7791F` reads on the light window ground (~`#F1F1F1`); GitHub's
/// `attention.fg` `#D29922` reads on the dark one (~`#1E1E1E`). It is the
/// sidebar's "needs attention" colour: anything that wants to say *this wants
/// your eye* draws the pair from here, so the product carries one amber rather
/// than several that nearly match.
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

    /// The pair resolved per appearance, fully opaque — the form a glyph or a
    /// label wants. `RowStatusIndicator`'s `.attention` case draws it;
    /// only `PRStatusPresentation`'s dark swatch still spells the numbers out
    /// inline.
    static var color: Color { adaptiveColor(light: light, dark: dark) }
}
