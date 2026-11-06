import SwiftUI

/// An audio file in the file viewer: a music symbol, the file name and the
/// system play bar, on the pane's own background.
///
/// The `AVPlayerView` is framed to the height of its inline control bar, which
/// shows the file's length, so the view adds no caption of its own.
/// `MediaPlayerHostView` hides AVKit's grey audio-only backdrop, which leaves
/// the play bar as the only shape drawn.
struct AudioPreviewView: View {
    let filePath: String
    let revision: Int
    /// True when this is the only file in the pane: it centres itself in the
    /// pane's visible area. False in a multi-file stack, where it takes its
    /// own height.
    let fillsViewport: Bool
    let onLoadFailure: @MainActor () -> Void

    /// The height the view frames its `AVPlayerView` at: the inline control
    /// bar alone.
    static let controlBarHeight: CGFloat = 44

    /// One modifier chain whose arguments follow `fillsViewport`, never an
    /// `if`/`else` over it. A branch would move `MediaPlayerView` to another
    /// place in the view tree whenever the selection goes between one file and
    /// several, and SwiftUI would dismantle it, stopping and resetting
    /// playback. An empty axis set sizes neither axis, so in a stack
    /// `containerRelativeFrame` takes its content's size and changes nothing.
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: fillsViewport ? .infinity : nil)
            .containerRelativeFrame(fillsViewport ? .vertical : [])
            .padding(.vertical, fillsViewport ? 0 : 16)
    }

    private var content: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text((filePath as NSString).lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            MediaPlayerView(
                url: URL(filePath: filePath, directoryHint: .notDirectory),
                revision: revision,
                onLoadFailure: onLoadFailure
            )
            .frame(height: Self.controlBarHeight)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
    }
}
