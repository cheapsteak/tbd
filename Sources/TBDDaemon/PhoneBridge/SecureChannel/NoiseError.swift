import Foundation

/// Why a Noise handshake or transport operation failed. The loader's
/// `NoiseError` carries the same case name as its `code`.
enum NoiseError: LocalizedError, Equatable {
    /// A message failed authentication: wrong key, wrong nonce, wrong
    /// associated data, or altered bytes.
    case decryptFailed
    /// The nonce counter reached 2^64−1, which Noise reserves.
    case nonceExhausted
    /// A message is shorter than its fixed parts.
    case messageTooShort
    /// A message or plaintext exceeds the 65,535-byte Noise limit.
    case messageTooLong
    /// A public key is not a usable X25519 key.
    case invalidPublicKey
    /// The PSK does not fit the pattern.
    case invalidPSK
    /// A room ID is not 32 bytes.
    case invalidRoomID
    /// An operation came out of the handshake's order.
    case invalidState

    var errorDescription: String? {
        switch self {
        case .decryptFailed:
            return "A phone channel message failed to decrypt."
        case .nonceExhausted:
            return "The phone channel used up its message counter."
        case .messageTooShort:
            return "A phone channel message is too short."
        case .messageTooLong:
            return "A phone channel message is longer than 65,535 bytes."
        case .invalidPublicKey:
            return "A phone channel public key is not a valid X25519 key."
        case .invalidPSK:
            return "The phone channel's pairing secret does not fit the handshake pattern."
        case .invalidRoomID:
            return "A phone channel room ID is not 32 bytes."
        case .invalidState:
            return "A phone channel handshake step came out of order."
        }
    }
}
