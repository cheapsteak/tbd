import SwiftUI
import TBDShared

/// Pure, view-free presentation model for one Nightwatch mode segment. Extracted
/// so the label / glyph / help copy and the active-state logic are unit-testable
/// without instantiating any SwiftUI view. The sidebar control renders one
/// segment per `NightwatchMode` case and highlights the one matching the active
/// mode.
enum NightwatchModePresentation {
    /// Every mode, in display order (Off · Day · Night).
    static let ordered: [NightwatchMode] = [.off, .daywatch, .nightwatch]

    /// Short segment label shown in the sidebar control.
    static func label(_ mode: NightwatchMode) -> String {
        switch mode {
        case .off: return "Off"
        case .daywatch: return "Day"
        case .nightwatch: return "Night"
        }
    }

    /// Glyph prefixed to the label (◐ = daywatch, 🌙 = nightwatch, none = off).
    /// Matches the menu-bar item's glyph vocabulary.
    static func glyph(_ mode: NightwatchMode) -> String? {
        switch mode {
        case .off: return nil
        case .daywatch: return "◐"
        case .nightwatch: return "🌙"
        }
    }

    /// Label with the glyph prepended, e.g. "◐ Day". Used for the visible
    /// segment text and its accessibility label.
    static func glyphLabel(_ mode: NightwatchMode) -> String {
        if let glyph = glyph(mode) {
            return "\(glyph) \(label(mode))"
        }
        return label(mode)
    }

    /// Short help explaining what each mode does. "daywatch"/"nightwatch" are
    /// not self-evident, so the control carries this as a tooltip.
    static func help(_ mode: NightwatchMode) -> String {
        switch mode {
        case .off: return "Off — not watching"
        case .daywatch: return "Daywatch — watching while you're around"
        case .nightwatch: return "Nightwatch — watching while you're away"
        }
    }

    /// Whether `segment` is the currently-active mode (drives the filled/tinted
    /// highlight so a glance answers "what mode am I in?").
    static func isActive(segment: NightwatchMode, current: NightwatchMode) -> Bool {
        segment == current
    }
}

/// Compact three-state Nightwatch mode control pinned in the sidebar footer.
/// `Off | ◐ Day | 🌙 Night` — the active mode is filled/tinted; tapping a
/// segment calls `setNightwatchMode`. Always visible so the mode is never lost
/// in the menu bar.
struct NightwatchModeToggle: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NightwatchModePresentation.ordered, id: \.self) { mode in
                segment(mode)
                if mode != NightwatchModePresentation.ordered.last {
                    Divider()
                        .frame(height: 14)
                        .opacity(0.4)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nightwatch mode")
    }

    @ViewBuilder
    private func segment(_ mode: NightwatchMode) -> some View {
        let isActive = NightwatchModePresentation.isActive(
            segment: mode, current: appState.nightwatchMode)
        Button {
            Task { @MainActor in
                await appState.setNightwatchMode(mode)
            }
        } label: {
            Text(NightwatchModePresentation.glyphLabel(mode))
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isActive ? Color.accentColor.opacity(0.14) : Color.clear)
                        .padding(1)
                )
        }
        .buttonStyle(.plain)
        .help(NightwatchModePresentation.help(mode))
        .accessibilityLabel(NightwatchModePresentation.glyphLabel(mode))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}
