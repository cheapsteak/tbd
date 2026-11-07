import Foundation
import Testing

@testable import TBDDaemonLib

/// The `base64url` section of `phone/test-vectors/pairing-link.json`.
struct Base64URLFile: Decodable {
    let base64url: Base64URLVectors
}

struct Base64URLVectors: Decodable {
    struct Case: Decodable {
        let text: String
        let hex: String
    }

    let valid: [Case]
    let invalid: [String]
}

@Suite("Phone channel: base64url")
struct Base64URLTests {
    @Test func sharedVectors() throws {
        let file = try PhoneTestVectors.load("pairing-link.json", as: Base64URLFile.self)
        #expect(file.base64url.valid.count == 5)
        for c in file.base64url.valid {
            #expect(Base64URL.encode(PhoneTestVectors.bytes(c.hex)) == c.text, "\(c.text)")
            #expect(Base64URL.decode(c.text) == PhoneTestVectors.bytes(c.hex), "\(c.text)")
        }
        #expect(file.base64url.invalid.count == 7)
        for text in file.base64url.invalid {
            #expect(Base64URL.decode(text) == nil, "\(text)")
        }
    }

    @Test func rejectsSpareBitsThatFoundationAccepts() {
        // Why the strict check exists: Foundation's decoder may accept
        // non-zero spare bits, and reads the same byte as "AA==" when it does.
        if let lenient = Data(base64Encoded: "AB==") {
            #expect(lenient == Data([0]))
        }
        #expect(Base64URL.decode("AB") == nil)
    }
}
