import AppKit
import ImageIO
import UniformTypeIdentifiers
import os

/// What we know about the file a `[Image: source: …]` marker names, WITHOUT
/// decoding it. Produced by a header-only probe cheap enough to run inside
/// synchronous row measurement.
struct TranscriptImageMetadata: Equatable {
    enum State: Equatable {
        /// A decodable image whose pixel dimensions are known.
        case ready(CGSize)
        /// No file at the path (or it is not a regular file). The image cache is
        /// disposable, so old transcripts hit this constantly.
        case missing
        /// The file exists but carries no image header: zero bytes, a truncated
        /// download, or a marker naming something that was never an image.
        case unreadable
    }

    let state: State

    var pixelSize: CGSize? {
        if case .ready(let size) = state { return size }
        return nil
    }
}

/// Loads attached-image thumbnails for the transcript: a synchronous header-only
/// metadata probe used by row measurement, and an asynchronous downsampling
/// decode used by the cells. Both are cached and bounded.
///
/// ## Why the decode is off-main
///
/// The transcript has a documented hard-freeze history from expensive work on the
/// main thread (issue #129 — syntax highlighting inside a JavaScriptCore VM, fixed
/// by moving it to `CodeHighlightService`'s background queue). Fully decoding a
/// user's 12-megapixel screenshot is the same class of hazard, so this service
/// never does it: `CGImageSourceCreateThumbnailAtIndex` with
/// `kCGImageSourceThumbnailMaxPixelSize` downsamples during decode, on a
/// background queue, and only the finished `NSImage` crosses back to main.
///
/// ## Why measurement can stay synchronous
///
/// `CGImageSourceCopyPropertiesAtIndex` reads the file's header — it does not
/// decode pixels — so the true aspect ratio is available BEFORE the thumbnail
/// exists. Row height is therefore exact from the first measurement and does not
/// change when the image arrives. Measured on a 4000×3000 PNG: the cold probe
/// runs in 0.12 ms median / 0.24 ms p95, against 26.4 ms to decode the same file
/// in full — cheap enough to sit inside synchronous row measurement, and the
/// cache below means a scrolled row pays it once.
///
/// `@unchecked Sendable` is justified by the state: `NSCache` is documented
/// thread-safe, every other stored property is a `let` of a Sendable type, and
/// the one `var` (`onThumbnailRequest`, a test seam) is `@MainActor`-isolated.
final class TranscriptImageService: @unchecked Sendable {
    static let shared = TranscriptImageService()

    private let queue = DispatchQueue(
        label: "com.tbd.transcript-image", qos: .userInitiated, attributes: .concurrent)
    private let log = Logger(subsystem: "com.tbd.app", category: "transcript-image")

    /// Header probes, keyed by path + mtime + byte size, so a rewritten file
    /// re-probes rather than serving a stale aspect ratio.
    private let metadataCache = NSCache<NSString, MetadataBox>()
    /// Decoded thumbnails, keyed by the metadata key plus the requested max pixel
    /// size. Bounded by count AND by approximate bitmap bytes so scrolling a long
    /// transcript full of screenshots cannot grow without limit.
    private let thumbnailCache = NSCache<NSString, NSImage>()

    private final class MetadataBox {
        let metadata: TranscriptImageMetadata
        init(_ metadata: TranscriptImageMetadata) { self.metadata = metadata }
    }

    private init() {
        metadataCache.countLimit = 512
        thumbnailCache.countLimit = 64
        thumbnailCache.totalCostLimit = 64 * 1024 * 1024
    }

    // MARK: - Synchronous metadata (measurement path)

    /// Header-only probe of `path`. Safe to call from row measurement: it stats
    /// the file, and on a cache miss reads only the image header.
    func metadata(forPath path: String) -> TranscriptImageMetadata {
        guard let stamp = Self.fileStamp(path) else { return TranscriptImageMetadata(state: .missing) }
        let key = Self.cacheKey(path: path, stamp: stamp) as NSString
        if let box = metadataCache.object(forKey: key) { return box.metadata }

        let metadata = Self.probe(path: path, stamp: stamp)
        metadataCache.setObject(MetadataBox(metadata), forKey: key)
        return metadata
    }

    // MARK: - Asynchronous thumbnail (render path)

    /// Delivers a downsampled thumbnail for `path` on the main thread, or `nil` if
    /// the file vanished or does not decode. A cache hit calls back synchronously,
    /// so a scroll-reused cell paints its image without a frame of blank.
    ///
    /// `maxPixelSize` is the longest edge in PIXELS — pass the display size scaled
    /// by the backing-scale factor so the thumbnail is crisp on Retina without
    /// decoding the original.
    @MainActor
    func thumbnail(
        forPath path: String,
        maxPixelSize: Int,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        onThumbnailRequest?(path, maxPixelSize)
        guard let stamp = Self.fileStamp(path) else {
            completion(nil)
            return
        }
        let key = "\(Self.cacheKey(path: path, stamp: stamp))|\(maxPixelSize)" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            completion(cached)
            return
        }

