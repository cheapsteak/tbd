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
        switch self {
        case .normal:
            return colorScheme == .dark
                ? Color(red: 60 / 255, green: 199 / 255, blue: 95 / 255)
                : Color(red: 27 / 255, green: 107 / 255, blue: 52 / 255)
        case .caution:
            return .orange
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}
