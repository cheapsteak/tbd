import AppKit
import SwiftUI

/// SwiftUI rendering of an attached image, for the hosted-per-row transcript
/// path. Deliberately the same geometry, the same off-main decode, the same
/// caches, the same click and menu actions and the same fallbacks as the native
/// `TranscriptImageBlockView` — this repo's standing trap is the two renderers
/// drifting apart.
///
/// The frame is fixed from the synchronous header probe BEFORE the decode
/// starts, so the row does not resize when the thumbnail lands.
struct TranscriptImageAttachmentView: View {
    let attachment: TranscriptImageAttachment

    @State private var image: NSImage?
    @State private var hovering = false

    /// Bumped on every load. An in-flight decode captures the value it was
    /// dispatched with and drops its result if this view was pointed at a
    /// different attachment meanwhile — the same staleness guard
    /// `TranscriptImageBlockView.generation` enforces on the native path.
    @State private var generation = 0

    /// Probed once per view identity. Cheap (header read, then cached by the
    /// service), and it is what makes the frame deterministic.
    private var metadata: TranscriptImageMetadata {
        TranscriptImageService.shared.metadata(forPath: attachment.path)
    }

    private var displaySize: CGSize {
        TranscriptImageGeometry.displaySize(
            metadata: metadata, bodyWidth: TranscriptImageGeometry.maxEdge)
    }

    /// A file that is there: clickable to preview, and worth a context menu.
    private var isPreviewable: Bool { metadata.state != .missing }
    /// Only a decodable image can meaningfully be copied as an image.
    private var isCopyable: Bool { metadata.pixelSize != nil }

    var body: some View {
        Group {
            if isPreviewable {
                // A Button rather than `.onTapGesture`: on macOS a tap gesture
                // swallows the right-click that `.contextMenu` needs.
                Button { TranscriptImageActions.preview(path: attachment.path) } label: {
                    sized
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Quick Look") { TranscriptImageActions.preview(path: attachment.path) }
                    if isCopyable {
                        Button("Copy Image") { TranscriptImageActions.copyImage(path: attachment.path) }
                    }
                    Button("Reveal in Finder") {
                        TranscriptImageActions.revealInFinder(path: attachment.path)
                    }
                }
            } else {
                sized
            }
        }
        .onHover { inside in
            hovering = inside
            guard isPreviewable else { return }
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(attachment.displayPath)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(
            TranscriptImageBlockView.accessibilityLabel(
                attachment: attachment, metadata: metadata))
        .accessibilityHint(isPreviewable ? "Quick Look preview" : "")
        .onAppear(perform: load)
        // This view renders inside `TableTranscriptView`'s shared `NSHostingView`
        // pool, where a recycled cell has its `rootView` REPLACED rather than being
        // torn down. Today `MarkdownSegments.Segment.id` keys image segments by
        // path, so SwiftUI rebuilds this view with fresh `@State` and the thumbnail
        // cannot survive onto another message — but that is the CALL SITE's
        // property, not this view's, and `load` alone would never notice: it bails
        // once `image` is non-nil and `onAppear` does not fire a second time. Own
        // the invariant here, where the failure (the wrong picture, silently) would
        // land.
        .onChange(of: attachment) { _, _ in
            image = nil
            hovering = false
            load()
        }
    }

    private var sized: some View {
        content
            .frame(width: displaySize.width, height: displaySize.height, alignment: .leading)
            .contentShape(Rectangle())
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
        generation &+= 1
        let captured = generation
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let maxPixel = Int((max(displaySize.width, displaySize.height) * scale).rounded(.up))
        TranscriptImageService.shared.thumbnail(
            forPath: attachment.path, maxPixelSize: maxPixel
        ) { decoded in
            // A decode dispatched for the PREVIOUS attachment must not paint over
            // the current one when it lands late.
            guard captured == generation else { return }
            image = decoded
        }
    }
}
