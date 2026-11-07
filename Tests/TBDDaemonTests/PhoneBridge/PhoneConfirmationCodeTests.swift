import Foundation
import Testing

@testable import TBDDaemonLib

/// `phone/test-vectors/confirmation-code.json`.
struct ConfirmationCodeFile: Decodable {
    struct Case: Decodable {
        let description: String
        let handshakeHash: String
        let code: String
    }

    let cases: [Case]
}

/// Tier 1 — pure computation over the committed vectors in
/// `phone/test-vectors/confirmation-code.json`; no daemon, no clock,
/// no subprocesses, no network.
@Suite("Phone channel: confirmation code")
struct PhoneConfirmationCodeTests {
    @Test func sharedVectors() throws {
        let file = try PhoneTestVectors.load("confirmation-code.json", as: ConfirmationCodeFile.self)
        #expect(file.cases.count == 7)
        for c in file.cases {
            #expect(
                PhoneConfirmationCode.make(handshakeHash: PhoneTestVectors.bytes(c.handshakeHash)) == c.code,
                "\(c.description)"
            )
        }
    }

    @Test func cacophonyIKpsk2Hash() {
        #expect(PhoneConfirmationCode.make(handshakeHash: PhoneTestVectors.bytes(
            "48c3f1eb397c797af6b139032c6074cb41282ff033ee25d5aee4a4badd3a2c3f")) == "801003")
    }

    @Test func keepsLeadingZeros() {
        #expect(PhoneConfirmationCode.make(handshakeHash: PhoneTestVectors.bytes(
            "0000002a" + String(repeating: "11", count: 28))) == "000042")
    }

    /// The bridge hands the channel slices of relay frames, whose
    /// `startIndex` is not 0.
    @Test func readsASlicedHash() {
        let framed = Data([0xEE]) + PhoneTestVectors.bytes(
            "48c3f1eb397c797af6b139032c6074cb41282ff033ee25d5aee4a4badd3a2c3f")
        #expect(PhoneConfirmationCode.make(handshakeHash: framed.dropFirst()) == "801003")
    }
}
