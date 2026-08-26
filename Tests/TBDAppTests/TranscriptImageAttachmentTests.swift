import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Covers the inline rendering of Claude Code's `[Image: source: …]` attachment
/// markers: how they are parsed out of transcript text, how the row is sized
/// before the thumbnail exists, and how a missing / undecodable / hostile path
/// degrades.
///
/// Every fixture is written into a per-test temp directory — no test reads the
/// developer's real Claude image cache.
/// `.serialized` because the tests share one process-wide `TranscriptImageService`
/// and several of them call `clearCaches()`: run in parallel, one test's reset
/// evicts another's just-decoded thumbnail and the cache assertions flake.
@MainActor
@Suite("Transcript image attachments", .serialized)
struct TranscriptImageAttachmentTests {

    // MARK: - Fixtures

    /// A scratch directory that cleans itself up.
    final class Scratch {
        let url: URL
        init() {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-image-tests-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    }

    /// Writes a real PNG of the given pixel dimensions and returns its path.
    private func writePNG(
        _ scratch: Scratch, name: String, width: Int, height: Int,
        color: NSColor = .systemTeal
    ) throws -> String {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let unwrapped = try #require(rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: unwrapped)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(unwrapped.representation(using: .png, properties: [:]))
        let path = scratch.path(name)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func marker(_ path: String) -> String { "[Image: source: \(path)]" }

    // MARK: - Marker parsing

    /// The overwhelmingly common shape: an `isMeta` follow-up line whose entire
    /// text is one marker. It becomes one image segment and NO text — the path
    /// must not survive as prose anywhere.
    @Test func soleMarkerBecomesOneImageSegmentAndNoText() {
        let segments = TranscriptImageMarker.split(marker("/tmp/a/1.png"))
        #expect(segments == [.image(TranscriptImageAttachment(path: "/tmp/a/1.png"))])
    }

    /// Several images in one paste arrive as several text blocks, which the
    /// daemon joins with newlines. Order is preserved.
    @Test func multipleMarkersProduceOrderedImageSegments() {
        let text = [marker("/tmp/a/2.png"), marker("/tmp/a/3.png")].joined(separator: "\n")
        let segments = TranscriptImageMarker.split(text)
        #expect(segments == [
            .image(TranscriptImageAttachment(path: "/tmp/a/2.png")),
            .image(TranscriptImageAttachment(path: "/tmp/a/3.png"))
        ])
    }

