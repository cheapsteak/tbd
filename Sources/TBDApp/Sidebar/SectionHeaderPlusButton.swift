import SwiftUI

/// Shared "+" control for sidebar section headers (Repo, Scratch, ...).
/// Reproduces RepoSectionView's original inline plus button exactly — a
/// caption-sized glyph in a 20x20 hit target — so every section header gets
/// the same tap/hover target size.
///
/// The glyph is a parameter so other 20x20 hover affordances on a sidebar row
/// — the worktree row's leading pin toggle — get identical styling and hit-area
/// instead of duplicating `HoverPressButtonStyle` + sizing at each call site.
struct SectionHeaderPlusButton: View {
    /// SF Symbol drawn in the button. Defaults to the "+" every section header
    /// uses; the pin toggle passes `pin` / `pin.slash`.
    var systemImage: String = "plus"
    /// Tooltip text. Pass `nil` for buttons that open a hover menu — a
    /// tooltip would render on top of the menu.
    var help: String? = nil
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(HoverPressButtonStyle())

        if let help {
            button.help(help)
        } else {
            button
        }
    }
}
