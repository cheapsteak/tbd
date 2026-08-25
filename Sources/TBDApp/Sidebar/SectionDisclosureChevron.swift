import SwiftUI

/// The disclosure chevron a collapsible sidebar section wears — a project row
/// (`RepoSectionView`) and the Scratch section (`ScratchSectionView`) share
/// this one view so the two cannot drift apart in placement, glyph size, hover
/// treatment, or what a screen reader hears.
///
/// `AppState.chevronBeforeProjectNameKey` decides which of two presentations
/// every section uses; the caller reads the setting and passes it as
/// `beforeTitle`, along with the placement's `isMounted` gate from
/// `SidebarHeaderMetrics.chevronMounted(beforeTitle:revealed:)`.
///
/// After the title (the default) it trails the name and takes the `+`'s hover
/// wash and hover gate, so the two affordances appear and vanish together and the resting
/// sidebar is quieter. That gate is deliberate and was signed off by the
/// maintainer: it costs the at-a-glance state read and pointer-free
/// reachability, because the caller's hover state is driven only by `.onHover`,
/// so the button is absent from the focus tree until a pointer enters the
/// section and Tab/Full Keyboard Access skips it. The accepted answer for
/// keyboard-only users is each section's ungated context-menu Collapse/Expand
/// item, which performs the same action — and the setting itself, whose
/// default placement is never gated. So do not "fix" the trailing placement by
/// always-mounting it; that reverses a decision someone made on purpose.
///
/// Before the title, the chevron is always mounted and plainly styled, so the
/// glyph sits in the same column on every row and the expanded/collapsed state
/// reads at a glance.
///
/// The unmounted branch keeps the chevron's square so nothing beside it slides
/// sideways as the glyph comes and goes.
struct SectionDisclosureChevron: View {
    let isExpanded: Bool
    /// Where this chevron sits relative to its section title — read from
    /// `AppState.chevronBeforeProjectNameKey` by the caller.
    let beforeTitle: Bool
    /// Whether the button is mounted right now; `Color.clear` holds its place
    /// when it isn't. See `SidebarHeaderMetrics.chevronMounted`.
    let isMounted: Bool
    /// What VoiceOver announces — the glyph carries no text of its own.
    let accessibilityLabel: String
    /// Overridden by a project row so a `.missing` repo's chevron dims with
    /// the rest of its header.
    var glyphStyle: AnyShapeStyle = AnyShapeStyle(HierarchicalShapeStyle.secondary)
    /// The section dims its rows while the chevron is hovered, so it needs the
    /// hover edges the button sees.
    var onHoverChange: (Bool) -> Void = { _ in }
    let toggle: () -> Void

    var body: some View {
        Group {
            if isMounted {
                if beforeTitle {
                    button.buttonStyle(.plain)
                } else {
                    button.buttonStyle(HoverPressButtonStyle())
                }
            } else {
                Color.clear
            }
        }
        .frame(width: SidebarHeaderMetrics.chevronColumnWidth,
               height: SidebarHeaderMetrics.chevronColumnWidth)
        // The square hit target centers the glyph, leaving ~4pt of slack on
        // each side. Trailing the title, trim the leading slack so the chevron
        // reads as attached to the title rather than floating after it, and
        // nudge down so it sits on the title's optical baseline rather than
        // its cap-height center. Both are layout-neutral for the hit target,
        // which rides along with the glyph. Leading the title, that slack is
        // what separates the glyph from the window edge, so it stays.
        .padding(.leading, beforeTitle ? 0 : -3)
        .offset(y: beforeTitle ? 0 : 2)
    }

    /// The button and its label, styleless — `body` applies the style the
    /// placement calls for. The glyph is a point smaller trailing the title so
    /// it doesn't outweigh the title it follows.
    private var button: some View {
        Button(action: toggle) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: beforeTitle ? 11 : 10))
                // Applied to the glyph, not the button, so it wins over
                // `HoverPressButtonStyle`'s blanket `.secondary` and a missing
                // repo still renders dimmed.
                .foregroundStyle(glyphStyle)
                .frame(width: SidebarHeaderMetrics.chevronColumnWidth,
                       height: SidebarHeaderMetrics.chevronColumnWidth)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(accessibilityLabel)
        .onHover { onHoverChange($0) }
        .help(isExpanded ? "Collapse" : "Expand")
    }
}
