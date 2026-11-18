import Observation
import SwiftUI

/// Whether a transcript pane's prompt rail lens is on screen, for the
/// overlays above the rail that hide while it is (lens spec, "Overlays above
/// the rail"). Each pane that mounts the rail owns one in `@State` and hands
/// it to its `TableTranscriptView`, whose coordinator sets `isShown`.
///
/// Only those overlays read `isShown`, each in its own body. The pane never
/// does: a pane re-render reruns `updateNSView`, and with it the table's
/// whole-transcript comparison (rail spec, "Views"). Holding the reference
/// in `@State` observes nothing; reading the property would.
@MainActor
@Observable
final class PromptLensVisibility {
    var isShown = false
}

/// A transcript pane's floating jump-to-latest button. It shows while the
/// transcript is scrolled up from its newest message and the prompt rail's
/// lens is not on screen (`TableTranscriptView.showsJumpToBottom`), so it
/// never covers the lens's rows or takes their clicks. It reads the lens's
/// visibility in its own body, so the lens opening and closing re-renders it
/// alone, never the pane.
struct TranscriptJumpToLatestButton: View {
    let atBottom: Bool
    let lensVisibility: PromptLensVisibility
    /// Room kept clear on the leading side, for a button overlaid across the
    /// rail's gutter.
    var leadingInset: CGFloat = 0
    let action: @MainActor () -> Void

    var body: some View {
        if TableTranscriptView.showsJumpToBottom(atBottom: atBottom, promptLensShown: lensVisibility.isShown) {
            Button(action: action) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(radius: 4)
            }
            .buttonStyle(.plain)
            .padding(16)
            .padding(.leading, leadingInset)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
            .help("Scroll to bottom")
        }
    }
}
