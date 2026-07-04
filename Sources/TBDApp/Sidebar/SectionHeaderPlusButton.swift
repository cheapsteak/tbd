import SwiftUI

/// Shared "+" control for sidebar section headers (Repo, Scratch, ...).
/// Reproduces RepoSectionView's original inline plus button exactly — a
/// caption-sized glyph in a 20x20 hit target — so every section header gets
/// the same tap/hover target size.
struct SectionHeaderPlusButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.caption)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(HoverPressButtonStyle())
        .help(help)
    }
}
