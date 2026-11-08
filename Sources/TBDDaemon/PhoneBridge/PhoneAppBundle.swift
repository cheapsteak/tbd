import CryptoKit
import Foundation

/// Why the phone app bundle cannot be served.
enum PhoneAppBundleError: Error, Equatable, LocalizedError {
    /// No `app.js` at any of these paths.
    case notFound(searched: [String])
    /// The Compression framework refused the bundle's bytes.
    case compressionFailed
    /// `app.js` is `bytes` long, over the `limit` a phone's loader inflates.
    case textTooLarge(bytes: Int, limit: Int)
    /// Compressed, the bundle is `bytes` long, over the `limit` a phone's
    /// loader accepts.
    case compressedTooLarge(bytes: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .notFound(let searched):
            return "TBD could not find the phone app bundle, so it cannot serve a phone. It looked in: "
                + searched.joined(separator: ", ") + "."
        case .compressionFailed:
            return "TBD could not compress the phone app bundle."
        case .textTooLarge(let bytes, let limit):
            return "The phone app bundle is \(bytes) bytes, more than the \(limit) a phone accepts, "
                + "so TBD cannot serve it."
        case .compressedTooLarge(let bytes, let limit):
            return "The phone app bundle is \(bytes) bytes compressed, more than the \(limit) a phone accepts, "
                + "so TBD cannot serve it."
        }
    }
}

/// The phone app bundle the laptop serves through the loader protocol: the
/// one `app.js` shipped in the daemon's resource bundle, hashed, compressed
/// and cut into chunks once, when it is loaded.
///
/// - `sha256Hex` is the hash of the uncompressed bytes. It names the bundle
///   in `welcome` and `bundle.get`.
/// - `compressed` is raw DEFLATE (RFC 1951), which the phone inflates with
///   the browser's `DecompressionStream("deflate-raw")`.
/// - `chunks` are `compressed` cut into pieces of at most
///   `PhoneBridgeConstants.bundleChunkRawBytes`, so each `bundle.chunk`,
///   base64 and envelope included, fits one transport message.
///
/// A bundle a phone's loader would refuse is never served: one over
/// `PhoneBridgeConstants.maxBundleTextBytes`, or over
/// `PhoneBridgeConstants.maxBundleCompressedBytes` once compressed, fails to
/// load, and the bridge shows why as its problem.
struct PhoneAppBundle: Sendable, Equatable {
    /// Where `.copy("Resources")` puts the bundle inside the daemon's
    /// resource bundle.
    static let subdirectory = "Resources/phone-app"
    static let fileName = "app.js"

    /// The `app.js` bytes.
    let source: Data
    /// Lowercase hex SHA-256 of `source`.
    let sha256Hex: String
    /// `source` as raw DEFLATE.
    let compressed: Data
    /// `compressed`, in order, in pieces of at most
    /// `PhoneBridgeConstants.bundleChunkRawBytes`. Joined, they are
    /// `compressed`.
    let chunks: [Data]

    /// Hashes, compresses and chunks `source`. Throws `.textTooLarge`, before
    /// any of that work, when `source` is over `maxTextBytes`, and
    /// `.compressedTooLarge` when its compressed form is over
    /// `maxCompressedBytes`. Tests pass smaller limits to reach the
    /// compressed one exactly.
    init(source: Data, maxTextBytes: Int = PhoneBridgeConstants.maxBundleTextBytes,
         maxCompressedBytes: Int = PhoneBridgeConstants.maxBundleCompressedBytes) throws {
        guard source.count <= maxTextBytes else {
            throw PhoneAppBundleError.textTooLarge(bytes: source.count, limit: maxTextBytes)
        }
        self.source = source
        self.sha256Hex = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        // `.zlib` is raw DEFLATE, not the zlib format: NSData.h documents
        // `NSDataCompressionAlgorithmZlib` as using "the raw DEFLATE format as
        // described in IETF RFC 1951", and compression.h describes
        // `COMPRESSION_ZLIB`'s encoder as zlib's
        // `deflateInit2(zstream, 5, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY)`,
        // where the negative window size means no zlib header or trailer.
        // So the stream is what `DecompressionStream("deflate-raw")` reads.
        let compressed: Data
        do {
            compressed = try (source as NSData).compressed(using: .zlib) as Data
        } catch {
            throw PhoneAppBundleError.compressionFailed
        }
        guard compressed.count <= maxCompressedBytes else {
            throw PhoneAppBundleError.compressedTooLarge(bytes: compressed.count, limit: maxCompressedBytes)
        }
        self.compressed = compressed
        let size = PhoneBridgeConstants.bundleChunkRawBytes
        self.chunks = stride(from: 0, to: compressed.count, by: size).map { start in
            compressed.subdata(in: start..<min(start + size, compressed.count))
        }
    }

    /// The shipped `app.js` in the first container whose
    /// `TBD_TBDDaemonLib.bundle` holds one, in either bundle layout SwiftPM
    /// emits. Searches the same places, in the same order, as the migration
    /// loader, for the same reason: `Bundle.module` would read the build
    /// tree's copy from a relocated binary.
    static func locate(in containers: [URL] = SQLMigrationLoader.candidateContainerURLs()) throws -> URL {
        var searched: [String] = []
        for container in containers {
            let bundle = container.appendingPathComponent(SQLMigrationLoader.resourceBundleName)
            for layout in SQLMigrationLoader.bundleResourceLayouts {
                let candidate = layout
                    .reduce(bundle) { $0.appendingPathComponent($1) }
                    .appendingPathComponent(subdirectory)
                    .appendingPathComponent(fileName)
                searched.append(candidate.path)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    return candidate
                }
            }
        }
        throw PhoneAppBundleError.notFound(searched: searched)
    }

    /// Locates, reads and prepares the shipped bundle.
    static func loadShipped() throws -> PhoneAppBundle {
        try PhoneAppBundle(source: Data(contentsOf: locate()))
    }
}
