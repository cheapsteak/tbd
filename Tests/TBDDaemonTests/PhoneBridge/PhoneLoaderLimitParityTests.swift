import Foundation
import Testing

@testable import TBDDaemonLib

/// The loader's constants file, `phone/loader/constants.js`. This file sits in
/// Tests/TBDDaemonTests/PhoneBridge, four levels below the repo root, as
/// `PhoneTestVectors` does.
private let loaderConstantsURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("phone/loader/constants.js")

/// The value of the line `export const <name> = <expression>;` in `source`,
/// when the expression is integer literals multiplied together, such as
/// `4 * 1024 * 1024` or `45_000`. Nil for a missing line or any other form,
/// so a constant rewritten in a new shape fails the test rather than reading
/// as some other number.
private func integerConstant(_ name: String, in source: String) -> Int? {
    let prefix = "export const \(name) = "
    guard let line = source.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return nil }
    let statement = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    guard statement.hasSuffix(";") else { return nil }
    var product = 1
    for factor in statement.dropLast().split(separator: "*") {
        let digits = factor.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits) else {
            return nil
        }
        product *= value
    }
    return product
}

/// The daemon must refuse to serve a bundle the phone's loader would refuse,
/// so its limits are the loader's (`PhoneAppBundle`). Tier 1: it reads one
/// committed file.
@Suite("Phone app bundle: loader limit parity")
struct PhoneLoaderLimitParityTests {
    @Test func theBundleLimitsAreTheLoaders() throws {
        let source = try String(contentsOf: loaderConstantsURL, encoding: .utf8)
        let compressed = try #require(integerConstant("MAX_BUNDLE_COMPRESSED", in: source))
        let text = try #require(integerConstant("MAX_BUNDLE_TEXT", in: source))
        let chunk = try #require(integerConstant("MAX_CHUNK_BYTES", in: source))
        #expect(compressed == PhoneBridgeConstants.maxBundleCompressedBytes)
        #expect(text == PhoneBridgeConstants.maxBundleTextBytes)
        #expect(chunk == PhoneBridgeConstants.bundleChunkRawBytes)
    }

    @Test func theReaderTakesOnlyAProductOfIntegers() {
        let source = """
            export const A = 4 * 1024 * 1024;
            export const B = 45_000;
            export const C = SIGNAL_TIMEOUT_MS + 1;
            """
        #expect(integerConstant("A", in: source) == 4 * 1024 * 1024)
        #expect(integerConstant("B", in: source) == 45_000)
        #expect(integerConstant("C", in: source) == nil)
        #expect(integerConstant("D", in: source) == nil)
    }
}
