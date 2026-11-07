import CryptoKit
import Foundation

/// The phone channel after its handshake: one cipher state for each
/// direction, each with its own key and counter. Every relay binary frame is
/// exactly one transport message, sealed with empty associated data.
///
/// A message is at most 65,535 bytes (spec section 4.2), so a plaintext is at
/// most 65,519. A plaintext over that fails loudly rather than producing a
/// frame the relay would drop.
struct NoiseTransport: Sendable {
    static let maxMessageLength = 65_535
    static let maxPlaintextLength = maxMessageLength - NoiseCipherState.tagLength

    private var send: NoiseCipherState
    private var receive: NoiseCipherState

    init(send: NoiseCipherState, receive: NoiseCipherState) {
        self.send = send
        self.receive = receive
    }

    /// Builds both directions from raw keys, for the vectors and tests. The
    /// bridge gets its transports only from a finished handshake.
    init(sendKey: SymmetricKey, receiveKey: SymmetricKey, sendNonce: UInt64 = 0, receiveNonce: UInt64 = 0) {
        self.init(
            send: NoiseCipherState(key: sendKey, nonce: sendNonce),
            receive: NoiseCipherState(key: receiveKey, nonce: receiveNonce)
        )
    }

    mutating func encrypt(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= Self.maxPlaintextLength else {
            throw NoiseError.messageTooLong
        }
        return try send.encrypt(ad: Data(), plaintext: plaintext)
    }

    /// The plaintext of one received message. A failure throws and leaves the
    /// receive counter where it was.
    mutating func decrypt(_ ciphertext: Data) throws -> Data {
        guard ciphertext.count <= Self.maxMessageLength else {
            throw NoiseError.messageTooLong
        }
        return try receive.decrypt(ad: Data(), ciphertext: ciphertext)
    }
}
