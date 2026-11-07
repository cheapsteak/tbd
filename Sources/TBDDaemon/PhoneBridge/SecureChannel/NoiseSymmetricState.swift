import CryptoKit
import Foundation

/// Noise's SymmetricState with SHA-256 and AESGCM (Noise revision 34,
/// sections 4 and 5.2): the handshake hash `h`, the chaining key `ck`, and the
/// cipher state that `ck` keys as the handshake goes.
///
/// A plain value type, like `NoiseCipherState`, so a handshake can work on a
/// copy and keep it only when every step succeeds.
struct NoiseSymmetricState: Sendable {
    /// SHA-256's output length, which is Noise's `HASHLEN`.
    static let hashLength = SHA256.byteCount

    /// `h`: every byte sent or received so far, hashed in order. Its value
    /// after the last message is the handshake hash both sides compare.
    private(set) var handshakeHash: Data
    /// `ck`: the HKDF chaining key, always 32 bytes.
    private var chainingKey: Data
    private var cipher: NoiseCipherState

    /// `h` starts as the protocol name zero-padded to 32 bytes when it fits
    /// (both of the channel's names do: 28 and 32 bytes) and as its SHA-256
    /// otherwise. `ck` starts equal to `h`, and the cipher has no key.
    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        if name.count <= Self.hashLength {
            handshakeHash = name + Data(count: Self.hashLength - name.count)
        } else {
            handshakeHash = Data(SHA256.hash(data: name))
        }
        chainingKey = handshakeHash
        cipher = NoiseCipherState()
    }

    /// `h = SHA256(h || data)`.
    mutating func mixHash(_ data: Data) {
        var hasher = SHA256()
        hasher.update(data: handshakeHash)
        hasher.update(data: data)
        handshakeHash = Data(hasher.finalize())
    }

    /// `(ck, k) = HKDF(ck, ikm, 2)`, then the cipher takes `k` with its
    /// counter at 0.
    mutating func mixKey(_ inputKeyMaterial: Data) {
        let output = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial, outputs: 2)
        chainingKey = output[0]
        cipher = NoiseCipherState(key: SymmetricKey(data: output[1]))
    }

    /// `(ck, th, k) = HKDF(ck, ikm, 3)`, then `mixHash(th)`, then the cipher
    /// takes `k`. The `psk` token mixes the pre-shared key this way.
    mutating func mixKeyAndHash(_ inputKeyMaterial: Data) {
        let output = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial, outputs: 3)
        chainingKey = output[0]
        mixHash(output[1])
        cipher = NoiseCipherState(key: SymmetricKey(data: output[2]))
    }

    /// Seals `plaintext` with `h` as associated data, then hashes the
    /// ciphertext into `h`. Before the first `mixKey` the bytes pass through.
    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(ad: handshakeHash, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    /// Opens `ciphertext` with `h` as associated data, then hashes the
    /// ciphertext, not the plaintext, into `h`.
    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ad: handshakeHash, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    /// The two transport cipher states, from `HKDF(ck, empty, 2)`.
    func split() -> (initiatorToResponder: NoiseCipherState, responderToInitiator: NoiseCipherState) {
        let output = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: Data(), outputs: 2)
        return (
            NoiseCipherState(key: SymmetricKey(data: output[0])),
            NoiseCipherState(key: SymmetricKey(data: output[1]))
        )
    }

    /// Noise's HKDF (section 4.3) over HMAC-SHA256, whose keys are always 32
    /// bytes here:
    /// - `t = HMAC(ck, ikm)`;
    /// - `o1 = HMAC(t, 0x01)`;
    /// - `o2 = HMAC(t, o1 || 0x02)`;
    /// - `o3 = HMAC(t, o2 || 0x03)`.
    static func hkdf(chainingKey: Data, inputKeyMaterial: Data, outputs: Int) -> [Data] {
        precondition((2...3).contains(outputs), "Noise's HKDF makes two or three outputs")
        let tempKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(
            for: inputKeyMaterial,
            using: SymmetricKey(data: chainingKey)
        )))
        var result: [Data] = []
        var previous = Data()
        for index in 1...outputs {
            var block = previous
            block.append(UInt8(index))
            previous = Data(HMAC<SHA256>.authenticationCode(for: block, using: tempKey))
            result.append(previous)
        }
        return result
    }

    /// X25519 between `privateKey` and `publicKey`, as raw bytes. A public
    /// key of low order gives the all-zero secret, which CryptoKit refuses
    /// and which this also checks, so a peer cannot force a known secret.
    static func dh(
        _ privateKey: Curve25519.KeyAgreement.PrivateKey,
        _ publicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> Data {
        let secret: Data
        do {
            secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
        } catch {
            throw NoiseError.invalidPublicKey
        }
        guard secret.contains(where: { $0 != 0 }) else {
            throw NoiseError.invalidPublicKey
        }
        return secret
    }
}
