import CryptoKit
import Foundation
import Testing

@testable import TBDDaemonLib

/// `phone/test-vectors/framing.json`.
struct FramingFile: Decodable {
    struct Message: Decodable {
        /// Decimal, because 2^64−2 does not survive a JS number.
        let nonce: String
        let plaintext: String
        let ciphertext: String
    }

    struct Prologue: Decodable {
        let roomID: String
        let prologue: String
    }

    let key: String
    let messages: [Message]
    let prologue: Prologue
}

@Suite("Phone channel: transport")
struct NoiseTransportTests {
    private static let p = Data(repeating: 0x50, count: 32)
    private static let p0 = Data(repeating: 0xA0, count: 32)
    private static let p1 = Data(repeating: 0xA1, count: 32)

    /// Two ends of one channel: `a` sends under the key `b` receives under,
    /// and the reverse.
    private static func pair() -> (a: NoiseTransport, b: NoiseTransport) {
        let k1 = SymmetricKey(size: .bits256)
        let k2 = SymmetricKey(size: .bits256)
        return (
            NoiseTransport(sendKey: k1, receiveKey: k2),
            NoiseTransport(sendKey: k2, receiveKey: k1)
        )
    }

    @Test func framingVectors() throws {
        let file = try PhoneTestVectors.load("framing.json", as: FramingFile.self)
        let key = SymmetricKey(data: PhoneTestVectors.bytes(file.key))
        #expect(file.messages.count == 5)
        for m in file.messages {
            let nonce = try #require(UInt64(m.nonce), "nonce \(m.nonce)")
            var t = NoiseTransport(sendKey: key, receiveKey: key, sendNonce: nonce, receiveNonce: nonce)
            let plaintext = Data(m.plaintext.utf8)
            let ciphertext = PhoneTestVectors.bytes(m.ciphertext)
            let sealed = try t.encrypt(plaintext)
            #expect(sealed == ciphertext, "nonce \(m.nonce)")
            let opened = try t.decrypt(ciphertext)
            #expect(opened == plaintext, "nonce \(m.nonce)")
        }
    }

    @Test func nonceLayout() {
        #expect(NoiseCipherState.nonceBytes(0x0102030405060708) == PhoneTestVectors.bytes("000000000102030405060708"))
        #expect(NoiseCipherState.nonceBytes(1 << 32) == PhoneTestVectors.bytes("000000000000000100000000"))
    }

    @Test func prologueVector() throws {
        let file = try PhoneTestVectors.load("framing.json", as: FramingFile.self)
        let roomID = try #require(Base64URL.decode(file.prologue.roomID))
        #expect(try PhoneChannelPrologue.make(roomID: roomID) == PhoneTestVectors.bytes(file.prologue.prologue))
        #expect(throws: NoiseError.invalidRoomID) { try PhoneChannelPrologue.make(roomID: Data(count: 31)) }
        #expect(throws: NoiseError.invalidRoomID) { try PhoneChannelPrologue.make(roomID: Data(count: 33)) }
    }

    @Test func protocolNames() {
        #expect(NoisePattern.ikpsk2.protocolName == "Noise_IKpsk2_25519_AESGCM_SHA256")
        #expect(NoisePattern.ik.protocolName == "Noise_IK_25519_AESGCM_SHA256")
        #expect(NoisePattern.ikpsk2.usesPSK)
        #expect(!NoisePattern.ik.usesPSK)
    }

    @Test func replayedMessageFails() throws {
        var (a, b) = Self.pair()
        let m0 = try a.encrypt(Self.p0)
        let opened = try b.decrypt(m0)
        #expect(opened == Self.p0)
        #expect(throws: NoiseError.decryptFailed) { try b.decrypt(m0) }
    }

    /// The failed decrypt of `m1` leaves the receive counter at 0, so `m0`
    /// and then `m1` still decrypt.
    @Test func reorderedMessageFails() throws {
        var (a, b) = Self.pair()
        let m0 = try a.encrypt(Self.p0)
        let m1 = try a.encrypt(Self.p1)
        #expect(throws: NoiseError.decryptFailed) { try b.decrypt(m1) }
        let first = try b.decrypt(m0)
        #expect(first == Self.p0)
        let second = try b.decrypt(m1)
        #expect(second == Self.p1)
    }

