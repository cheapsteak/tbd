import CryptoKit
import Foundation
import Testing

@testable import TBDDaemonLib

/// `phone/test-vectors/noise-cacophony.json`: cacophony's published vectors
/// for the two protocols the phone channel uses. Keys are snake_case in the
/// file; `PhoneTestVectors` decodes them into these names.
struct CacophonyFile: Decodable {
    struct Message: Decodable {
        let payload: String
        let ciphertext: String
    }

    struct Vector: Decodable {
        let protocolName: String
        let initPrologue: String
        let initPsks: [String]?
        let initStatic: String
        let initEphemeral: String
        let initRemoteStatic: String
        let respPrologue: String
        let respPsks: [String]?
        let respStatic: String
        let respEphemeral: String
        let handshakeHash: String
        let messages: [Message]
    }

    let vectors: [Vector]
}

extension CacophonyFile.Vector {
    func pattern() throws -> NoisePattern {
        let match = [NoisePattern.ikpsk2, .ik].first(where: { $0.protocolName == protocolName })
        return try #require(match, "unknown protocol \(protocolName)")
    }

    func payload(_ index: Int) -> Data {
        PhoneTestVectors.bytes(messages[index].payload)
    }

    func ciphertext(_ index: Int) -> Data {
        PhoneTestVectors.bytes(messages[index].ciphertext)
    }

    var expectedHash: Data {
        PhoneTestVectors.bytes(handshakeHash)
    }

    /// The vector's PSK: the first of its `psks`, which only IKpsk2 has.
    private static func firstKey(_ psks: [String]?) -> SymmetricKey? {
        guard let hex = psks?.first else {
            return nil
        }
        return SymmetricKey(data: PhoneTestVectors.bytes(hex))
    }

    /// The vector's initiator, or one whose PSK is `psk` instead of the
    /// vector's.
    func makeInitiator(psk: SymmetricKey? = nil) throws -> NoiseInitiator {
        try NoiseInitiator(
            pattern: pattern(),
            staticKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: PhoneTestVectors.bytes(initStatic)),
            remoteStatic: Curve25519.KeyAgreement.PublicKey(rawRepresentation: PhoneTestVectors.bytes(initRemoteStatic)),
            psk: psk ?? Self.firstKey(initPsks),
            prologue: PhoneTestVectors.bytes(initPrologue),
            ephemeral: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: PhoneTestVectors.bytes(initEphemeral))
        )
    }

    func makeResponder() throws -> NoiseResponder {
        try NoiseResponder(
            pattern: pattern(),
            staticKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: PhoneTestVectors.bytes(respStatic)),
            psk: Self.firstKey(respPsks),
            prologue: PhoneTestVectors.bytes(respPrologue),
            ephemeral: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: PhoneTestVectors.bytes(respEphemeral))
        )
    }

    /// Messages 2..<6 alternate: the initiator sends the even ones and the
    /// responder the odd ones.
    func checkTransport(_ transport: NoiseTransport, asInitiator: Bool) throws {
        var transport = transport
        for index in 2..<6 {
            if index.isMultiple(of: 2) == asInitiator {
                let sealed = try transport.encrypt(payload(index))
                #expect(sealed == ciphertext(index), "\(protocolName) message \(index)")
            } else {
                let opened = try transport.decrypt(ciphertext(index))
                #expect(opened == payload(index), "\(protocolName) message \(index)")
            }
        }
    }
}

@Suite("Phone channel: cacophony vectors")
struct NoiseCacophonyVectorTests {
    private static func vectors() throws -> [CacophonyFile.Vector] {
        try PhoneTestVectors.load("noise-cacophony.json", as: CacophonyFile.self).vectors
    }

    private static func vector(_ pattern: NoisePattern) throws -> CacophonyFile.Vector {
        let match = try vectors().first(where: { $0.protocolName == pattern.protocolName })
        return try #require(match, "no vector for \(pattern.protocolName)")
    }

    /// Frames meant for a replaced peer, each with the error that refuses it,
    /// to send before `real`. Flipping `real`'s last bit alters the payload's
    /// tag, so a read gets through every token, changing the whole symmetric
    /// state, before it fails: the hardest case for a read that must leave
    /// the state as it was. One frame has an all-zero ephemeral key.
    private static func staleFrames(before real: Data, randomLength: Int) -> [(frame: Data, expected: NoiseError)] {
        [
            (PhoneTestVectors.randomBytes(randomLength), .decryptFailed),
            (Data(count: 10), .messageTooShort),
            (Data(count: 65_536), .messageTooLong),
            (PhoneTestVectors.flipping(real, at: -1), .decryptFailed),
            (Data(count: 32) + real.dropFirst(32), .invalidPublicKey),
        ]
    }

    @Test func fileHoldsBothProtocols() throws {
        let vectors = try Self.vectors()
        let names = Set(vectors.map { $0.protocolName })
        let expected: Set<String> = ["Noise_IK_25519_AESGCM_SHA256", "Noise_IKpsk2_25519_AESGCM_SHA256"]
        #expect(names == expected)
        #expect(vectors.count == 2)
        for v in vectors {
            #expect(v.messages.count == 6, "\(v.protocolName)")
        }
    }

    @Test func initiatorRole() throws {
        for v in try Self.vectors() {
            var initiator = try v.makeInitiator()
            let first = try initiator.writeMessage1(payload: v.payload(0))
            #expect(first == v.ciphertext(0), "\(v.protocolName)")
            let second = try initiator.readMessage2(v.ciphertext(1))
            #expect(second.payload == v.payload(1), "\(v.protocolName)")
            #expect(second.handshakeHash == v.expectedHash, "\(v.protocolName)")
            try v.checkTransport(second.transport, asInitiator: true)
        }
    }

