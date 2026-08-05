import AppKit
import SwiftUI

/// SwiftUI rendering of an attached image, for the hosted-per-row transcript
/// path. Deliberately the same geometry, the same off-main decode, the same
/// caches and the same fallbacks as the native `TranscriptImageBlockView` — this
/// repo's standing trap is the two renderers drifting apart.
///
/// The frame is fixed from the synchronous header probe BEFORE the decode
/// starts, so the row does not resize when the thumbnail lands.
struct TranscriptImageAttachmentView: View {
    let attachment: TranscriptImageAttachment

    @State private var image: NSImage?
    @State private var hovering = false

    /// Probed once per view identity. Cheap (header read, then cached by the
    /// service), and it is what makes the frame deterministic.
    private var metadata: TranscriptImageMetadata {
        TranscriptImageService.shared.metadata(forPath: attachment.path)
    }

    private var displaySize: CGSize {
        TranscriptImageGeometry.displaySize(
            metadata: metadata, bodyWidth: TranscriptImageGeometry.maxWidth)
    }

    private var isRevealable: Bool { metadata.state != .missing }

    var body: some View {
        content
            .frame(width: displaySize.width, height: displaySize.height, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { reveal() }
            .onHover { inside in
                hovering = inside
                guard isRevealable else { return }
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(attachment.displayPath)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(
                TranscriptImageBlockView.accessibilityLabel(
                    attachment: attachment, metadata: metadata))
            .accessibilityHint(isRevealable ? "Reveal in Finder" : "")
            .onAppear(perform: load)
    }

    @ViewBuilder
    private var content: some View {
        switch metadata.state {
        case .ready:
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(hovering ? 0.85 : 1)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
            }
        case .missing:
            chip(symbol: "photo.badge.exclamationmark", text: "\(attachment.fileName) — unavailable")
        case .unreadable:
            chip(symbol: "doc", text: attachment.fileName)
        }
    }

    private func chip(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() {
        guard case .ready = metadata.state, image == nil else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let maxPixel = Int((max(displaySize.width, displaySize.height) * scale).rounded(.up))
        TranscriptImageService.shared.thumbnail(
            forPath: attachment.path, maxPixelSize: maxPixel
        ) { decoded in
            image = decoded
        }
    }

    private func reveal() {
        guard isRevealable else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: attachment.path)])
    }
}
