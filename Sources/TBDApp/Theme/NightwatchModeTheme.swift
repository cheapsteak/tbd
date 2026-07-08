import SwiftUI
import TBDShared

/// Computes the tint color for a given nightwatch mode.
/// - .off: returns nil (no tint)
/// - .daywatch: returns a warm, golden amber tint
/// - .nightwatch: returns a cool, deep indigo tint
func tintColor(for mode: NightwatchMode) -> Color? {
    switch mode {
    case .off:
        return nil
    case .daywatch:
        // Warm golden amber — approx. #D4A574 in a subtle, low-opacity wash
        return Color(red: 0.835, green: 0.647, blue: 0.455)
    case .nightwatch:
        // Cool deep indigo — approx. #3B5998 in a subtle, low-opacity wash
        return Color(red: 0.231, green: 0.349, blue: 0.596)
    }
}
