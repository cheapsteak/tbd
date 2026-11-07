import Foundation

/// The 6-digit code both screens show after a pairing handshake, so the user
/// can check that the phone and the laptop finished the same handshake.
///
/// The code is the first 4 bytes of the 32-byte Noise handshake hash, read as
/// a big-endian `UInt32`, modulo 1,000,000, zero-padded to 6 digits. It has no
/// space; the UI inserts one when it shows the code as `123 456`.
enum PhoneConfirmationCode {
    static func make(handshakeHash: Data) -> String {
        precondition(handshakeHash.count == 32, "a SHA-256 Noise handshake hash is 32 bytes")
        // Fold rather than subscript: the hash may be a slice whose
        // startIndex is not 0.
        let leading = handshakeHash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let digits = String(leading % 1_000_000)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }
}
