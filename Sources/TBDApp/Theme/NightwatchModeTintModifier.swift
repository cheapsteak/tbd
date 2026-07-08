import SwiftUI
import TBDShared

/// View modifier that applies a subtle nightwatch mode tint wash to the view's background.
/// The tint is applied as a low-opacity overlay for a gentle, ambient mood effect.
/// Gated behind the experimental opt-in flag to maintain fail-closed behavior.
struct NightwatchModeTintModifier: ViewModifier {
    let mode: NightwatchMode
    let experimentalEnabled: Bool

    func body(content: Content) -> some View {
        if experimentalEnabled {
            ZStack {
                // Tint wash overlay — very low opacity (0.05) for subtlety
                if let tintColor = tintColor(for: mode) {
                    tintColor
                        .opacity(0.05)
                        .ignoresSafeArea()
                }
                content
            }
        } else {
            content
        }
    }
}

extension View {
    /// Applies a subtle nightwatch mode tint wash to this view.
    /// The tint updates automatically when the mode changes.
    /// Only applies if the experimental opt-in flag is enabled.
    func nightwatchModeTint(_ mode: NightwatchMode, experimentalEnabled: Bool) -> some View {
        self.modifier(NightwatchModeTintModifier(mode: mode, experimentalEnabled: experimentalEnabled))
    }
}
