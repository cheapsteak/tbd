import AppKit
import SwiftUI

/// Shared color mapping for usage fill levels, consumed by both the
/// compact bars and the account picker to ensure consistency.
extension ProfileUsagePresentation.FillLevel {
    /// Bar/percent color for this fill level, matching Claude-Usage-Tracker's
    /// three-tier scheme exactly: adaptive green (brighter mint in dark mode,
    /// deeper forest in light), then plain system orange/red. `.caution` and
    /// `.warning` intentionally share orange — the tracker's bars have no
    /// separate yellow tier.
    func barColor(_ colorScheme: ColorScheme) -> Color {
        Color(nsColor: nsBarColor(isDark: colorScheme == .dark))
    }

    /// The AppKit form of `barColor`, and the one table both read. The account
    /// menus' bars image takes it, choosing light or dark when it draws.
    func nsBarColor(isDark: Bool) -> NSColor {
        switch self {
        case .normal:
            return isDark
                ? NSColor(srgbRed: 60 / 255, green: 199 / 255, blue: 95 / 255, alpha: 1)
                : NSColor(srgbRed: 27 / 255, green: 107 / 255, blue: 52 / 255, alpha: 1)
        case .caution, .warning:
            return .systemOrange
        case .critical:
            return .systemRed
        }
    }
}
