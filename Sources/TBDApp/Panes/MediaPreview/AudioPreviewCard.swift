import AVFoundation
import CoreMedia
import SwiftUI

/// An audio file in the file viewer: a compact card with a music symbol, the
/// file name, the duration and the system play bar.
///
/// The `AVPlayerView` is framed to the height of its inline control bar, so its
/// audio-only placeholder, a large QuickTime logo over an empty area, never
/// shows. The duration loads in a `.task`, never in `body`.
struct AudioPreviewCard: View {
    let filePath: String
    let revision: Int
    /// True when the card is the only file in the pane: it centres itself in
    /// the pane's visible area. False in a multi-file stack, where it takes
    /// its own height.
    let fillsViewport: Bool
    let onLoadFailure: @MainActor () -> Void

    /// The height the card frames its `AVPlayerView` at: the inline control
    /// bar alone.
    static let controlBarHeight: CGFloat = 44

    /// The duration text with the path it was loaded for, so a rewrite keeps
    /// the old text until the new one arrives while another file never shows
    /// this one's.
    @State private var loadedDuration: LoadedDuration?

    private struct LoadedDuration: Equatable {
        let path: String
        let text: String
    }

    var body: some View {
        if fillsViewport {
            card
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .containerRelativeFrame(.vertical)
        } else {
            card
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
    }

    private var card: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(URL(fileURLWithPath: filePath).lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(durationText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            MediaPlayerView(
                url: URL(fileURLWithPath: filePath),
                revision: revision,
                onLoadFailure: onLoadFailure
            )
            .frame(height: Self.controlBarHeight)
        }
        .padding(16)
        .frame(maxWidth: 420)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .task(id: "\(filePath)#\(revision)") {
            await loadDuration()
        }
    }

    /// A space until the duration is known, so the line keeps its height and
    /// the card does not jump when the text arrives.
    private var durationText: String {
        guard let loadedDuration, loadedDuration.path == filePath,
              !loadedDuration.text.isEmpty else { return " " }
        return loadedDuration.text
    }

    private func loadDuration() async {
        let path = filePath
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = try? await asset.load(.duration)
        guard !Task.isCancelled else { return }
        let text = duration.map { Self.formattedDuration(seconds: CMTimeGetSeconds($0)) } ?? ""
        loadedDuration = LoadedDuration(path: path, text: text)
    }

    /// `m:ss` below one hour and `h:mm:ss` from one hour, rounded to the
    /// nearest second. Empty for a value that is not a finite, non-negative
    /// number of seconds, such as an indefinite duration.
    nonisolated static func formattedDuration(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int32.max) else { return "" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = total / 60 % 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
