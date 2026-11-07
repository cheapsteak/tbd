import CryptoKit
import Foundation

/// Noise's CipherState with the AESGCM cipher (Noise revision 34, sections
/// 5.1 and 12.2): an optional key and a 64-bit nonce counter.
///
/// Without a key, encryption and decryption pass the bytes through, as the
/// early handshake tokens need. With a key, each operation uses the counter
/// as its nonce and then advances it. The counter value 2^64−1 is reserved,
/// so an operation at that value throws `nonceExhausted`.
///
/// A plain value type with no reference-typed storage of its own, so a
/// caller can work on a copy and keep it only when every step succeeds.
struct NoiseCipherState: Sendable {
    /// The AES-GCM tag that follows every ciphertext.
    static let tagLength = 16

    private let key: SymmetricKey?
    private(set) var nonce: UInt64

    init(key: SymmetricKey? = nil, nonce: UInt64 = 0) {
        self.key = key
        self.nonce = nonce
    }

    /// The ciphertext followed by its 16-byte tag, never CryptoKit's
    /// `combined` form, which puts the nonce first.
    mutating func encrypt(ad: Data, plaintext: Data) throws -> Data {
        guard let key else {
            return Data(plaintext)
        }
        guard nonce != .max else {
            throw NoiseError.nonceExhausted
        }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: AES.GCM.Nonce(data: Self.nonceBytes(nonce)),
            authenticating: ad
        )
        nonce += 1
        return sealed.ciphertext + sealed.tag
    }

    /// The plaintext of `ciphertext`, which ends with its 16-byte tag. A
    /// failure throws and leaves the nonce where it was.
    mutating func decrypt(ad: Data, ciphertext: Data) throws -> Data {
        guard let key else {
            return Data(ciphertext)
        }
        guard nonce != .max else {
            throw NoiseError.nonceExhausted
        }
        guard ciphertext.count >= Self.tagLength else {
            throw NoiseError.messageTooShort
        }
        let plaintext: Data
        do {
            // Slice, never subscript: `ciphertext` may be a slice of a relay
            // frame whose startIndex is not 0.
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Self.nonceBytes(nonce)),
                ciphertext: ciphertext.dropLast(Self.tagLength),
                tag: ciphertext.suffix(Self.tagLength)
            )
            plaintext = try AES.GCM.open(box, using: key, authenticating: ad)
        } catch {
            throw NoiseError.decryptFailed
        }
        nonce += 1
        return plaintext
    }

    /// The 12-byte AES-GCM nonce: 4 zero bytes, then the counter big-endian.
    static func nonceBytes(_ n: UInt64) -> Data {
        Data(count: 4) + withUnsafeBytes(of: n.bigEndian) { Data($0) }
    }
}
