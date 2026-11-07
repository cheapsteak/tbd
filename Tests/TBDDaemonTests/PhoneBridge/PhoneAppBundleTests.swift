import CryptoKit
import Foundation
import Testing

@testable import TBDDaemonLib

/// Lowercase hex SHA-256, computed here rather than through the code under
/// test.
private func hexSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// `count` bytes from the system's random generator, which DEFLATE cannot
/// shrink, so the compressed stream is about as long as the input.
private func randomBytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
}

/// Whether `bytes` starts with a zlib (RFC 1950) header: a CMF byte whose
/// method nibble is 8 (DEFLATE), and a CMF-FLG pair that is a multiple of 31.
private func startsWithZlibHeader(_ bytes: Data) -> Bool {
    guard bytes.count >= 2 else { return false }
    let cmf = bytes[bytes.startIndex]
    let flg = bytes[bytes.startIndex + 1]
    return cmf & 0x0F == 8 && (Int(cmf) << 8 | Int(flg)) % 31 == 0
}

@Suite("PhoneAppBundle")
struct PhoneAppBundleTests {
    @Test func theShippedPlaceholderLoads() throws {
        let bundle = try PhoneAppBundle.loadShipped()
        #expect(bundle.sha256Hex == hexSHA256(bundle.source))
        #expect(String(decoding: bundle.source, as: UTF8.self).contains("TBD phone app placeholder"))
        #expect(!bundle.chunks.isEmpty)
        #expect(try (bundle.compressed as NSData).decompressed(using: .zlib) as Data == bundle.source)
    }

    @Test func theHashIsLowercaseHexOfTheUncompressedBytes() throws {
        let bundle = try PhoneAppBundle(source: Data("abc".utf8))
        #expect(bundle.sha256Hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func chunksAreBoundedAndReassemble() throws {
        let source = randomBytes(200_000)
        let bundle = try PhoneAppBundle(source: source)
        #expect(bundle.chunks.allSatisfy { $0.count <= 45_000 })
        #expect(bundle.chunks.count == (bundle.compressed.count + 44_999) / 45_000)
        // Random bytes do not compress, so the stream needs several chunks.
        #expect(bundle.chunks.count >= 5)
        #expect(bundle.chunks.reduce(Data(), +) == bundle.compressed)
        #expect(try (bundle.compressed as NSData).decompressed(using: .zlib) as Data == source)
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
