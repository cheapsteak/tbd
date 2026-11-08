import CryptoKit
import Foundation
import Testing
import TestSupport

@testable import TBDDaemonLib

/// Lowercase hex SHA-256, computed here rather than through the code under
/// test.
private func hexSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Whether `bytes` starts with a zlib (RFC 1950) header: a CMF byte whose
/// method nibble is 8 (DEFLATE), and a CMF-FLG pair that is a multiple of 31.
private func startsWithZlibHeader(_ bytes: Data) -> Bool {
    guard bytes.count >= 2 else { return false }
    let cmf = bytes[bytes.startIndex]
    let flg = bytes[bytes.startIndex + 1]
    return cmf & 0x0F == 8 && (Int(cmf) << 8 | Int(flg)) % 31 == 0
}

/// `count` random bytes, which DEFLATE cannot shrink, filled in one call so a
/// test of megabytes spends no time per byte.
private func incompressibleBytes(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
        if let base = buffer.baseAddress {
            arc4random_buf(base, buffer.count)
        }
    }
    return data
}

/// Builds a bundle on a thread the tests own: hashing and compressing
/// megabytes is synchronous work that must not hold a cooperative pool thread
/// (`Tests/CLAUDE.md`, "the cooperative pool").
private func bundleOffThePool(_ source: Data) async throws -> PhoneAppBundle {
    try await withTaskExecutorPreference(GateExecutor.shared) {
        try PhoneAppBundle(source: source)
    }
}

@Suite("PhoneAppBundle")
struct PhoneAppBundleTests {
    @Test func theShippedBundleLoads() throws {
        let bundle = try PhoneAppBundle.loadShipped()
        #expect(bundle.sha256Hex == hexSHA256(bundle.source))
        #expect(String(decoding: bundle.source, as: UTF8.self).hasPrefix("/* TBD phone app. Built by `npm run build:app`"))
        #expect(!bundle.chunks.isEmpty)
        #expect(try (bundle.compressed as NSData).decompressed(using: .zlib) as Data == bundle.source)
    }

    @Test func theHashIsLowercaseHexOfTheUncompressedBytes() throws {
        let bundle = try PhoneAppBundle(source: Data("abc".utf8))
        #expect(bundle.sha256Hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func chunksAreBoundedAndReassemble() throws {
        let source = PhoneTestVectors.randomBytes(200_000)
        let bundle = try PhoneAppBundle(source: source)
        #expect(bundle.chunks.allSatisfy { $0.count <= 45_000 })
        #expect(bundle.chunks.count == (bundle.compressed.count + 44_999) / 45_000)
        // Random bytes do not compress, so the stream needs several chunks.
        #expect(bundle.chunks.count >= 5)
        #expect(bundle.chunks.reduce(Data(), +) == bundle.compressed)
        #expect(try (bundle.compressed as NSData).decompressed(using: .zlib) as Data == source)
    }

    // MARK: The loader's size limits

    @Test func aBundleOverTheLoadersTextLimitIsRefused() {
        let limit = PhoneBridgeConstants.maxBundleTextBytes
        // Refused before it is hashed or compressed, so this costs nothing.
        let source = Data(repeating: 0x61, count: limit + 1)
        #expect(throws: PhoneAppBundleError.textTooLarge(bytes: limit + 1, limit: limit)) {
            try PhoneAppBundle(source: source)
        }
    }

    @Test func aBundleAtTheLoadersTextLimitIsAccepted() async throws {
        let limit = PhoneBridgeConstants.maxBundleTextBytes
        let bundle = try await bundleOffThePool(Data(repeating: 0x61, count: limit))
        #expect(bundle.source.count == limit)
        #expect(bundle.compressed.count <= PhoneBridgeConstants.maxBundleCompressedBytes)
    }

    @Test func aBundleOverTheLoadersCompressedLimitIsRefused() async throws {
        // Random bytes do not compress: DEFLATE stores them, block headers
        // and all, so the compressed form is a few hundred bytes over.
        let limit = PhoneBridgeConstants.maxBundleCompressedBytes
        let refusal = await #expect(throws: PhoneAppBundleError.self) {
            try await bundleOffThePool(incompressibleBytes(limit))
        }
        guard case .compressedTooLarge(let bytes, let refusedLimit)? = refusal else {
            Issue.record("expected compressedTooLarge, got \(String(describing: refusal))")
            return
        }
        #expect(refusedLimit == limit)
        #expect(bytes > limit)
    }

    @Test func theCompressedLimitAcceptsABundleExactlyAtIt() throws {
        let source = incompressibleBytes(64 * 1024)
        let compressedSize = try PhoneAppBundle(source: source).compressed.count
        let atLimit = try PhoneAppBundle(source: source, maxCompressedBytes: compressedSize)
        #expect(atLimit.compressed.count == compressedSize)
        #expect(throws: PhoneAppBundleError.compressedTooLarge(bytes: compressedSize, limit: compressedSize - 1)) {
            try PhoneAppBundle(source: source, maxCompressedBytes: compressedSize - 1)
        }
    }

    @Test func theTextLimitAcceptsABundleExactlyAtIt() throws {
        let source = Data("acme".utf8)
        let atLimit = try PhoneAppBundle(source: source, maxTextBytes: source.count)
        #expect(atLimit.source == source)
        #expect(throws: PhoneAppBundleError.textTooLarge(bytes: source.count, limit: source.count - 1)) {
            try PhoneAppBundle(source: source, maxTextBytes: source.count - 1)
        }
    }

    @Test func aRefusalSaysTheBundleCannotBeServed() {
        let text = PhoneAppBundleError.compressedTooLarge(bytes: 5_000_000, limit: 4_194_304).localizedDescription
        #expect(text == "The phone app bundle is 5000000 bytes compressed, more than the 4194304 a phone accepts, "
            + "so TBD cannot serve it.")
    }

    @Test func compressionIsRawDeflateWithNoZlibHeader() throws {
        let bundle = try PhoneAppBundle.loadShipped()
        #expect(bundle.compressed.count >= 2)
        #expect(!startsWithZlibHeader(bundle.compressed))
    }

    @Test func aMissingBundleNamesEverySearchedPath() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("phone-app-bundle-\(UUID().uuidString)")
        #expect(throws: PhoneAppBundleError.notFound(searched: [
            "\(tmp.path)/TBD_TBDDaemonLib.bundle/Resources/phone-app/app.js",
            "\(tmp.path)/TBD_TBDDaemonLib.bundle/Contents/Resources/Resources/phone-app/app.js",
        ])) {
            try PhoneAppBundle.locate(in: [tmp])
        }
    }

    @Test func eitherBundleLayoutIsFound() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("phone-app-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let nested = tmp.appendingPathComponent("TBD_TBDDaemonLib.bundle/Contents/Resources/Resources/phone-app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("app.js")
        try Data("x".utf8).write(to: file)
        #expect(try PhoneAppBundle.locate(in: [tmp]).path == file.path)
    }
}
