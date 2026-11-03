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
    /// The video's own width, which is the pane's, so a stacked video can
    /// take a 16:9 frame as wide as the pane.
    @State private var videoWidth: CGFloat = 0

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

    /// One modifier chain whose arguments follow `fillsViewport`, never an
    /// `if`/`else` over it. A branch would move `MediaPlayerView` to another
    /// place in the view tree whenever the selection goes between one file and
    /// several, and SwiftUI would dismantle it, stopping and resetting
    /// playback.
    ///
    /// In a stack the height is the measured width times 9/16. A conditional
    /// `aspectRatio` cannot stand in for it: given no ratio, it takes the
    /// ratio of the player's ideal size, and an `AVPlayerView` has none. Alone
    /// in the pane, `containerRelativeFrame` gives it the scroll view's visible
    /// height; in a stack its axis set is empty, which sizes neither axis, so
    /// the frame takes its content's size and changes nothing.
    private var video: some View {
        MediaPlayerView(
            url: URL(filePath: filePath, directoryHint: .notDirectory),
            revision: revision,
            onLoadFailure: loadFailed
        )
        .frame(maxWidth: .infinity)
        .frame(height: fillsViewport ? nil : videoWidth * 9 / 16)
        .containerRelativeFrame(fillsViewport ? .vertical : [])
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            videoWidth = width
        }
    }

    /// Marks this render's load failed. Built per render, so it names the load
    /// it was handed to rather than whichever load is current when it runs.
    private var loadFailed: @MainActor () -> Void {
        let key = loadKey
        return { failedKey = key }
    }
}
