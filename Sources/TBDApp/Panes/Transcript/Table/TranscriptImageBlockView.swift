import AppKit
import os

/// The native (NSTableView) rendering of an attached image: a leading-aligned
/// thumbnail that reveals the file in Finder when clicked.
///
/// The view is width-pinned to the bubble's full body width by the block stack
/// (like every other block), and draws its content at the leading edge in the
/// exact `displaySize` the measurer used — so the drawn height equals the row
/// height by construction, and the thumbnail arriving later never resizes
/// anything.
@MainActor
final class TranscriptImageBlockView: NSView {
    private let imageView = NSImageView()
    private let placeholder = NSView()
    private let chip = NSTextField(labelWithString: "")
    private let chipIcon = NSImageView()

    private var attachment: TranscriptImageAttachment?
    private var isRevealable = false

    /// Bumped on every `configure`. An in-flight decode captures the value it was
    /// dispatched with and drops its result if the cell was recycled onto another
    /// message meanwhile — the same staleness guard the async syntax highlighter
    /// uses. (#129)
    private var generation = 0

    private var contentWidth: NSLayoutConstraint!
    private var contentHeight: NSLayoutConstraint!
    private var chipWidth: NSLayoutConstraint!

    private static let log = Logger(subsystem: "com.tbd.app", category: "transcript-image")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.wantsLayer = true
        placeholder.layer?.cornerRadius = 6
        placeholder.layer?.cornerCurve = .continuous
        placeholder.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true

        chipIcon.translatesAutoresizingMaskIntoConstraints = false
        chipIcon.imageScaling = .scaleProportionallyDown
        chipIcon.contentTintColor = .secondaryLabelColor

        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.font = NSFont.systemFont(ofSize: 11)
        chip.textColor = .secondaryLabelColor
        chip.lineBreakMode = .byTruncatingMiddle
        chip.cell?.truncatesLastVisibleLine = true

        addSubview(placeholder)
        addSubview(imageView)
        addSubview(chipIcon)
        addSubview(chip)

        contentWidth = placeholder.widthAnchor.constraint(equalToConstant: 1)
        contentHeight = placeholder.heightAnchor.constraint(equalToConstant: 1)
        chipWidth = chip.widthAnchor.constraint(lessThanOrEqualToConstant: 1)

        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor),
            contentWidth,
            contentHeight,

            imageView.leadingAnchor.constraint(equalTo: placeholder.leadingAnchor),
            imageView.topAnchor.constraint(equalTo: placeholder.topAnchor),
            imageView.widthAnchor.constraint(equalTo: placeholder.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: placeholder.heightAnchor),

            chipIcon.leadingAnchor.constraint(equalTo: leadingAnchor),
            chipIcon.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor),
            chipIcon.widthAnchor.constraint(equalToConstant: 12),
            chipIcon.heightAnchor.constraint(equalToConstant: 12),

            chip.leadingAnchor.constraint(equalTo: chipIcon.trailingAnchor, constant: 4),
            chip.centerYAnchor.constraint(equalTo: chipIcon.centerYAnchor),
            chipWidth
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Renders `attachment` at exactly `displaySize` — the size
    /// `TranscriptImageGeometry` produced from the synchronous header probe, and
    /// the size the row was measured at.
    func configure(
        attachment: TranscriptImageAttachment,
        metadata: TranscriptImageMetadata,
        displaySize: CGSize
    ) {
        generation &+= 1
        let captured = generation
        self.attachment = attachment

        contentWidth.constant = max(displaySize.width, 1)
        contentHeight.constant = max(displaySize.height, 1)
        chipWidth.constant = max(displaySize.width - 16, 1)

        toolTip = attachment.displayPath
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.accessibilityLabel(attachment: attachment, metadata: metadata))

        switch metadata.state {
        case .ready:
            isRevealable = true
            setAccessibilityHelp("Reveal in Finder")
            chip.isHidden = true
            chipIcon.isHidden = true
            imageView.isHidden = false
            placeholder.isHidden = false
            imageView.image = nil
            // Ask for pixels, not points, so the thumbnail stays crisp on Retina
            // without the original ever being decoded at full size.
            let scale = window?.backingScaleFactor ?? 2
            let maxPixel = Int((max(displaySize.width, displaySize.height) * scale).rounded(.up))
            TranscriptImageService.shared.thumbnail(
                forPath: attachment.path, maxPixelSize: maxPixel
            ) { [weak self] image in
                guard let self, self.generation == captured else { return }
                guard let image else {
                    // The file decoded its header at measure time but not its
                    // pixels now (truncated, deleted mid-scroll). Fall back to the
                    // chip IN PLACE — the reserved height is unchanged.
                    self.showChip(missing: true)
                    return
                }
                self.imageView.image = image
                self.placeholder.isHidden = true
            }

        case .missing:
            isRevealable = false
            setAccessibilityHelp(nil)
            showChip(missing: true)

        case .unreadable:
            // The file is there but is not a decodable image. Revealing it is
            // still the useful gesture, so the chip stays clickable.
            isRevealable = true
            setAccessibilityHelp("Reveal in Finder")
            showChip(missing: false)
        }

        // A revealable/unrevealable switch changes whether we want the pointing
        // hand, and cursor rects are only rebuilt on request.
        window?.invalidateCursorRects(for: self)
    }

    private func showChip(missing: Bool) {
        imageView.isHidden = true
        placeholder.isHidden = true
        chip.isHidden = false
        chipIcon.isHidden = false
        let symbol = missing ? "photo.badge.exclamationmark" : "doc"
        chipIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let name = attachment?.fileName ?? "image"
        chip.stringValue = missing ? "\(name) — unavailable" : name
    }

    static func accessibilityLabel(
        attachment: TranscriptImageAttachment,
        metadata: TranscriptImageMetadata
    ) -> String {
        switch metadata.state {
        case .ready: return "Attached image, \(attachment.fileName)"
        case .missing: return "Attached image, \(attachment.fileName), unavailable"
        case .unreadable: return "Attached file, \(attachment.fileName), not a viewable image"
        }
    }

    // MARK: - Reveal affordance

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isRevealable else { return }
        addCursorRect(
            NSRect(origin: .zero, size: NSSize(
                width: contentWidth.constant, height: contentHeight.constant)),
            cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard isRevealable, let attachment else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let content = NSRect(
            origin: .zero,
            size: NSSize(width: contentWidth.constant, height: contentHeight.constant))
        guard content.contains(point) else {
            super.mouseDown(with: event)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: attachment.path)])
    }

    override func accessibilityPerformPress() -> Bool {
        guard isRevealable, let attachment else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: attachment.path)])
        return true
    }

    /// Test seam: the image currently drawn, if the async decode has landed.
    var renderedImage: NSImage? { imageView.isHidden ? nil : imageView.image }

    /// Test seam: the fallback chip's text, or nil when a thumbnail is showing.
    var fallbackChipText: String? { chip.isHidden ? nil : chip.stringValue }
}
