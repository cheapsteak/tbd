import SwiftUI

/// The file viewer's "Cannot preview" screen, for a file with no view of its
/// own and for a media file that turns out not to play.
///
/// Its two buttons never hand the file to its default app: Quick Look shows it
/// in the floating panel, and Reveal in Finder selects it in a Finder window.
/// `actions` is injectable so a test can see which one ran.
struct BinaryFallbackView: View {
    let filePath: String
    var actions: BinaryFallbackActions = .live()

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Cannot preview binary file")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(URL(fileURLWithPath: filePath).lastPathComponent)
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Button("Quick Look") {
                    actions.openQuickLook(filePath)
                }
                .buttonStyle(.borderedProminent)
                Button("Reveal in Finder") {
                    actions.reveal(filePath)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