    /// A marker inside a sentence splits the prose around it and keeps both
    /// halves. (Observed in the corpus when a prompt quotes the marker syntax.)
    @Test func midSentenceMarkerKeepsSurroundingProse() {
        let segments = TranscriptImageMarker.split("before \(marker("/tmp/a/1.png")) after")
        #expect(segments == [
            .text("before"),
            .image(TranscriptImageAttachment(path: "/tmp/a/1.png")),
            .text("after")
        ])
    }

    /// The inline `[Image #N]` placeholder is the user's own text, marking where
    /// they pasted; it lives in a DIFFERENT message from the `source:` marker and
    /// is deliberately left untouched.
    @Test func inlinePlaceholderIsNotTreatedAsAMarker() {
        let segments = TranscriptImageMarker.split("looks good [Image #1] fix the badge")
        #expect(segments == [.text("looks good [Image #1] fix the badge")])
    }

    /// A marker inside a fenced code block is quoted source, not an attachment.
    @Test func markerInsideCodeFenceStaysLiteralText() {
        let text = "docs:\n```\n\(marker("/tmp/a/1.png"))\n```\ndone"
        let segments = TranscriptImageMarker.split(text)
        #expect(segments.count == 1)
        guard case .text(let body) = segments[0] else {
            Issue.record("expected a single text segment, got \(segments)")
            return
        }
        #expect(body.contains("[Image: source: /tmp/a/1.png]"))
    }

    /// A payload that is not an absolute path is nothing we could reveal, so the
    /// marker stays as written rather than becoming an empty hole.
    @Test func relativePathStaysLiteralText() {
        let segments = TranscriptImageMarker.split("[Image: source: relative/1.png]")
        #expect(segments == [.text("[Image: source: relative/1.png]")])
    }

    /// Text with no marker at all takes the fast path and is returned verbatim,
    /// whitespace included — ordinary messages must not be reshaped.
    @Test func textWithoutMarkersIsReturnedVerbatim() {
        let text = "\n  hello **world**  \n\n"
        #expect(TranscriptImageMarker.split(text) == [.text(text)])
    }

    // MARK: - Both renderers see the same blocks

    @Test func renderBlocksEmitsImageBlocksBetweenProse() {
        let blocks = MarkdownAttributedRenderer.renderBlocks(
            "before \(marker("/tmp/a/1.png")) after", linkResolver: nil)
        #expect(blocks.count == 3)
        guard case .prose(let lead) = blocks[0],
              case .image(let attachment) = blocks[1],
              case .prose(let trail) = blocks[2] else {
            Issue.record("expected prose/image/prose, got \(blocks)")
            return
        }
        #expect(lead.string.contains("before"))
        #expect(attachment.path == "/tmp/a/1.png")
        #expect(trail.string.contains("after"))
        // The path must not leak into the rendered prose on either side.
        #expect(!lead.string.contains("/tmp/a/1.png"))
        #expect(!trail.string.contains("/tmp/a/1.png"))
    }

    /// The SwiftUI path splits identically — the standing two-renderer trap.
    @Test func swiftUISegmentsMatchTheNativeBlocks() {
        let text = "before \(marker("/tmp/a/1.png")) after"
        let segments = MarkdownSegments.split(text)
        #expect(segments == [
            .prose("before"),
            .image(TranscriptImageAttachment(path: "/tmp/a/1.png")),
            .prose("after")
        ])
    }

    // MARK: - Sizing

    /// The thumbnail is CONTAINED in a `maxEdge` square: a wide image binds on
    /// width, a tall one on height, and neither exceeds the box on either axis.
    @Test func imagesAreContainedInTheSquareOnTheirLongEdge() throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let wide = try writePNG(scratch, name: "wide.png", width: 1200, height: 800)
        let tall = try writePNG(scratch, name: "tall.png", width: 400, height: 1600)
        let bodyWidth: CGFloat = 702

        let wideSize = TranscriptImageGeometry.displaySize(
            metadata: TranscriptImageService.shared.metadata(forPath: wide), bodyWidth: bodyWidth)
        let tallSize = TranscriptImageGeometry.displaySize(
            metadata: TranscriptImageService.shared.metadata(forPath: tall), bodyWidth: bodyWidth)

        // 1200×800 binds on WIDTH now (3:2 → 200×133), 400×1600 on height.
        #expect(wideSize == CGSize(width: 200, height: 133))
        #expect(tallSize == CGSize(width: 50, height: 200))
        for size in [wideSize, tallSize] {
            #expect(size.width <= TranscriptImageGeometry.maxEdge)
            #expect(size.height <= TranscriptImageGeometry.maxEdge)
        }
    }

    /// A square image fills the box exactly — the case that would expose a cap
    /// applied to only one axis.
    @Test func squareImageFillsTheBoxOnBothAxes() throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let square = try writePNG(scratch, name: "square.png", width: 900, height: 900)
        let size = TranscriptImageGeometry.displaySize(
            metadata: TranscriptImageService.shared.metadata(forPath: square), bodyWidth: 702)
        #expect(size == CGSize(
            width: TranscriptImageGeometry.maxEdge, height: TranscriptImageGeometry.maxEdge))
    }

    /// A thumbnail is never blown up past its natural pixel size.
    @Test func smallImageIsNotUpscaled() throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let icon = try writePNG(scratch, name: "icon.png", width: 32, height: 24)
        let size = TranscriptImageGeometry.displaySize(
            metadata: TranscriptImageService.shared.metadata(forPath: icon), bodyWidth: 702)
        #expect(size == CGSize(width: 32, height: 24))
    }

    /// A narrow bubble clamps the thumbnail to the body width, not the 200pt box.
    @Test func narrowBodyWidthClampsTheThumbnail() throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let wide = try writePNG(scratch, name: "wide.png", width: 1200, height: 800)
        let size = TranscriptImageGeometry.displaySize(
            metadata: TranscriptImageService.shared.metadata(forPath: wide), bodyWidth: 120)
        #expect(size.width == 120)
        #expect(size.height == 80)
    }

    // MARK: - Failure paths

    @Test func missingFileDegradesToAFixedChipAndNeverPrintsThePath() throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let path = scratch.path("gone.png")
        let metadata = TranscriptImageService.shared.metadata(forPath: path)
        #expect(metadata.state == .missing)

        let size = TranscriptImageGeometry.displaySize(metadata: metadata, bodyWidth: 702)
        #expect(size.height == TranscriptImageGeometry.fallbackHeight)

        let view = TranscriptImageBlockView()
        view.configure(attachment: .init(path: path), metadata: metadata, displaySize: size)
        let chip = try #require(view.fallbackChipText)
        #expect(chip.contains("gone.png"))
        #expect(!chip.contains(path), "the raw path must never be drawn")
        #expect(view.renderedImage == nil)
        // Still legible to VoiceOver.
        #expect(view.accessibilityLabel()?.contains("gone.png") == true)
        // …and the tooltip is the one place the path stays reachable.
        #expect(view.toolTip == (path as NSString).abbreviatingWithTildeInPath)
    }

    @Test func zeroByteFileIsUnreadableNotMissing() throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let path = scratch.path("empty.png")
        try Data().write(to: URL(fileURLWithPath: path))
        #expect(TranscriptImageService.shared.metadata(forPath: path).state == .unreadable)
    }

    /// A marker naming something that is not an image at all — including a file
    /// that merely LOOKS like one by extension.
    @Test func nonImageFileRendersAChipAndStaysClickable() throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let path = scratch.path("notreally.png")
        try Data("this is plain text, not a PNG".utf8).write(to: URL(fileURLWithPath: path))

        let metadata = TranscriptImageService.shared.metadata(forPath: path)
        #expect(metadata.state == .unreadable)
        #expect(metadata.pixelSize == nil)

        let view = TranscriptImageBlockView()
        view.configure(
            attachment: .init(path: path), metadata: metadata,
            displaySize: TranscriptImageGeometry.displaySize(metadata: metadata, bodyWidth: 702))
        #expect(view.fallbackChipText == "notreally.png")
        #expect(view.accessibilityLabel()?.contains("not a viewable image") == true)
    }

    /// A directory (or anything that is not a regular file) must probe as missing
    /// rather than being opened — the guard that also keeps a marker naming a
    /// device node from blocking the reader forever.
    @Test func nonRegularFileProbesAsMissing() {
        TranscriptImageService.shared.clearCaches()
        let scratch = Scratch()
        #expect(TranscriptImageService.shared.metadata(forPath: scratch.url.path).state == .missing)
        #expect(TranscriptImageService.shared.metadata(forPath: "").state == .missing)
    }

    /// Carries a probe's result back from a worker thread. A class so the escaping
    /// closure can write it; the semaphore in the test is the ordering.
    private final class ProbeResult: @unchecked Sendable {
        var state: TranscriptImageMetadata.State?
    }

    /// The hazard `fileStamp`'s `.typeRegular` check is named for, exercised with a
    /// real one: `open(2)` on a fifo with no writer never returns, so a probe that
    /// opened the file would wedge the measurement thread forever. A directory —
    /// what `nonRegularFileProbesAsMissing` covers — degrades for a different
    /// reason (it opens fine and simply has no image header) and cannot catch this.
    ///
    /// The probe therefore runs OFF the main thread behind a deadline, so a
    /// regression fails this test instead of hanging the suite; if it does block,
    /// the test opens the write end to release the stuck opener before finishing.
    @Test func fifoProbesAsMissingWithoutBlockingTheReader() throws {
        TranscriptImageService.shared.clearCaches()
        let scratch = Scratch()
        let path = scratch.path("pipe.png")
        try #require(mkfifo(path, 0o600) == 0,
                     Comment(rawValue: "mkfifo failed: \(String(cString: strerror(errno)))"))
        defer { unlink(path) }

        let result = ProbeResult()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result.state = TranscriptImageService.shared.metadata(forPath: path).state
            finished.signal()
        }
        let blocked = finished.wait(timeout: .now() + 5) == .timedOut
        if blocked {
            // Release the stuck `open(2)` so the worker thread is not leaked in a
            // permanently blocking syscall, then report.
            let writeEnd = open(path, O_WRONLY | O_NONBLOCK)
            if writeEnd >= 0 { close(writeEnd) }
            _ = finished.wait(timeout: .now() + 2)
        }
        #expect(!blocked, "the probe blocked opening a fifo — the .typeRegular guard is gone")
        #expect(result.state == .missing)
    }

    // MARK: - Click and context menu

    /// Counts how many times a click asked for the Quick Look panel. A class so
    /// the stub presenter can mutate it after escaping.
    private final class PanelShows { var count = 0 }

    /// Runs `body` with the Quick Look panel presentation stubbed out — a real
    /// panel would pop over the screen of whoever is running the suite, and needs
    /// a key window this process does not have.
    private func withStubbedPanel(_ body: (PanelShows) throws -> Void) rethrows {
        let shows = PanelShows()
        let previous = TranscriptQuickLook.shared.showPanel
        TranscriptQuickLook.shared.showPanel = { shows.count += 1 }
        defer { TranscriptQuickLook.shared.showPanel = previous }
        try body(shows)
    }

    private func configuredView(path: String) -> TranscriptImageBlockView {
        let metadata = TranscriptImageService.shared.metadata(forPath: path)
        let view = TranscriptImageBlockView()
        view.configure(
            attachment: .init(path: path), metadata: metadata,
            displaySize: TranscriptImageGeometry.displaySize(metadata: metadata, bodyWidth: 702))
        return view
    }

    /// A click previews THAT file — the whole point of the gesture change. The
    /// panel itself cannot be driven headlessly, so what is asserted is the
    /// wiring: the presenter is asked exactly once, for exactly this URL.
    @Test func clickingAThumbnailPreviewsThatExactFile() throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let path = try writePNG(scratch, name: "shot.png", width: 800, height: 600)
        let view = configuredView(path: path)

        try withStubbedPanel { shows in
            #expect(view.accessibilityPerformPress())
            #expect(shows.count == 1)
            #expect(TranscriptQuickLook.shared.previewURL?.path == path)
        }
        #expect(view.accessibilityHelp() == "Quick Look preview")
    }

    /// Reveal in Finder did not disappear when click stopped doing it — it moved
    /// to the right-click menu, alongside Copy Image.
    @Test func contextMenuKeepsRevealInFinderAndCopyReachable() throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let path = try writePNG(scratch, name: "shot.png", width: 800, height: 600)
        let menu = try #require(configuredView(path: path).makeContextMenu())
        #expect(menu.items.map(\.title) == ["Quick Look", "Copy Image", "Reveal in Finder"])
    }

    /// An `.unreadable` file stays clickable — Quick Look previews a PDF or a
    /// text file perfectly well — but there is no image to copy.
    @Test func unreadableFileStaysPreviewableWithoutCopyImage() throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let path = scratch.path("notreally.png")
        try Data("this is plain text, not a PNG".utf8).write(to: URL(fileURLWithPath: path))
        let view = configuredView(path: path)

        let menu = try #require(view.makeContextMenu())
        #expect(menu.items.map(\.title) == ["Quick Look", "Reveal in Finder"])

        try withStubbedPanel { shows in
            #expect(view.accessibilityPerformPress())
            #expect(shows.count == 1)
            #expect(TranscriptQuickLook.shared.previewURL?.path == path)
        }
    }

    /// A `.missing` file is inert: no click, no menu. There is nothing on disk to
    /// preview or reveal.
    @Test func missingFileIsNotClickableAndHasNoMenu() throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let view = configuredView(path: scratch.path("gone.png"))

        #expect(view.makeContextMenu() == nil)
        try withStubbedPanel { shows in
            #expect(view.accessibilityPerformPress() == false)
            #expect(shows.count == 0)
        }
    }

    // MARK: - Decode and cache

    @Test func thumbnailDecodesOffMainAndIsThenServedFromCache() async throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let path = try writePNG(scratch, name: "big.png", width: 2400, height: 1600)
        let maxPixel = 600

        #expect(!TranscriptImageService.shared.hasCachedThumbnail(
            forPath: path, maxPixelSize: maxPixel))

        let image: NSImage? = await withCheckedContinuation { continuation in
            TranscriptImageService.shared.thumbnail(forPath: path, maxPixelSize: maxPixel) {
                continuation.resume(returning: $0)
            }
        }
        let decoded = try #require(image)
        // Downsampled, never decoded at full size.
        #expect(max(decoded.size.width, decoded.size.height) <= CGFloat(maxPixel))
        #expect(TranscriptImageService.shared.hasCachedThumbnail(
            forPath: path, maxPixelSize: maxPixel))

        // A cache hit calls back SYNCHRONOUSLY, so a scroll-reused row repaints
        // without a blank frame and without re-decoding.
        var synchronous = false
        var second: NSImage?
        TranscriptImageService.shared.thumbnail(forPath: path, maxPixelSize: maxPixel) {
            synchronous = true
            second = $0
        }
        #expect(synchronous, "a cached thumbnail must not round-trip through a queue")
        #expect(second === decoded)
    }

    /// An animated GIF renders its FIRST frame as a still.
    @Test func animatedGIFRendersAStill() async throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let png = try writePNG(scratch, name: "frame.png", width: 60, height: 40)
        let source = try #require(NSImage(contentsOfFile: png))
        // Two identical frames is enough to make it animated.
        let gifPath = scratch.path("anim.gif")
        let destination = try #require(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: gifPath) as CFURL, "com.compuserve.gif" as CFString, 2, nil))
        var rect = CGRect(x: 0, y: 0, width: 60, height: 40)
        let cg = try #require(source.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]]
        CGImageDestinationAddImage(destination, cg, frameProps as CFDictionary)
        CGImageDestinationAddImage(destination, cg, frameProps as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        #expect(TranscriptImageService.shared.metadata(forPath: gifPath).state == .ready(CGSize(width: 60, height: 40)))
        let image: NSImage? = await withCheckedContinuation { continuation in
            TranscriptImageService.shared.thumbnail(forPath: gifPath, maxPixelSize: 120) {
                continuation.resume(returning: $0)
            }
        }
        let decoded = try #require(image)
        // One still frame, not an animated representation.
        #expect(decoded.representations.count == 1)
    }

    // MARK: - Measurement is stable across the async decode

    /// The whole point of probing the header synchronously: the row height the
    /// table reserves BEFORE the thumbnail exists must equal the height after it
    /// lands, or the transcript would jump while scrolling.
    @Test func rowHeightIsIdenticalBeforeAndAfterTheImageArrives() async throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let path = try writePNG(scratch, name: "shot.png", width: 1600, height: 900)
        let item = TranscriptItem.userPrompt(id: "u1", text: marker(path), timestamp: nil)
        let columnWidth: CGFloat = 800
        let bodyWidth = TranscriptBubbleGeometry.bodyWidth(columnWidth: columnWidth, role: .user)

        let blocks = TranscriptBubbleGeometry.composedBlocks(
            for: item, badgeUsage: nil, linkResolver: nil)
        #expect(blocks.count == 1)
        guard case .image = blocks[0] else {
            Issue.record("expected a single image block, got \(blocks)")
            return
        }

        let before = MessageBlockMeasurer().blockHeights(blocks, bodyWidth: bodyWidth)
        let heightBefore = TranscriptBubbleGeometry.rowHeight(
            blocksHeight: MessageBlockMeasurer().blocksHeight(fromBlockHeights: before),
            role: .user)
        #expect(!TranscriptImageService.shared.hasCachedThumbnail(forPath: path, maxPixelSize: 400))

        _ = await withCheckedContinuation { continuation in
            TranscriptImageService.shared.thumbnail(forPath: path, maxPixelSize: 400) {
                continuation.resume(returning: $0)
            }
        }

        let after = MessageBlockMeasurer().blockHeights(blocks, bodyWidth: bodyWidth)
        let heightAfter = TranscriptBubbleGeometry.rowHeight(
            blocksHeight: MessageBlockMeasurer().blocksHeight(fromBlockHeights: after),
            role: .user)
        #expect(before == after)
        #expect(heightBefore == heightAfter)
    }

    /// …and the live cell realizes at exactly that reserved height, the row-height
    /// oracle this transcript is held to everywhere else.
    @Test func cellRealizesAtTheReservedRowHeight() throws {
        let scratch = Scratch()
        TranscriptImageService.shared.clearCaches()
        let path = try writePNG(scratch, name: "shot.png", width: 1600, height: 900)
        let item = TranscriptItem.userPrompt(id: "u1", text: marker(path), timestamp: nil)
        let columnWidth: CGFloat = 800
        let bodyWidth = TranscriptBubbleGeometry.bodyWidth(columnWidth: columnWidth, role: .user)

        let blocks = TranscriptBubbleGeometry.composedBlocks(
            for: item, badgeUsage: nil, linkResolver: nil)
        let heights = MessageBlockMeasurer().blockHeights(blocks, bodyWidth: bodyWidth)
        let rowHeight = TranscriptBubbleGeometry.rowHeight(
            blocksHeight: MessageBlockMeasurer().blocksHeight(fromBlockHeights: heights),
            role: .user)

        let cell = TranscriptBubbleCellView()
        cell.configure(
            blocks: blocks, blockHeights: heights, sourceText: marker(path),
            role: .user, peerHeader: nil, accessibilityAttribution: "You",
            bodyWidth: bodyWidth, columnWidth: columnWidth, cachedHeight: rowHeight,
            onLinkClicked: nil)
        cell.layoutSubtreeIfNeeded()
        #expect(abs(cell.realizedRowHeight - rowHeight) <= 1.0,
                "realized=\(cell.realizedRowHeight) reserved=\(rowHeight)")

        // The bubble draws the picture, not the path.
        let drawn = Self.drawnStrings(in: cell)
        #expect(!drawn.contains { $0.contains(path) }, "the raw path must never be drawn, got \(drawn)")
    }

    // MARK: - Hosted (SwiftUI) reuse staleness

    /// The SwiftUI image view renders inside `TableTranscriptView`'s shared
    /// `NSHostingView` pool (reachable via `AskUserQuestionCard`'s embedded
    /// `ChatBubbleView`), where a recycled cell has its `rootView` REPLACED rather
    /// than being torn down. Its thumbnail lives in `@State` and `load()` bails
    /// once that is non-nil, so a cell recycled onto a different message must be
    /// made to fetch the NEW attachment — otherwise it keeps drawing the previous
    /// message's picture.
    ///
    /// What is observable headlessly is the FETCH, not the pixels: SwiftUI content
    /// is not captured by `cacheDisplay` or `CALayer.render` in this unbundled test
    /// process, so the drawn image cannot be read back. The fetch is a sound proxy:
    /// a view draws only what it fetched, so a request for the second attachment is
    /// what proves the recycled cell is not still showing the first one's picture.
    ///
    /// Both fixtures are the same pixel size, so `maxPixelSize` is identical for
    /// both and a request cannot be confused for the wrong file.
    ///
    /// This covers the COMPOSITE — call site plus view. Which of the two mechanisms
    /// delivered the re-fetch is deliberately not pinned here, and today it is the
    /// call site's path-keyed segment identity rather than the view's `.onChange`.
    /// `attachmentChangeRefetchesWhenTheViewIdentityIsStable` below is the one that
    /// pins the view's own guard; keep both, since either mechanism regressing
    /// alone leaves a real hazard the other happens to be covering.
    ///
    /// It watches `onThumbnailRequest` rather than `hasCachedThumbnail`, and that
    /// is what makes it deterministic. The cache is the wrong instrument twice
    /// over: the entry appears only after an asynchronous decode whose scheduling
    /// latency is unbounded (this file's own fifo probe parks a global-queue
    /// thread for up to 5 s; daemon suites park more), and `thumbnailCache` is an
    /// `NSCache` with `countLimit` 64, so once landed the entry can be evicted by
    /// any concurrent suite that decodes images of its own. The request is
    /// synchronous with `load()`, so waiting on it measures the view's behavior
    /// instead of the machine's weather.
    @Test func recycledHostingViewFetchesTheNewAttachmentsThumbnail() async throws {
        let scratch = Scratch()
        // The fixtures must outlive every wait below: `Scratch.deinit` deletes
        // the directory, and `load()` never requests a thumbnail for a file whose
        // header probe comes back `.missing`.
        defer { withExtendedLifetime(scratch) {} }
        TranscriptImageService.shared.clearCaches()
        let first = try writePNG(scratch, name: "first.png", width: 160, height: 160, color: .red)
        let second = try writePNG(scratch, name: "second.png", width: 160, height: 160, color: .blue)
        let maxPixel = Self.hostedMaxPixelSize(forPath: first)

        let requests = ThumbnailRequestLog()
        TranscriptImageService.shared.onThumbnailRequest = { requests.record(path: $0, maxPixelSize: $1) }
        defer { TranscriptImageService.shared.onThumbnailRequest = nil }

        let host = NSHostingView(rootView: AnyView(Self.bubble(marker: marker(first))))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host

        try await awaitRequest(
            for: first, maxPixelSize: maxPixel, in: requests, drivingLayoutOf: host,
            what: "precondition: the hosted view must fetch its own attachment at all")
        #expect(!requests.contains(path: second, maxPixelSize: maxPixel),
                "precondition: nothing has asked for the second attachment yet")

        // Recycle the cell onto a different message carrying a different image.
        host.rootView = AnyView(Self.bubble(marker: marker(second)))
        try await awaitRequest(
            for: second, maxPixelSize: maxPixel, in: requests, drivingLayoutOf: host,
            what: "the recycled hosting view never fetched the new attachment, so it is still "
                + "drawing the previous message's thumbnail")
    }

    /// The view's OWN staleness guard, isolated from the call site that currently
    /// masks it.
    ///
    /// `recycledHostingViewFetchesTheNewAttachmentsThumbnail` above goes through
    /// `ChatBubbleView`, whose `ForEach` keys image segments by path
    /// (`MarkdownSegments.Segment.id` → `"i:<path>"`). Swapping the marker
    /// therefore changes the segment's identity, SwiftUI discards the old
    /// `TranscriptImageAttachmentView` along with its `@State`, and the fresh one
    /// fetches on `onAppear` — with or without `.onChange(of: attachment)`. That
    /// makes the composite test a real regression test for the composite (the
    /// picture is never stale end to end) but blind to the view's own guard:
    /// deleting `.onChange` leaves it passing.
    ///
    /// This test removes the mask. The host's root view is one concrete type with
    /// no `ForEach` and no `.id`, so replacing `rootView` is an in-place UPDATE:
    /// structural identity is stable, `@State image` survives, and `onAppear` does
    /// not fire a second time. `.onChange` is then the only thing that can make the
    /// view re-fetch — which is exactly the invariant its comment claims to own,
    /// and what would keep the previous message's picture on screen if the call
    /// site ever stopped keying identity by path.
    ///
    /// The first thumbnail is decoded UP FRONT so the cache serves the hosted
    /// view's request synchronously (the documented cache-hit contract, pinned by
    /// `thumbnailDecodesOffMainAndIsThenServedFromCache`). That makes `image`
    /// non-nil at the swap without polling for a decode, so the test exercises the
    /// stale-picture case rather than the never-loaded one. If a concurrent suite
    /// evicts that entry first the test still holds — it just proves the weaker
    /// arm — so eviction can never redden it.
    @Test func attachmentChangeRefetchesWhenTheViewIdentityIsStable() async throws {
        let scratch = Scratch()
        defer { withExtendedLifetime(scratch) {} }
        TranscriptImageService.shared.clearCaches()
        let first = try writePNG(scratch, name: "first.png", width: 160, height: 160, color: .red)
        let second = try writePNG(scratch, name: "second.png", width: 160, height: 160, color: .blue)
        let maxPixel = Self.hostedMaxPixelSize(forPath: first)

        // Warm `first` before the hook is installed, so the pre-warm decode is not
        // itself recorded as one of the view's requests.
        _ = await withCheckedContinuation { continuation in
            TranscriptImageService.shared.thumbnail(forPath: first, maxPixelSize: maxPixel) {
                continuation.resume(returning: $0)
            }
        }

        let requests = ThumbnailRequestLog()
        TranscriptImageService.shared.onThumbnailRequest = { requests.record(path: $0, maxPixelSize: $1) }
        defer { TranscriptImageService.shared.onThumbnailRequest = nil }

        let host = NSHostingView(rootView: StableIdentityAttachmentHost(path: first))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host

        try await awaitRequest(
            for: first, maxPixelSize: maxPixel, in: requests, drivingLayoutOf: host,
            what: "precondition: the hosted view must fetch its own attachment at all")
        #expect(!requests.contains(path: second, maxPixelSize: maxPixel),
                "precondition: nothing has asked for the second attachment yet")

        // Point the SAME view at a different attachment. No identity change, so
        // `onAppear` cannot save it — only `.onChange(of: attachment)` can.
        host.rootView = StableIdentityAttachmentHost(path: second)
        try await awaitRequest(
            for: second, maxPixelSize: maxPixel, in: requests, drivingLayoutOf: host,
            what: "the view did not re-fetch when its attachment changed under a stable "
                + "identity, so it is still drawing the previous attachment's thumbnail")
    }

    /// One attachment view under a stable structural identity — no `ForEach`, no
    /// `.id`, one concrete root type — so `NSHostingView.rootView =` updates it in
    /// place instead of rebuilding it.
    private struct StableIdentityAttachmentHost: View {
        let path: String
        var body: some View {
            TranscriptImageAttachmentView(attachment: TranscriptImageAttachment(path: path))
        }
    }

    /// The harness's own guard, pinned because its failure mode is invisible in
    /// the suite it protects: a swallowed cancellation makes every subsequent
    /// `Task.sleep` return instantly, so `awaitRequest` busy-spins
    /// `layoutSubtreeIfNeeded` plus a cache scan ON THE MAIN ACTOR for the whole
    /// 30 s budget, starving every other main-isolated test in the process —
    /// and then blames production ("the view never re-fetched") for a harness
    /// event. Deterministic: the wait observes the cancellation on its first
    /// iteration, so this costs milliseconds.
    @Test func awaitRequestEndsOnCancellationInsteadOfSpinning() async throws {
        let requests = ThumbnailRequestLog()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let started = ContinuousClock.now

        let waiter = Task { [self] in
            try await awaitRequest(
                for: "/nonexistent/never-requested.png", maxPixelSize: 64, in: requests,
                drivingLayoutOf: view, what: "cancellation probe", within: .seconds(30))
        }
        waiter.cancel()

        var thrown: (any Error)?
        do { try await waiter.value } catch { thrown = error }
        let elapsed = ContinuousClock.now - started

        #expect(thrown is ThumbnailWaitCancelled,
                "cancellation must end the wait as itself, not as a never-observed request: \(String(describing: thrown))")
        #expect(elapsed < .seconds(5),
                "a cancelled wait must return at once, not spin out its budget (took \(elapsed))")
    }

    /// Ordered record of every `TranscriptImageService` thumbnail request, in the
    /// order the views made them.
    @MainActor
    private final class ThumbnailRequestLog {
        private(set) var requests: [(path: String, maxPixelSize: Int)] = []

        func record(path: String, maxPixelSize: Int) {
            requests.append((path: path, maxPixelSize: maxPixelSize))
        }

        func contains(path: String, maxPixelSize: Int) -> Bool {
            requests.contains { $0.path == path && $0.maxPixelSize == maxPixelSize }
        }

        /// Every request as `<file>@<maxPixelSize>` — file names only, so the
        /// diagnostic stays readable and never prints a temp path.
        var summary: String {
            requests.isEmpty
                ? "none"
                : requests.map { "\(($0.path as NSString).lastPathComponent)@\($0.maxPixelSize)" }
                    .joined(separator: ", ")
        }
    }

    /// A bounded wait that ran out with no matching request. Thrown rather than
    /// `#expect`-ed: only a thrown error puts the observed state on the PRIMARY
    /// failure line, which is the line CI summaries keep (`Tests/CLAUDE.md`,
    /// assertion-hygiene rule 4). The bare `#expect` this replaced reported
    /// `condition(value → false)` and could not distinguish "the view never
    /// re-fetched" from "the cache entry was evicted underneath us".
    private struct ThumbnailRequestNotObserved: Error, CustomStringConvertible {
        let what: String
        let expected: String
        let maxPixelSize: Int
        let observed: String
        let waited: Duration

        var description: String {
            "\(what) — no thumbnail request for \(expected) at maxPixelSize=\(maxPixelSize) "
                + "after polling for \(waited); observed requests: \(observed)"
        }
    }

    /// The surrounding task was cancelled while waiting — the suite time limit
    /// fired, or the run is tearing down. Named separately for the reason
    /// `ChildReaperTests.ZombieWaitOutcome.cancelled` is: a swallowed
    /// `CancellationError` makes every subsequent `Task.sleep` return instantly,
    /// so the loop burns its whole budget in microseconds and reports "the view
    /// never re-fetched" — production blamed for a harness event. Worse here
    /// than there, because this suite is `@MainActor`: the busy-spin runs
    /// `layoutSubtreeIfNeeded` plus a cache scan **on the main actor**, starving
    /// every other main-isolated test in the process until the deadline.
    private struct ThumbnailWaitCancelled: Error, CustomStringConvertible {
        let what: String
        let expected: String
        let observed: String
        let waited: Duration

        var description: String {
            "\(what) — waiting for a thumbnail request for \(expected) was CANCELLED after "
                + "\(waited); observed requests: \(observed). This says nothing about whether "
                + "the view re-fetched."
        }
    }

    /// Drives `view`'s layout and yields the main actor until the service has been
    /// asked for `path` at `maxPixelSize`, or the deadline passes.
    ///
    /// It YIELDS rather than spinning a nested `RunLoop.run`: SwiftUI delivers
    /// `onAppear` / `onChange` through the main queue, and suspending is what lets
    /// that queue run. A nested run loop could not — this body is itself a block on
    /// that serial queue, so the delivery would sit there until the body ended and
    /// then land inside some other test.
    ///
    /// The budget is generous because it bounds a hang, not a measurement: what is
    /// being waited on is a main-queue delivery, not a decode, so a healthy run
    /// satisfies it in milliseconds and a saturated one still has room.
    ///
    /// **Cancellation ends the wait; it is never swallowed** — see
    /// `ThumbnailWaitCancelled`. And the diagnostics report ELAPSED time, not the
    /// budget: on the cancelled path those differ by three orders of magnitude,
    /// and "after polling for 30 seconds" would be a fabrication.
    private func awaitRequest(
        for path: String, maxPixelSize: Int, in log: ThumbnailRequestLog,
        drivingLayoutOf view: NSView, what: String,
        within budget: Duration = .seconds(30)
    ) async throws {
        let started = ContinuousClock.now
        let deadline = started + budget
        var elapsed: Duration { ContinuousClock.now - started }
        func cancelled() -> ThumbnailWaitCancelled {
            ThumbnailWaitCancelled(
                what: what, expected: (path as NSString).lastPathComponent,
                observed: log.summary, waited: elapsed)
        }
        while true {
            view.layoutSubtreeIfNeeded()
            if log.contains(path: path, maxPixelSize: maxPixelSize) { return }
            if Task.isCancelled { throw cancelled() }
            guard ContinuousClock.now < deadline else { break }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                throw cancelled()
            }
        }
        throw ThumbnailRequestNotObserved(
            what: what, expected: (path as NSString).lastPathComponent,
            maxPixelSize: maxPixelSize, observed: log.summary, waited: elapsed)
    }

    /// The hosted shape the reuse pool actually renders: a chat bubble whose text
    /// is one image marker.
    @MainActor
    private static func bubble(marker: String) -> some View {
        ChatBubbleView(item: .userPrompt(id: "u1", text: marker, timestamp: nil))
            .frame(width: 420, alignment: .leading)
    }

    /// The `maxPixelSize` `TranscriptImageAttachmentView.load` will ask for, derived
    /// the same way it derives it — so the test reads the same cache slot the view
    /// fills rather than a hardcoded one.
    private static func hostedMaxPixelSize(forPath path: String) -> Int {
        let display = TranscriptImageGeometry.displaySize(
            metadata: TranscriptImageService.shared.metadata(forPath: path),
            bodyWidth: TranscriptImageGeometry.maxEdge)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return Int((max(display.width, display.height) * scale).rounded(.up))
    }

    /// Every string actually drawn by `view`'s subtree.
    private static func drawnStrings(in view: NSView) -> [String] {
        var out: [String] = []
        if let field = view as? NSTextField, !field.isHidden, !field.stringValue.isEmpty {
            out.append(field.stringValue)
        }
        if let textView = view as? NSTextView, !textView.isHidden, !textView.string.isEmpty {
            out.append(textView.string)
        }
        for sub in view.subviews { out.append(contentsOf: drawnStrings(in: sub)) }
        return out
    }
}
