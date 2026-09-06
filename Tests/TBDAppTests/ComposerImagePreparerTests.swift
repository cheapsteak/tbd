import AppKit
import Foundation
import ImageIO
import TestSupport
import Testing
import UniformTypeIdentifiers
@testable import TBDApp

/// Image preparation. Every accepted image is decoded, downscaled, and
/// re-encoded as PNG — the original bytes are never passed through unexamined,
/// which is what lets the composer promise the file it writes is an image and
/// what its extension says it is.
///
/// **Every fixture is built at an exact pixel size** with
/// `NSBitmapImageRep(bitmapDataPlanes:…)`, never with `NSImage.lockFocus()`.
/// `lockFocus` renders at the deepest attached screen's backing scale, so on a
/// Retina developer machine a "64×48" fixture is really 128×96 pixels and
/// `aSmallImageKeepsItsSize` fails there while passing on a CI runner with no
/// screen. The pixel dimensions are the subject of these tests, so they are
/// stated rather than inherited from the hardware.
@MainActor
@Suite("ComposerImagePreparer")
struct ComposerImagePreparerTests {

    /// A bitmap at an exact pixel size. `noisy` fills it with deterministic
    /// pseudo-random bytes, which is the only way to make a PNG big enough to
    /// exercise the size cap — a solid colour compresses to nothing at any
    /// resolution and would let the cap test pass without the cap existing.
    private func makeBitmap(width: Int, height: Int, noisy: Bool = false) throws
        -> NSBitmapImageRep
    {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 3,
            bitsPerPixel: 24))
        let bytes = try #require(rep.bitmapData)
        let count = rep.bytesPerRow * height
        if noisy {
            // A tiny xorshift, so the fixture is incompressible and identical
            // on every run.
            var state: UInt32 = 0x1234_5678
            for index in 0..<count {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                bytes[index] = UInt8(truncatingIfNeeded: state)
            }
        } else {
            memset(bytes, 0x40, count)
        }
        return rep
    }

    /// A solid-colour image at a chosen size, in a chosen format.
    private func makeImage(width: Int, height: Int, type: UTType, noisy: Bool = false)
        throws -> Data
    {
        let rep = try makeBitmap(width: width, height: height, noisy: noisy)
        // `UTType` is a struct, not an enum, so this is a lookup rather than a
        // switch that could be exhaustive.
        let format: NSBitmapImageRep.FileType = type == .tiff ? .tiff
            : (type == .png ? .png : .jpeg)
        return try #require(rep.representation(using: format, properties: [:]))
    }

    /// A JPEG that really carries an EXIF orientation tag, written through
    /// ImageIO because `NSBitmapImageRep` has no way to attach one.
    private func makeOrientedImage(width: Int, height: Int, orientation: Int) throws -> Data {
        let cgImage = try #require(try makeBitmap(width: width, height: height).cgImage)
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func dimensions(of data: Data) throws -> (width: Int, height: Int) {
        let props = try properties(of: data)
        return (
            try #require(props[kCGImagePropertyPixelWidth] as? Int),
            try #require(props[kCGImagePropertyPixelHeight] as? Int))
    }

    private func orientation(of data: Data) throws -> Int? {
        try properties(of: data)[kCGImagePropertyOrientation] as? Int
    }

    private func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    @Test func tiffInPngOut() throws {
        let out = try ComposerImagePreparer.preparePNG(
            from: try makeImage(width: 64, height: 48, type: .tiff))
        #expect(isPNG(out))
    }

    @Test func pngInPngOut() throws {
        let out = try ComposerImagePreparer.preparePNG(
            from: try makeImage(width: 64, height: 48, type: .png))
        #expect(isPNG(out))
    }

    /// A small image is not upscaled. Downscaling is a cap, not a target.
    @Test func aSmallImageKeepsItsSize() throws {
        let source = try makeImage(width: 64, height: 48, type: .png)
        // The fixture itself must be the size it claims, or this test would be
        // measuring the developer machine's backing scale.
        #expect(try dimensions(of: source) == (width: 64, height: 48))
        let out = try ComposerImagePreparer.preparePNG(from: source)
        let size = try dimensions(of: out)
        #expect(size.width == 64 && size.height == 48)
    }

    @Test func aLargeImageIsCappedOnItsLongEdge() throws {
        let out = try ComposerImagePreparer.preparePNG(
            from: try makeImage(width: 4000, height: 1000, type: .png))
        let size = try dimensions(of: out)
        #expect(size.width == ComposerImagePreparer.maxLongEdge)
        #expect(size.height == 500, "the aspect ratio must survive: got \(size)")
    }

    @Test func aTallImageIsCappedOnItsLongEdgeToo() throws {
        let out = try ComposerImagePreparer.preparePNG(
            from: try makeImage(width: 1000, height: 4000, type: .png))
        let size = try dimensions(of: out)
        #expect(size.height == ComposerImagePreparer.maxLongEdge)
    }

    /// **The result must fit Claude Code's cap after base64 expansion**, which is
    /// four bytes out for every three in. The fixture is noise, so the long-edge
    /// cap alone is not enough to get under it and the re-encode loop has to run.
    @Test func theResultFitsTheBase64Cap() throws {
        let out = try ComposerImagePreparer.preparePNG(
            from: try makeImage(width: 4000, height: 3000, type: .png, noisy: true))
        let base64Bytes = (out.count + 2) / 3 * 4
        #expect(base64Bytes <= ComposerImagePreparer.maxBase64Bytes,
                "\(out.count) raw bytes expand to \(base64Bytes) base64 bytes")
        // …and it really did have to shrink further than the long-edge cap,
        // which is what makes the assertion above discriminating.
        #expect(try dimensions(of: out).width < ComposerImagePreparer.maxLongEdge)
    }

    /// Undecodable input is refused with a message, never written and never sent.
    @Test func undecodableInputIsRefused() {
        #expect(throws: ComposerImagePreparer.PrepareError.undecodable) {
            try ComposerImagePreparer.preparePNG(from: Data("not an image".utf8))
        }
        #expect(throws: ComposerImagePreparer.PrepareError.undecodable) {
            try ComposerImagePreparer.preparePNG(from: Data())
        }
    }

    /// A file drop shares the same path — the bytes are read and then prepared,
    /// never linked to in place.
    @Test func aFileDropIsReadAndPrepared() throws {
        let root = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdimg"), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("drop.png")
        try makeImage(width: 32, height: 32, type: .png).write(to: url)

        let read = try #require(ComposerImagePreparer.imageData(fromFileAt: url))
        #expect(isPNG(try ComposerImagePreparer.preparePNG(from: read)))
    }

    /// Orientation is applied rather than carried: a rotated source must come out
    /// with its pixels already in reading order, because the token that follows
    /// it is a path and nothing downstream re-reads EXIF.
    ///
    /// The fixture carries a real EXIF orientation of 6 (rotate 90° clockwise for
    /// display), so its 200×100 stored pixels are a 100×200 picture. A preparer
    /// that ignored the tag would emit 200×100 and fail here — which an
    /// orientation-tag assertion on an untagged fixture could not do, since PNG
    /// carries no orientation and the check would read its own default back.
    @Test func orientationIsBakedIntoThePixels() throws {
        let data = try makeOrientedImage(width: 200, height: 100, orientation: 6)
        #expect(try orientation(of: data) == 6,
                "the fixture must really carry the tag, or this test proves nothing")

        let out = try ComposerImagePreparer.preparePNG(from: data)
        let size = try dimensions(of: out)
        #expect(size.width == 100 && size.height == 200,
                "the rotation must be in the pixels: got \(size)")
        #expect((try orientation(of: out) ?? 1) == 1,
                "the output must carry no residual orientation tag")
    }

    /// **A dropped file is validated before its bytes become an image.** The
    /// drop path reads whatever URL the pasteboard carried, so without a check
    /// a dragged source file or log would be handed to `onImageData` and only
    /// fail later, deep inside the preparer, as an opaque "not an image".
    @Test func aDroppedTextFileIsRefused() throws {
        let root = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdimg"), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.txt")
        try Data("not a picture, just prose".utf8).write(to: url)

        #expect(ComposerImagePreparer.imageData(fromFileAt: url) == nil)
    }

    /// The same check must not refuse the thing it exists to let through.
    @Test func aDroppedPNGFileIsRead() throws {
        let root = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdimg"), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("shot.png")
        let written = try makeImage(width: 24, height: 24, type: .png)
        try written.write(to: url)

        #expect(ComposerImagePreparer.imageData(fromFileAt: url) == written)
    }

    /// A misnamed image is still an image: the type check falls back to
    /// sniffing the bytes, so a screenshot saved without an extension works.
    @Test func aPNGWithAMisleadingExtensionIsStillRead() throws {
        let root = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdimg"), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("screenshot.txt")
        try makeImage(width: 24, height: 24, type: .png).write(to: url)

        #expect(ComposerImagePreparer.imageData(fromFileAt: url) != nil)
    }
}
