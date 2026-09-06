import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns whatever arrived — clipboard TIFF, clipboard PNG, a dropped file — into
/// one PNG the composer can write and Claude Code can read.
///
/// **The original bytes are never passed through unexamined.** Everything is
/// decoded and re-encoded, which is what lets the composer promise that the file
/// it wrote is an image and that its `.png` extension tells the truth — and
/// Claude Code's paste handler keys its image detection on that extension.
///
/// Downscaling uses ImageIO's thumbnail path with
/// `kCGImageSourceCreateThumbnailFromImageAlways`. The **if-absent** variant can
/// return a stale embedded EXIF thumbnail, which is a different picture from the
/// one the person pasted; always-from-image costs a decode and cannot.
enum ComposerImagePreparer {
    enum PrepareError: Error, Equatable, LocalizedError {
        /// ImageIO could not read it. Refused with a message rather than written
        /// as an unopenable file.
        case undecodable
        /// Still over Claude Code's cap after the smallest re-encode this will
        /// attempt. The payload is the BASE64 size, the number the cap is
        /// measured against.
        case tooLargeAfterReencoding(bytes: Int)

        /// The message a person sees. It names the numbers, because "too large"
        /// on its own tells them nothing about what to do next.
        var errorDescription: String? {
            switch self {
            case .undecodable:
                return "That is not an image TBD can read."
            case .tooLargeAfterReencoding(let bytes):
                return """
                    Still \(bytes) bytes once base64-encoded at \
                    \(ComposerImagePreparer.smallestEdge) px on its long edge, \
                    over the \(ComposerImagePreparer.maxBase64Bytes)-byte limit.
                    """
            }
        }
    }

    /// The longest edge any prepared image may have. A screenshot is legible far
    /// below its native resolution, and the cap is what keeps a Retina capture
    /// from spending the whole message budget on pixels nobody reads.
    static let maxLongEdge = 2000

    /// Claude Code's 5 MiB cap, measured against the BASE64 form — the encoding
    /// the image travels in, which is four bytes out for every three in.
    static let maxBase64Bytes = 5 * 1024 * 1024

    /// The floor the re-encode loop will not go below: past this an image is too
    /// small to read anything off, so failing with a number beats silently
    /// handing over a thumbnail.
    private static let smallestEdge = 640

    /// Successively smaller long edges to try when the first result is too big.
    /// Descending, so the loop keeps the largest size that fits.
    private static let fallbackEdges = [1600, 1200, 900, smallestEdge]

    static func preparePNG(from data: Data) throws -> Data {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { throw PrepareError.undecodable }

        for edge in [maxLongEdge] + fallbackEdges {
            guard let png = encodePNG(source: source, maxPixelSize: edge) else { continue }
            if base64Size(of: png) <= maxBase64Bytes { return png }
        }
        // One last attempt at the smallest size, so the error can name a real
        // number rather than a guess.
        guard let smallest = encodePNG(source: source, maxPixelSize: smallestEdge)
        else { throw PrepareError.undecodable }
        throw PrepareError.tooLargeAfterReencoding(bytes: base64Size(of: smallest))
    }

    /// Base64 is four output bytes for every three input bytes, rounded up to a
    /// whole quantum. The cap is measured against this, not against the raw
    /// count, because the expansion is what the message actually carries.
    private static func base64Size(of data: Data) -> Int { (data.count + 2) / 3 * 4 }

    /// One decode-and-encode at a given cap. `kCGImageSourceCreateThumbnailFromImageAlways`
    /// forces a real decode; `kCGImageSourceCreateThumbnailWithTransform` applies
    /// the EXIF orientation to the pixels, so nothing downstream has to re-read a
    /// tag that the PNG will not carry anyway.
    private static func encodePNG(source: CGImageSource, maxPixelSize: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Read image bytes off the pasteboard **without** adding image types to the
    /// text view's readable types.
    ///
    /// That distinction is the whole reason this exists: letting `NSTextView`'s
    /// default pipeline see an image would make it insert an inline attachment
    /// into the storage, which reopens every rich-text hazard the plain-text
    /// composer closes. It is the same shape the terminal view's paste override
    /// already uses (`TBDTerminalView.paste(_:)`).
    @MainActor
    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return data }
        }
        // A copied file, e.g. from Finder.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first {
            return imageData(fromFileAt: first)
        }
        return nil
    }

    static func imageData(fromFileAt url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}
