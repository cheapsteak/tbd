import AppKit
import SwiftUI

/// Thumbnails of every staged image, above the text field, hidden when there are
/// none.
///
/// **A view of the map; the text decides what is sent.** An image whose token is
/// gone from the text shows as detached — greyed and marked "not in message" —
/// so nothing is dropped silently. Clicking a detached thumbnail re-inserts its
/// token at the caret; clicking an attached one moves the caret to its token. The
/// x removes both the token and the image from the send.
struct AttachmentStrip: View {
    let draft: ComposerDraft
    let onReinsert: (Int) -> Void
    /// An attached thumbnail was clicked: move the caret to its token. There is
    /// deliberately no second gesture — no Finder reveal — because there is no
    /// second affordance on a thumbnail to carry one.
    let onFocusToken: (Int) -> Void
    let onRemove: (Int) -> Void
    let hoveredNumber: Int?
    let onHover: (Int?) -> Void

    private var ordered: [ComposerDraft.Attachment] {
        draft.attachments.values.sorted { $0.number < $1.number }
    }

    var body: some View {
        if !ordered.isEmpty {
            // Scanned ONCE per render and handed down. `detachedNumbers` runs a
            // regex over the whole message, and reading it inside the row builder
            // ran that scan once per thumbnail — on every keystroke, because the
            // text it scans is what changed.
            let detached = Set(draft.detachedNumbers)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ordered) { attachment in
                        thumbnail(attachment, detached: detached.contains(attachment.number))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(
        _ attachment: ComposerDraft.Attachment, detached: Bool
    ) -> some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                AttachmentThumbnailImage(path: attachment.path)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(detached ? 0.45 : 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                hoveredNumber == attachment.number
                                    ? Color.accentColor : Color.secondary.opacity(0.25),
                                lineWidth: hoveredNumber == attachment.number ? 2 : 1))
                Button {
                    onRemove(attachment.number)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(2)
                .accessibilityLabel("Remove image \(attachment.number)")
            }
            Text(detached ? "not in message" : "#\(attachment.number)")
                .font(.system(size: 9))
                .foregroundStyle(detached ? Color.orange : Color.secondary)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                onHover(attachment.number)
            } else if hoveredNumber == attachment.number {
                onHover(nil)
            }
        }
        .onTapGesture {
            if detached {
                onReinsert(attachment.number)
            } else {
                onFocusToken(attachment.number)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            detached
                ? "Image \(attachment.number), not in message. Click to re-insert."
                : "Image \(attachment.number), in message. Click to go to it.")
    }
}

/// One thumbnail, decoded off the main thread through the same ImageIO service
/// the transcript uses — never `NSImage(contentsOfFile:)`, which decodes the
/// whole file on whatever thread asks.
private struct AttachmentThumbnailImage: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
            }
        }
        .task(id: path) {
            await withCheckedContinuation { continuation in
                TranscriptImageService.shared.thumbnail(
                    forPath: path, maxPixelSize: 112
                ) { loaded in
                    image = loaded
                    continuation.resume()
                }
            }
        }
    }
}