    /// Each direction has its own key, so a message sent back to its sender
    /// fails even at the same nonce.
    @Test func reflectedMessageFails() throws {
        var (a, _) = Self.pair()
        let m = try a.encrypt(Self.p)
        #expect(throws: NoiseError.decryptFailed) { try a.decrypt(m) }
    }

    /// Flips one bit of the message: a ciphertext byte, or (−1) the last tag
    /// byte. The untouched message still decrypts afterwards.
    @Test(arguments: [0, 20, -1]) func tamperedByteFails(offset: Int) throws {
        var (a, b) = Self.pair()
        let m = try a.encrypt(Self.p)
        var bytes = Array(m)
        bytes[offset < 0 ? bytes.count + offset : offset] ^= 0x01
        let tampered = Data(bytes)
        #expect(throws: NoiseError.decryptFailed) { try b.decrypt(tampered) }
        let opened = try b.decrypt(m)
        #expect(opened == Self.p)
    }

    @Test func nonceExhaustion() throws {
        let k1 = SymmetricKey(size: .bits256)
        let k2 = SymmetricKey(size: .bits256)
        var a = NoiseTransport(sendKey: k1, receiveKey: k2, sendNonce: UInt64.max - 1)
        var b = NoiseTransport(sendKey: k2, receiveKey: k1, receiveNonce: UInt64.max - 1)
        let last = try a.encrypt(Self.p)
        #expect(throws: NoiseError.nonceExhausted) { try a.encrypt(Self.p) }
        let opened = try b.decrypt(last)
        #expect(opened == Self.p)
        #expect(throws: NoiseError.nonceExhausted) { try b.decrypt(Data(count: 16)) }
    }

    @Test func sizeLimits() throws {
        #expect(NoiseTransport.maxMessageLength == 65_535)
        #expect(NoiseTransport.maxPlaintextLength == 65_519)
        var (a, b) = Self.pair()
        let largest = try a.encrypt(Data(count: 65_519))
        #expect(largest.count == 65_535)
        #expect(throws: NoiseError.messageTooLong) { try a.encrypt(Data(count: 65_520)) }
        #expect(throws: NoiseError.messageTooLong) { try b.decrypt(Data(count: 65_536)) }
        #expect(throws: NoiseError.messageTooShort) { try b.decrypt(Data(count: 15)) }
        let opened = try b.decrypt(largest)
        #expect(opened == Data(count: 65_519))
        // The refused encrypt left the send counter at 1, so `a`'s next
        // message is the one `b` expects after `largest`.
        let next = try a.encrypt(Self.p)
        let openedNext = try b.decrypt(next)
        #expect(openedNext == Self.p)
    }

    /// The bridge hands the channel slices of relay frames, whose
    /// `startIndex` is not 0.
    @Test func decryptsASlice() throws {
        var (a, b) = Self.pair()
        let m = try a.encrypt(Self.p)
        let slice = (Data([0xAA]) + m).dropFirst()
        #expect(slice.startIndex != 0)
        let opened = try b.decrypt(slice)
        #expect(opened == Self.p)
    }

    /// The handshake seals with the handshake hash as associated data.
    @Test func associatedDataIsAuthenticated() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = NoiseCipherState(key: key)
        var receiver = NoiseCipherState(key: key)
        let m = try sender.encrypt(ad: Data([1, 2, 3]), plaintext: Self.p)
        #expect(throws: NoiseError.decryptFailed) { try receiver.decrypt(ad: Data([1, 2, 4]), ciphertext: m) }
        #expect(receiver.nonce == 0)
        let opened = try receiver.decrypt(ad: Data([1, 2, 3]), ciphertext: m)
        #expect(opened == Self.p)
        #expect(receiver.nonce == 1)
    }

    /// Before the handshake mixes in a key, its cipher passes bytes through
    /// and keeps its counter.
    @Test func keylessStatePassesThrough() throws {
        var state = NoiseCipherState()
        let sealed = try state.encrypt(ad: Data([1]), plaintext: Self.p)
        #expect(sealed == Self.p)
        let opened = try state.decrypt(ad: Data([1]), ciphertext: Self.p)
        #expect(opened == Self.p)
        #expect(state.nonce == 0)
    }
}
