import CryptoKit
import Foundation

/// The laptop's side of the phone channel's handshake: it reads message 1 and
/// writes message 2.
///
/// What a throw does:
/// - **A call out of turn** throws `invalidState` and changes nothing:
///   `writeMessage2` before `readMessage1`, a `readMessage1` after one has
///   succeeded, or any call once the handshake has completed or failed.
/// - **A `writeMessage2` that fails in its turn**, for a payload too long or
///   a failed key agreement, ends the handshake: every later call throws
///   `invalidState`.
/// - **A `readMessage1` that fails** changes nothing, so the caller can drop
///   a frame that fails to read and still read the real message 1.
struct NoiseResponder: Sendable {
    private var state: NoiseHandshakeState

    /// Throws `invalidPSK` unless `psk` fits `pattern`: `ikpsk2` needs a
    /// 256-bit key and `ik` takes nil. `ephemeral` is for the vectors; nil
    /// makes a fresh key.
    init(
        pattern: NoisePattern,
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        psk: SymmetricKey?,
        prologue: Data,
        ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil
    ) throws {
        state = try NoiseHandshakeState.responder(
            pattern: pattern,
            staticKey: staticKey,
            psk: psk,
            prologue: prologue,
            ephemeral: ephemeral
        )
    }

    /// Reads message 1 and returns the phone's static key with the payload.
    ///
    /// Only a frame that fails to read can be dropped. A stale frame that is
    /// a valid message 1 does not fail: a replay, or the phone's previous
    /// attempt in the same room, reads successfully, and the real message 1
    /// after it then throws `invalidState`. Nothing here tells such a frame
    /// from the real one, so the caller's rule is: when the completed
    /// handshake's first transport message fails to decrypt, or the handshake
    /// times out, discard this responder and start a new one.
    ///
    /// Check `remoteStatic` against the room's paired phones before calling
    /// `writeMessage2`, and never write message 2 for an unknown key: discard
    /// this responder instead, because it has taken that message 1. Noise
    /// gives message 1 no replay protection, so act on nothing in its payload
    /// until the handshake completes, the phone's first transport message
    /// decrypts and, when pairing, the user allows the phone.
    mutating func readMessage1(_ message: Data) throws -> (remoteStatic: Curve25519.KeyAgreement.PublicKey, payload: Data) {
        var next = state
        let payload = try next.readMessage(message)
        guard let remoteStatic = next.remoteStatic else {
            throw NoiseError.invalidState
        }
        state = next
        return (remoteStatic, payload)
    }

    /// Message 2, which carries `payload` encrypted and completes the
    /// handshake.
    mutating func writeMessage2(payload: Data) throws -> (message: Data, transport: NoiseTransport, handshakeHash: Data) {
        let message = try state.writeMessage(payload: payload)
        let finished = try state.finish()
        return (message, finished.transport, finished.handshakeHash)
    }
}
