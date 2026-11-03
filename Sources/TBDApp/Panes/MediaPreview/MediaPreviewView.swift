import SwiftUI

/// An audio or video file in the file viewer, or the "Cannot preview" screen
/// once the player reports that the file does not load.
///
/// Audio shows as `AudioPreviewCard`. Video fills the pane's visible area when
/// it is the only file, and takes a 16:9 frame as wide as the pane in a
/// multi-file stack. The viewer stacks files in a `ScrollView`, which proposes
/// no height, so a single video sizes itself against the scroll view's visible
/// area with `containerRelativeFrame` rather than taking the pane over.
struct MediaPreviewView: View {
    let filePath: String
    let revision: Int
    let isVideo: Bool
    let fillsViewport: Bool

    /// The `path#revision` whose load failed. Keyed on the revision as well as
    /// the path, so a rewrite of the file tries the player again.
    @State private var failedKey: String?

    private var loadKey: String { "\(filePath)#\(revision)" }

    var body: some View {
        if failedKey == loadKey {
            BinaryFallbackView(filePath: filePath)
        } else if isVideo {
            video
        } else {
            AudioPreviewCard(
                filePath: filePath,
                revision: revision,
                fillsViewport: fillsViewport,
                onLoadFailure: loadFailed
            )
        }
    }

    @ViewBuilder
    private var video: some View {
        let player = MediaPlayerView(
            url: URL(fileURLWithPath: filePath),
            revision: revision,
            onLoadFailure: loadFailed
        )
        .frame(maxWidth: .infinity)
        if fillsViewport {
            player.containerRelativeFrame(.vertical)
        } else {
            player.aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
    }

    /// Marks this render's load failed. Built per render, so it names the load
    /// it was handed to rather than whichever load is current when it runs.
    private var loadFailed: @MainActor () -> Void {
        let key = loadKey
        return { failedKey = key }
    }
}
