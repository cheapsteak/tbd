import SwiftUI

/// Shared "+" control for sidebar section headers (Repo, Scratch, ...).
/// Reproduces RepoSectionView's original inline plus button exactly — a
/// caption-sized glyph in a 20x20 hit target — so every section header gets
/// the same tap/hover target size.
struct SectionHeaderPlusButton: View {
    /// Tooltip text. Pass `nil` for buttons that open a hover menu — a
    /// tooltip would render on top of the menu.
    var help: String? = nil
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        let button = Button(action: action) {
            Image(systemName: "plus")
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
