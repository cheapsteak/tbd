import SwiftUI

/// The slim header pinned over the top of a remote transcript's table that
/// says where its earlier history stands
/// (docs/specs/2026-09-25-remote-session-transcript-design.md, "Loading
/// earlier history").
///
/// It is an overlay, not a table row, so showing or hiding it never shifts the
/// rows and the table's row model is unchanged. `Content.resolve` decides what
/// it shows; the pane mounts it only when that is not `.hidden`.
struct RemoteTranscriptEarlierHeader: View {
    let content: Content
    let onRetry: @MainActor () -> Void

    enum Content: Equatable {
        case hidden
        case spinner
        case retryButton(String)
        case text(String)

        static let retryTitle = "Load earlier messages"
        static let startText = "Start of conversation"
        static let expiredText = "Earlier history is no longer available"

        /// What the header shows:
        ///
        /// - a spinner while a call is in flight, and the retry button after a
        ///   failure, wherever the table is scrolled;
        /// - "Start of conversation" or the expired notice only while the table
        ///   is near its top, where the reader is looking for more;
        /// - nothing while idle.
        ///
        /// Without `hasEarlier`, only the two end-of-history notices can show.
        /// With `remote_transcript_live_sync_enabled` off the daemon never
        /// reports `hasEarlier` and no load reaches either notice, so the
        /// header never appears and the pane looks as it did without the flag.
        static func resolve(
            state: RemoteTranscriptEarlierState, hasEarlier: Bool, nearTop: Bool
        ) -> Content {
            switch state {
            case .idle:
                return .hidden
            case .loading:
                return hasEarlier ? .spinner : .hidden
            case .failed:
                return hasEarlier ? .retryButton(retryTitle) : .hidden
            case .reachedStart:
                return nearTop ? .text(startText) : .hidden
            case .expired:
                return nearTop ? .text(expiredText) : .hidden
            }
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            switch content {
            case .hidden:
                EmptyView()
            case .spinner:
                ProgressView().controlSize(.small)
                Text("Loading earlier messages…")
            case .retryButton(let title):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button(title, action: onRetry)
                    .buttonStyle(.link)
            case .text(let text):
                Text(text)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 6)
    }
}
