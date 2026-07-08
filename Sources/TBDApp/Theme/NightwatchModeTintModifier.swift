import SwiftUI
import TBDShared

/// View modifier that applies a subtle nightwatch mode tint wash to the view's background.
/// The tint is applied as a low-opacity overlay for a gentle, ambient mood effect.
struct NightwatchModeTintModifier: ViewModifier {
    let mode: NightwatchMode

    func body(content: Content) -> some View {
        ZStack {
            // Tint wash overlay — very low opacity (0.05) for subtlety
            if let tintColor = tintColor(for: mode) {
                tintColor
                    .opacity(0.05)
                    .ignoresSafeArea()
            }
            content
        }
    }
}

extension View {
    /// Applies a subtle nightwatch mode tint wash to this view.
    /// The tint updates automatically when the mode changes.
    func nightwatchModeTint(_ mode: NightwatchMode) -> some View {
        self.modifier(NightwatchModeTintModifier(mode: mode))
    }
}