    @Test func responderRole() throws {
        for v in try Self.vectors() {
            var responder = try v.makeResponder()
            let first = try responder.readMessage1(v.ciphertext(0))
            #expect(first.payload == v.payload(0), "\(v.protocolName)")
            let initiatorStatic = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: PhoneTestVectors.bytes(v.initStatic))
            #expect(first.remoteStatic.rawRepresentation == initiatorStatic.publicKey.rawRepresentation, "\(v.protocolName)")
            let second = try responder.writeMessage2(payload: v.payload(1))
            #expect(second.message == v.ciphertext(1), "\(v.protocolName)")
            #expect(second.handshakeHash == v.expectedHash, "\(v.protocolName)")
            try v.checkTransport(second.transport, asInitiator: false)
        }
    }

    /// The `psk` token comes last in message 2, so a wrong PSK still writes
    /// the vector's message 1 and fails only on message 2.
    @Test func pskEntersOnlyAtMessage2() throws {
        let v = try Self.vector(.ikpsk2)
        var initiator = try v.makeInitiator(psk: SymmetricKey(data: Data(count: 32)))
        let first = try initiator.writeMessage1(payload: v.payload(0))
        #expect(first == v.ciphertext(0))
        #expect(throws: NoiseError.decryptFailed) { try initiator.readMessage2(v.ciphertext(1)) }
    }

    @Test func confirmationCodesOfVectors() throws {
        let ik = try Self.vector(.ik)
        let ikpsk2 = try Self.vector(.ikpsk2)
        #expect(PhoneConfirmationCode.make(handshakeHash: ik.expectedHash) == "534016")
        #expect(PhoneConfirmationCode.make(handshakeHash: ikpsk2.expectedHash) == "801003")
    }

    /// The relay can deliver frames meant for a replaced peer before the real
    /// message 1. Each refused frame, including one whose ephemeral key is
    /// all zeros, leaves the responder as it was, so the real message 1 and
    /// then message 2 still match the vector.
    @Test func staleFramesAreDroppedByTheResponder() throws {
        for v in try Self.vectors() {
            var responder = try v.makeResponder()
            let real = v.ciphertext(0)
            for (frame, expected) in Self.staleFrames(before: real, randomLength: 120) {
                #expect(throws: expected, "\(v.protocolName), \(frame.count) bytes") {
                    try responder.readMessage1(frame)
                }
            }
            let first = try responder.readMessage1(real)
            #expect(first.payload == v.payload(0), "\(v.protocolName)")
            let second = try responder.writeMessage2(payload: v.payload(1))
            #expect(second.message == v.ciphertext(1), "\(v.protocolName)")
            #expect(second.handshakeHash == v.expectedHash, "\(v.protocolName)")
            try v.checkTransport(second.transport, asInitiator: false)
        }
    }

    /// The initiator's side of the same: refused frames, including one whose
    /// ephemeral key is all zeros, leave it able to read the real message 2.
    @Test func staleFramesAreDroppedByTheInitiator() throws {
        for v in try Self.vectors() {
            var initiator = try v.makeInitiator()
            let first = try initiator.writeMessage1(payload: v.payload(0))
            #expect(first == v.ciphertext(0), "\(v.protocolName)")
            let real = v.ciphertext(1)
            for (frame, expected) in Self.staleFrames(before: real, randomLength: 64) {
                #expect(throws: expected, "\(v.protocolName), \(frame.count) bytes") {
                    try initiator.readMessage2(frame)
                }
            }
            let second = try initiator.readMessage2(real)
            #expect(second.payload == v.payload(1), "\(v.protocolName)")
            #expect(second.handshakeHash == v.expectedHash, "\(v.protocolName)")
            try v.checkTransport(second.transport, asInitiator: true)
        }
    }

    /// A write out of turn is refused and changes nothing: each side still
    /// writes and reads the vector's messages byte for byte, and reaches its
    /// handshake hash.
    @Test func wrongPhaseWritesChangeNothing() throws {
        for v in try Self.vectors() {
            var initiator = try v.makeInitiator()
            var responder = try v.makeResponder()
            #expect(throws: NoiseError.invalidState, "\(v.protocolName): writeMessage2 before message 1") {
                try responder.writeMessage2(payload: v.payload(1))
            }
            let first = try initiator.writeMessage1(payload: v.payload(0))
            #expect(first == v.ciphertext(0), "\(v.protocolName)")
            #expect(throws: NoiseError.invalidState, "\(v.protocolName): writeMessage1 twice") {
                try initiator.writeMessage1(payload: v.payload(0))
            }

            let received = try responder.readMessage1(first)
            #expect(received.payload == v.payload(0), "\(v.protocolName)")
            let second = try responder.writeMessage2(payload: v.payload(1))
            #expect(second.message == v.ciphertext(1), "\(v.protocolName)")
            #expect(second.handshakeHash == v.expectedHash, "\(v.protocolName)")
            try v.checkTransport(second.transport, asInitiator: false)

            let done = try initiator.readMessage2(second.message)
            #expect(done.payload == v.payload(1), "\(v.protocolName)")
            #expect(done.handshakeHash == v.expectedHash, "\(v.protocolName)")
            try v.checkTransport(done.transport, asInitiator: true)
        }
    }
}
