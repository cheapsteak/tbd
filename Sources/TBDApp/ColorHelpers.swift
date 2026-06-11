import AppKit
import SwiftUI

/// Resolves an `NSColor` per appearance so SwiftUI sees the correct value in light/dark mode.
func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}
