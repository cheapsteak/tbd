import CryptoKit
import Foundation
import Testing

@testable import TBDDaemonLib

/// Tier 1 — pure computation over random keys; no files, no daemon, no
/// clock, no subprocesses, no network.
@Suite("Phone channel: handshakes")
struct NoiseHandshakeTests {
    private static let devicePayload = Data(#"{"deviceName":"iPhone"}"#.utf8)
    private static let laptopPayload = Data(#"{"laptopName":"Acme MacBook"}"#.utf8)

    /// One handshake's inputs: random static keys, a random 32-byte PSK for
    /// `ikpsk2`, and the prologue of a random room. A test copies it and
    /// changes a field to make the two sides disagree.
    private struct Setup {
        var pattern: NoisePattern
        var initiatorKey = Curve25519.KeyAgreement.PrivateKey()
        var responderKey = Curve25519.KeyAgreement.PrivateKey()
        var psk: SymmetricKey?
        var prologue: Data

        init(pattern: NoisePattern) throws {
            self.pattern = pattern
            psk = pattern.usesPSK ? SymmetricKey(size: .bits256) : nil
            prologue = try NoiseHandshakeTests.randomPrologue()
        }

        func initiator() throws -> NoiseInitiator {
            try NoiseInitiator(
                pattern: pattern,
                staticKey: initiatorKey,
                remoteStatic: responderKey.publicKey,
                psk: psk,
                prologue: prologue
            )
        }

        func responder() throws -> NoiseResponder {
            try NoiseResponder(pattern: pattern, staticKey: responderKey, psk: psk, prologue: prologue)
        }
    }

    /// Both ends of a finished handshake.
    private struct Finished {
        var phone: NoiseTransport
        var laptop: NoiseTransport
        let phoneHash: Data
        let laptopHash: Data
    }

    private static func randomPrologue() throws -> Data {
        try PhoneChannelPrologue.make(roomID: PhoneTestVectors.randomBytes(32))
    }

    private static func handshake(_ setup: Setup) throws -> Finished {
        var initiator = try setup.initiator()
        var responder = try setup.responder()
        let first = try initiator.writeMessage1(payload: devicePayload)
        _ = try responder.readMessage1(first)
        let second = try responder.writeMessage2(payload: laptopPayload)
        let done = try initiator.readMessage2(second.message)
        return Finished(
            phone: done.transport,
            laptop: second.transport,
            phoneHash: done.handshakeHash,
            laptopHash: second.handshakeHash
        )
    }

    @Test(arguments: [NoisePattern.ikpsk2, .ik]) func roundTrip(pattern: NoisePattern) throws {
        let setup = try Setup(pattern: pattern)
        var initiator = try setup.initiator()
        var responder = try setup.responder()

        let first = try initiator.writeMessage1(payload: Self.devicePayload)
        let received = try responder.readMessage1(first)
        #expect(received.payload == Self.devicePayload)
        #expect(received.remoteStatic.rawRepresentation == setup.initiatorKey.publicKey.rawRepresentation)

        let second = try responder.writeMessage2(payload: Self.laptopPayload)
        let done = try initiator.readMessage2(second.message)
        #expect(done.payload == Self.laptopPayload)
        #expect(done.handshakeHash.count == 32)
        #expect(done.handshakeHash == second.handshakeHash)
        #expect(
            PhoneConfirmationCode.make(handshakeHash: done.handshakeHash)
                == PhoneConfirmationCode.make(handshakeHash: second.handshakeHash)
        )

        var phone = done.transport
        var laptop = second.transport
        for index in 0..<3 {
            let up = Data(#"{"type":"up","n":\#(index)}"#.utf8)
            let sealedUp = try phone.encrypt(up)
            let openedUp = try laptop.decrypt(sealedUp)
            #expect(openedUp == up)
            let down = Data(#"{"type":"down","n":\#(index)}"#.utf8)
            let sealedDown = try laptop.encrypt(down)
            let openedDown = try phone.decrypt(sealedDown)
            #expect(openedDown == down)
        }
    }

    /// The PSK enters only at the end of message 2, so the laptop reads
    /// message 1 and writes message 2, and the phone's read of it fails.
    @Test func wrongPSKFailsAtMessage2() throws {
        let setup = try Setup(pattern: .ikpsk2)
        var phoneSide = setup
        phoneSide.psk = SymmetricKey(size: .bits256)
        var initiator = try phoneSide.initiator()
        var responder = try setup.responder()
        let first = try initiator.writeMessage1(payload: Self.devicePayload)
        let received = try responder.readMessage1(first)
        #expect(received.payload == Self.devicePayload)
        let second = try responder.writeMessage2(payload: Self.laptopPayload)
        #expect(throws: NoiseError.decryptFailed) { try initiator.readMessage2(second.message) }
    }

    /// A phone that holds the wrong laptop key fails at the laptop's first
    /// read, before the laptop learns anything.
    @Test(arguments: [NoisePattern.ikpsk2, .ik]) func wrongResponderKeyFailsAtMessage1(pattern: NoisePattern) throws {
        let setup = try Setup(pattern: pattern)
        var phoneSide = setup
        phoneSide.responderKey = Curve25519.KeyAgreement.PrivateKey()
        var initiator = try phoneSide.initiator()
        var responder = try setup.responder()
        let first = try initiator.writeMessage1(payload: Self.devicePayload)
        #expect(throws: NoiseError.decryptFailed) { try responder.readMessage1(first) }
    }

    @Test(arguments: [NoisePattern.ikpsk2, .ik]) func otherRoomFailsAtMessage1(pattern: NoisePattern) throws {
        let setup = try Setup(pattern: pattern)
        var phoneSide = setup
        phoneSide.prologue = try Self.randomPrologue()
        var initiator = try phoneSide.initiator()
        var responder = try setup.responder()
        let first = try initiator.writeMessage1(payload: Self.devicePayload)
        #expect(throws: NoiseError.decryptFailed) { try responder.readMessage1(first) }
    }

    /// Offsets: the ephemeral key (0), the encrypted static key (40), the
    /// payload ciphertext (85) and the payload's tag (−1).
    @Test(arguments: [0, 40, 85, -1]) func tamperedMessage1Fails(offset: Int) throws {
        let setup = try Setup(pattern: .ikpsk2)
        var initiator = try setup.initiator()
        var responder = try setup.responder()
        let first = try initiator.writeMessage1(payload: Self.devicePayload)
        #expect(first.count == 96 + Self.devicePayload.count)
        let tampered = PhoneTestVectors.flipping(first, at: offset)
        #expect(throws: NoiseError.decryptFailed) { try responder.readMessage1(tampered) }
    }

    /// Offsets: the ephemeral key (0) and the payload's tag (−1).
    @Test(arguments: [0, -1]) func tamperedMessage2Fails(offset: Int) throws {
        let setup = try Setup(pattern: .ikpsk2)
        var initiator = try setup.initiator()
        var responder = try setup.responder()
        let first = try initiator.writeMessage1(payload: Self.devicePayload)
        _ = try responder.readMessage1(first)
        let second = try responder.writeMessage2(payload: Self.laptopPayload)
        let tampered = PhoneTestVectors.flipping(second.message, at: offset)
        #expect(throws: NoiseError.decryptFailed) { try initiator.readMessage2(tampered) }
    }

    /// An all-zero ephemeral key is a low-order point that would make the DH
    /// secret all zeros, so the responder refuses it.
    @Test func allZeroEphemeralIsRejected() throws {
        let setup = try Setup(pattern: .ikpsk2)
        var initiator = try setup.initiator()
        var responder = try setup.responder()
        let first = try initiator.writeMessage1(payload: Self.devicePayload)
        let zeroed = Data(count: 32) + first.dropFirst(32)
        #expect(throws: NoiseError.invalidPublicKey) { try responder.readMessage1(zeroed) }
    }

    /// Fresh ephemeral keys give two connections between the same static
    /// keys different hashes and different transport keys.
    @Test(arguments: [NoisePattern.ikpsk2, .ik]) func eachConnectionHasNewKeys(pattern: NoisePattern) throws {
        let setup = try Setup(pattern: pattern)
        var a = try Self.handshake(setup)
        var b = try Self.handshake(setup)
        #expect(a.phoneHash == a.laptopHash)
        #expect(b.phoneHash == b.laptopHash)
        #expect(a.phoneHash != b.phoneHash)
        let message = try a.phone.encrypt(Self.devicePayload)
        #expect(throws: NoiseError.decryptFailed) { try b.laptop.decrypt(message) }
        let opened = try a.laptop.decrypt(message)
        #expect(opened == Self.devicePayload)
    }

    @Test func lengthLimits() throws {
        let setup = try Setup(pattern: .ikpsk2)

        // Reads: a refused length leaves the handshake as it was.
        var responder = try setup.responder()
        #expect(throws: NoiseError.messageTooShort) { try responder.readMessage1(Data(count: 95)) }
        #expect(throws: NoiseError.messageTooLong) { try responder.readMessage1(Data(count: 65_536)) }
        var initiator = try setup.initiator()
        let first = try initiator.writeMessage1(payload: Self.devicePayload)
        #expect(throws: NoiseError.messageTooShort) { try initiator.readMessage2(Data(count: 47)) }
        #expect(throws: NoiseError.messageTooLong) { try initiator.readMessage2(Data(count: 65_536)) }
        _ = try responder.readMessage1(first)
        let second = try responder.writeMessage2(payload: Self.laptopPayload)
        let done = try initiator.readMessage2(second.message)
        #expect(done.handshakeHash == second.handshakeHash)

        // Message 1: 96 bytes besides the payload.
        var tooLong1 = try setup.initiator()
        #expect(throws: NoiseError.messageTooLong) { try tooLong1.writeMessage1(payload: Data(count: 65_440)) }
        var largest = try setup.initiator()
        let largest1 = try largest.writeMessage1(payload: Data(count: 65_439))
        #expect(largest1.count == 65_535)

        // Message 2: 48 bytes besides the payload.
        var tooLongResponder = try setup.responder()
        _ = try tooLongResponder.readMessage1(largest1)
        #expect(throws: NoiseError.messageTooLong) { try tooLongResponder.writeMessage2(payload: Data(count: 65_488)) }
        var largestResponder = try setup.responder()
        let read1 = try largestResponder.readMessage1(largest1)
        #expect(read1.payload == Data(count: 65_439))
        let largest2 = try largestResponder.writeMessage2(payload: Data(count: 65_487))
        #expect(largest2.message.count == 65_535)
        let read2 = try largest.readMessage2(largest2.message)
        #expect(read2.payload == Data(count: 65_487))
    }

    /// A call out of turn, read or write, is refused and changes nothing, so
    /// the handshake it interrupted still completes.
    @Test func misuseThrowsInvalidState() throws {
        let setup = try Setup(pattern: .ikpsk2)
        var initiator = try setup.initiator()
        var responder = try setup.responder()

        // readMessage2 before writeMessage1. The phase is checked before the
        // length, so 10 bytes are refused for the phase, not as too short.
        #expect(throws: NoiseError.invalidState) { try initiator.readMessage2(Data(count: 48)) }
        #expect(throws: NoiseError.invalidState) { try initiator.readMessage2(Data(count: 10)) }
        // writeMessage2 before readMessage1.
        #expect(throws: NoiseError.invalidState) { try responder.writeMessage2(payload: Self.laptopPayload) }

        let first = try initiator.writeMessage1(payload: Self.devicePayload)
        // writeMessage1 twice.
        #expect(throws: NoiseError.invalidState) { try initiator.writeMessage1(payload: Self.devicePayload) }

        _ = try responder.readMessage1(first)
        // readMessage1 twice.
        #expect(throws: NoiseError.invalidState) { try responder.readMessage1(first) }
        #expect(throws: NoiseError.invalidState) { try responder.readMessage1(Data(count: 10)) }

        // None of the refusals changed anything, so the handshake completes.
        let second = try responder.writeMessage2(payload: Self.laptopPayload)
        let done = try initiator.readMessage2(second.message)
        #expect(done.payload == Self.laptopPayload)
        #expect(done.handshakeHash == second.handshakeHash)

        // A finished handshake takes no more messages.
        #expect(throws: NoiseError.invalidState) { try initiator.readMessage2(second.message) }
        #expect(throws: NoiseError.invalidState) { try responder.writeMessage2(payload: Self.laptopPayload) }
    }

    /// A write that fails in its turn ends the handshake, unlike a call out
    /// of turn: every later call is refused, the write it would have been
    /// in turn for too.
    @Test func failedWriteInItsTurnEndsTheHandshake() throws {
        let setup = try Setup(pattern: .ikpsk2)

        var initiator = try setup.initiator()
        #expect(throws: NoiseError.messageTooLong) { try initiator.writeMessage1(payload: Data(count: 65_440)) }
        #expect(throws: NoiseError.invalidState) { try initiator.writeMessage1(payload: Self.devicePayload) }
        #expect(throws: NoiseError.invalidState) { try initiator.readMessage2(Data(count: 48)) }

        var phone = try setup.initiator()
        let first = try phone.writeMessage1(payload: Self.devicePayload)
        var responder = try setup.responder()
        _ = try responder.readMessage1(first)
        #expect(throws: NoiseError.messageTooLong) { try responder.writeMessage2(payload: Data(count: 65_488)) }
        #expect(throws: NoiseError.invalidState) { try responder.writeMessage2(payload: Self.laptopPayload) }
        #expect(throws: NoiseError.invalidState) { try responder.readMessage1(first) }
    }

    /// A write made out of turn on either side, before or after a step of
    /// the handshake, leaves both sides able to finish it and agree.
    @Test(arguments: [NoisePattern.ikpsk2, .ik]) func wrongPhaseWritesLeaveTheHandshakeAbleToComplete(pattern: NoisePattern) throws {
        let setup = try Setup(pattern: pattern)
        var initiator = try setup.initiator()
        var responder = try setup.responder()

        #expect(throws: NoiseError.invalidState) { try responder.writeMessage2(payload: Self.laptopPayload) }
        let first = try initiator.writeMessage1(payload: Self.devicePayload)
        #expect(throws: NoiseError.invalidState) { try initiator.writeMessage1(payload: Self.devicePayload) }
        #expect(throws: NoiseError.invalidState) { try responder.writeMessage2(payload: Self.laptopPayload) }
        let received = try responder.readMessage1(first)
        #expect(received.payload == Self.devicePayload)
        #expect(throws: NoiseError.invalidState) { try initiator.writeMessage1(payload: Self.devicePayload) }

        let second = try responder.writeMessage2(payload: Self.laptopPayload)
        let done = try initiator.readMessage2(second.message)
        #expect(done.payload == Self.laptopPayload)
        #expect(done.handshakeHash == second.handshakeHash)

        var phone = done.transport
        var laptop = second.transport
        let sealed = try phone.encrypt(Self.devicePayload)
        let opened = try laptop.decrypt(sealed)
        #expect(opened == Self.devicePayload)
    }

    /// `finish()` hands out the transport once. A second transport would
    /// have the same keys at nonce 0 and reuse AES-GCM nonces, so a second
    /// call throws, as does a call before message 2, and a throw changes
    /// nothing.
    @Test(arguments: [NoisePattern.ikpsk2, .ik]) func finishIsOneShot(pattern: NoisePattern) throws {
        let setup = try Setup(pattern: pattern)
        var initiator = try NoiseHandshakeState.initiator(
            pattern: pattern,
            staticKey: setup.initiatorKey,
            remoteStatic: setup.responderKey.publicKey,
            psk: setup.psk,
            prologue: setup.prologue
        )
        var responder = try NoiseHandshakeState.responder(
            pattern: pattern,
            staticKey: setup.responderKey,
            psk: setup.psk,
            prologue: setup.prologue
        )
        #expect(throws: NoiseError.invalidState) { try initiator.finish() }
        let first = try initiator.writeMessage(payload: Self.devicePayload)
        _ = try responder.readMessage(first)
        #expect(throws: NoiseError.invalidState) { try responder.finish() }
        let second = try responder.writeMessage(payload: Self.laptopPayload)
        _ = try initiator.readMessage(second)

        var laptop = try responder.finish()
        var phone = try initiator.finish()
        #expect(phone.handshakeHash == laptop.handshakeHash)
        #expect(throws: NoiseError.invalidState) { try responder.finish() }
        #expect(throws: NoiseError.invalidState) { try initiator.finish() }

        // The one transport each side got works.
        let sealed = try phone.transport.encrypt(Self.devicePayload)
        let opened = try laptop.transport.decrypt(sealed)
        #expect(opened == Self.devicePayload)
    }

    /// Once the handshake completes, each wrapper refuses every call, so
    /// neither side can get a second transport.
    @Test(arguments: [NoisePattern.ikpsk2, .ik]) func completedHandshakeRefusesEveryCall(pattern: NoisePattern) throws {
        let setup = try Setup(pattern: pattern)
        var initiator = try setup.initiator()
        var responder = try setup.responder()
        let first = try initiator.writeMessage1(payload: Self.devicePayload)
        _ = try responder.readMessage1(first)
        let second = try responder.writeMessage2(payload: Self.laptopPayload)
        _ = try initiator.readMessage2(second.message)

        #expect(throws: NoiseError.invalidState) { try initiator.readMessage2(second.message) }
        #expect(throws: NoiseError.invalidState) { try initiator.writeMessage1(payload: Self.devicePayload) }
        #expect(throws: NoiseError.invalidState) { try initiator.readMessage2(second.message) }
        #expect(throws: NoiseError.invalidState) { try responder.readMessage1(first) }
        #expect(throws: NoiseError.invalidState) { try responder.writeMessage2(payload: Self.laptopPayload) }
        #expect(throws: NoiseError.invalidState) { try responder.readMessage1(first) }
    }

    /// Empty payloads give the shortest messages, 96 and 48 bytes, and the
    /// reads accept them: each minimum length is allowed.
    @Test(arguments: [NoisePattern.ikpsk2, .ik]) func emptyPayloadsRoundTrip(pattern: NoisePattern) throws {
        let setup = try Setup(pattern: pattern)
        var initiator = try setup.initiator()
        var responder = try setup.responder()

        let first = try initiator.writeMessage1(payload: Data())
        #expect(first.count == 96)
        let received = try responder.readMessage1(first)
        #expect(received.payload.isEmpty)
        #expect(received.remoteStatic.rawRepresentation == setup.initiatorKey.publicKey.rawRepresentation)

        let second = try responder.writeMessage2(payload: Data())
        #expect(second.message.count == 48)
        let done = try initiator.readMessage2(second.message)
        #expect(done.payload.isEmpty)
        #expect(done.handshakeHash == second.handshakeHash)

        var phone = done.transport
        var laptop = second.transport
        let sealed = try phone.encrypt(Self.devicePayload)
        let opened = try laptop.decrypt(sealed)
        #expect(opened == Self.devicePayload)
    }

    @Test func pskMustFitPattern() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let remote = Curve25519.KeyAgreement.PrivateKey().publicKey
        let prologue = try Self.randomPrologue()
        let cases: [(pattern: NoisePattern, psk: SymmetricKey?)] = [
            (.ikpsk2, nil),
            (.ik, SymmetricKey(size: .bits256)),
            (.ikpsk2, SymmetricKey(size: .bits128)),
        ]
        for (pattern, psk) in cases {
            #expect(throws: NoiseError.invalidPSK) {
                try NoiseInitiator(pattern: pattern, staticKey: key, remoteStatic: remote, psk: psk, prologue: prologue)
            }
            #expect(throws: NoiseError.invalidPSK) {
                try NoiseResponder(pattern: pattern, staticKey: key, psk: psk, prologue: prologue)
            }
        }
    }

    /// The bridge hands the channel slices of relay frames, whose
    /// `startIndex` is not 0.
    @Test func slicedMessagesParse() throws {
        let setup = try Setup(pattern: .ikpsk2)
        var initiator = try setup.initiator()
        var responder = try setup.responder()
        let first = try initiator.writeMessage1(payload: Self.devicePayload)
        let slice1 = (Data([0xAA]) + first).dropFirst()
        #expect(slice1.startIndex != 0)
        let received = try responder.readMessage1(slice1)
        #expect(received.payload == Self.devicePayload)
        let second = try responder.writeMessage2(payload: Self.laptopPayload)
        let slice2 = (Data([0xAA]) + second.message).dropFirst()
        #expect(slice2.startIndex != 0)
        let done = try initiator.readMessage2(slice2)
        #expect(done.payload == Self.laptopPayload)
        #expect(done.handshakeHash == second.handshakeHash)
    }
}