        queue.async { [self] in
            guard let image = Self.decodeThumbnail(path: path, maxPixelSize: maxPixelSize) else {
                log.debug("transcript-image decode failed path=\(path, privacy: .public)")
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil) } }
                return
            }
            let cost = Int(image.size.width * image.size.height * 4)
            thumbnailCache.setObject(image, forKey: key, cost: max(cost, 1))
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(image) } }
        }
    }

    /// Test seam: fired on every thumbnail REQUEST, with the requested path and
    /// `maxPixelSize`, BEFORE the cache is consulted — so it observes the fetch
    /// itself rather than the entry the fetch eventually lands in.
    ///
    /// That distinction is the point. A test that asserts through
    /// `hasCachedThumbnail` is asserting on `thumbnailCache`, which is an
    /// `NSCache` under a `countLimit` and an eviction policy of its own: the
    /// entry may not have landed yet (the decode is asynchronous and its
    /// scheduling latency is unbounded under load) and, once landed, may be
    /// evicted by any concurrently running suite that decodes 64 other images.
    /// The request is synchronous, ordered, and nobody else's to evict.
    ///
    /// `@MainActor`-isolated, like `thumbnail(forPath:maxPixelSize:completion:)`
    /// which fires it, so the seam needs no synchronization of its own and does
    /// not weaken the class's `@unchecked Sendable` justification. Production
    /// never sets it.
    @MainActor var onThumbnailRequest: ((String, Int) -> Void)?

    /// Test seam: drops every probe and thumbnail so a test can observe a cold
    /// path. Production never calls it — the caches are self-bounding.
    func clearCaches() {
        metadataCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
    }

    /// Test seam: true when a thumbnail for this exact (path, mtime, size,
    /// maxPixelSize) is already resident, i.e. the next request is served without
    /// a decode.
    func hasCachedThumbnail(forPath path: String, maxPixelSize: Int) -> Bool {
        guard let stamp = Self.fileStamp(path) else { return false }
        let key = "\(Self.cacheKey(path: path, stamp: stamp))|\(maxPixelSize)" as NSString
        return thumbnailCache.object(forKey: key) != nil
    }

    // MARK: - Primitives

    private struct FileStamp {
        let modified: TimeInterval
        let size: Int64
    }

    /// mtime + size of a REGULAR file at `path`, or nil. The regular-file check
    /// is not pedantry: a marker naming a fifo or a character device would hang
    /// the reader forever, and `/dev/random` would never end.
    private static func fileStamp(_ path: String) -> FileStamp? {
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return FileStamp(modified: modified, size: size)
    }

    private static func cacheKey(path: String, stamp: FileStamp) -> String {
        "\(path)|\(stamp.modified)|\(stamp.size)"
    }

    /// Header-only dimensions probe. Never decodes pixels.
    private static func probe(path: String, stamp: FileStamp) -> TranscriptImageMetadata {
        guard stamp.size > 0 else { return TranscriptImageMetadata(state: .unreadable) }
        let url = URL(fileURLWithPath: path)
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(
                source, 0, sourceOptions as CFDictionary) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            return TranscriptImageMetadata(state: .unreadable)
        }
        // EXIF orientations 5–8 transpose the image; the thumbnail is created with
        // `kCGImageSourceCreateThumbnailWithTransform`, so measurement must swap
        // the axes to match what will actually be drawn.
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let transposed = orientation >= 5 && orientation <= 8
        let size = transposed
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
        return TranscriptImageMetadata(state: .ready(size))
    }

    /// Downsampling decode. `kCGImageSourceThumbnailMaxPixelSize` bounds the
    /// decoded bitmap, so a 12-megapixel screenshot never enters memory at full
    /// size. Index 0 is the first frame, which is what makes an animated GIF
    /// render as a still.
    private static func decodeThumbnail(path: String, maxPixelSize: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// Deterministic on-screen size for an attached image, and the fallback chip's
/// size when there is nothing to draw.
///
/// The scheme CONTAINS the image inside a `maxEdge` × `maxEdge` square while
/// preserving its true aspect ratio, and NEVER upscales — the same fit a Finder
/// icon grid uses. One cap on both axes is what keeps a thumbnail recognisably a
/// thumbnail: a wide screenshot binds on width and comes out short, a tall
/// portrait binds on height and comes out narrow, and neither shape can dominate
/// the bubble. Because the aspect ratio comes from the synchronous header probe,
/// this size is known before the decode starts, so the row height measured at
/// open equals the row height after the image lands.
@MainActor
enum TranscriptImageGeometry {
    /// Longest the thumbnail may be on EITHER axis — the side of the square it
    /// is contained in.
    static let maxEdge: CGFloat = 200
    /// Height of the one-line chip shown for a missing or undecodable file.
    static let fallbackHeight: CGFloat = 20
    /// Width of that chip (clamped to the body width).
    static let fallbackWidth: CGFloat = 320

    /// Laid-out size of the attachment at `bodyWidth`. Deterministic and
    /// decode-independent: `metadata` comes from the header probe.
    static func displaySize(metadata: TranscriptImageMetadata, bodyWidth: CGFloat) -> CGSize {
        guard let pixelSize = metadata.pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: min(max(bodyWidth, 1), fallbackWidth), height: fallbackHeight)
        }
        // A bubble narrower than the box clamps the square further; nothing may
        // overflow the body.
        let availableWidth = min(max(bodyWidth, 1), maxEdge)
        let scale = min(availableWidth / pixelSize.width, maxEdge / pixelSize.height, 1)
        return CGSize(
            width: max((pixelSize.width * scale).rounded(.down), 1),
            height: max((pixelSize.height * scale).rounded(.down), 1)
        )
    }
}
