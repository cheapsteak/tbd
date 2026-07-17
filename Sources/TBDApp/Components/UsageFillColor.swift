import SwiftUI

/// Shared color mapping for usage fill levels, consumed by both the
/// compact bars and the account picker to ensure consistency.
extension ProfileUsagePresentation.FillLevel {
    /// Bar/percent color for this fill level, adapted to the current appearance.
    /// Green reads on both themes: brighter mint in dark mode, deeper forest in light.
    /// Yellow reads on both themes: bright warm yellow in dark, deeper amber in light.
    func barColor(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .normal:
            return colorScheme == .dark
                ? Color(red: 60 / 255, green: 199 / 255, blue: 95 / 255)
                : Color(red: 27 / 255, green: 107 / 255, blue: 52 / 255)
        case .caution:
            return colorScheme == .dark
                ? Color(red: 235 / 255, green: 194 / 255, blue: 52 / 255)
                : Color(red: 158 / 255, green: 110 / 255, blue: 6 / 255)
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}
