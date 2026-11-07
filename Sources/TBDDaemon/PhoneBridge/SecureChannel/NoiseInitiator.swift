import CryptoKit
import Foundation

/// The phone's side of the phone channel's handshake: it writes message 1 and
/// reads message 2. The loader runs its JavaScript twin; this one serves the
/// shared vectors and the daemon's tests.
///
/// What a throw does:
/// - **A call out of turn** throws `invalidState` and changes nothing:
///   `readMessage2` before `writeMessage1`, a second `writeMessage1`, or any
///   call once the handshake has completed or failed.
/// - **A `writeMessage1` that fails in its turn**, for a payload too long or
///   a failed key agreement, ends the handshake: every later call throws
///   `invalidState`.
/// - **A `readMessage2` that fails** changes nothing, so the caller can drop
///   a stale frame and still read the real message 2.
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

    /// Message 1, which carries `payload` encrypted.
    mutating func writeMessage1(payload: Data) throws -> Data {
        try state.writeMessage(payload: payload)
    }

    /// Reads message 2 and completes the handshake.
    mutating func readMessage2(_ message: Data) throws -> (payload: Data, transport: NoiseTransport, handshakeHash: Data) {
        // `finish()` runs on the copy too, so the state changes only when
        // both succeed.
        var next = state
        let payload = try next.readMessage(message)
        let finished = try next.finish()
        state = next
        return (payload, finished.transport, finished.handshakeHash)
    }
}
