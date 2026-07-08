import SwiftUI
import TBDShared

/// View modifier that applies a subtle nightwatch mode tint wash to the view's background.
/// The tint is applied as a low-opacity overlay for a gentle, ambient mood effect.
/// Gated behind the experimental opt-in flag to maintain fail-closed behavior.
struct NightwatchModeTintModifier: ViewModifier {
    let mode: NightwatchMode
    let experimentalEnabled: Bool

    /// Resolves the tint color based on mode and experimental flag.
    /// Returns nil when the feature is disabled or the mode has no tint.
    static func resolvedTint(mode: NightwatchMode, experimentalEnabled: Bool) -> Color? {
        guard experimentalEnabled else { return nil }
        return tintColor(for: mode)
    }

    func body(content: Content) -> some View {
        if let tintColor = Self.resolvedTint(mode: mode, experimentalEnabled: experimentalEnabled) {
            ZStack {
                // Tint wash overlay — very low opacity (0.05) for subtlety
                tintColor
                    .opacity(0.05)
                    .ignoresSafeArea()
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
