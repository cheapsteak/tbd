import CryptoKit
import Foundation

/// The phone's side of the phone channel's handshake: it writes message 1 and
/// reads message 2. The loader runs its JavaScript twin; this one serves the
/// shared vectors and the daemon's tests.
struct NoiseInitiator: Sendable {
    private var state: NoiseHandshakeState

    /// Throws `invalidPSK` unless `psk` fits `pattern`: `ikpsk2` needs a
    /// 256-bit key and `ik` takes nil. `ephemeral` is for the vectors; nil
    /// makes a fresh key.
    init(
        pattern: NoisePattern,
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        remoteStatic: Curve25519.KeyAgreement.PublicKey,
        psk: SymmetricKey?,
        prologue: Data,
        ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil
    ) throws {
        state = try NoiseHandshakeState.initiator(
            pattern: pattern,
            staticKey: staticKey,
            remoteStatic: remoteStatic,
            psk: psk,
            prologue: prologue,
            ephemeral: ephemeral
        )
    }

    /// Message 1, which carries `payload` encrypted. A throw ends this
    /// handshake: every later call throws `invalidState`.
    mutating func writeMessage1(payload: Data) throws -> Data {
        try state.writeMessage(payload: payload)
    }

    /// Reads message 2 and completes the handshake. A throw leaves the
    /// handshake as it was, so the caller can drop a stale frame and still
    /// read the real message 2.
    mutating func readMessage2(_ message: Data) throws -> (payload: Data, transport: NoiseTransport, handshakeHash: Data) {
        var next = state
        let payload = try next.readMessage(message)
        let finished = try next.finish()
        state = next
        return (payload, finished.transport, finished.handshakeHash)
    }
}
