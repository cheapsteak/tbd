import CryptoKit
import Foundation

/// Noise's HandshakeState for the phone channel's two patterns, in either
/// role (Noise revision 34, section 5.3):
///
/// ```
/// IK:                          IKpsk2:
///   <- s                         <- s
///   ...                          ...
///   -> e, es, s, ss              -> e, es, s, ss
///   <- e, ee, se                 <- e, ee, se, psk
/// ```
///
/// Message 1 goes from the initiator (the phone) to the responder (the
/// laptop), and message 2 back, which completes the handshake.
///
/// **Reads are atomic.** The relay can deliver frames meant for a replaced
/// peer before the real handshake message, so each side drops a frame it
/// cannot use and keeps waiting. A read therefore works on a copy and keeps
/// it only on success: when `readMessage` throws, the state is exactly as it
/// was, and the real message can still be read.
///
/// **Writes poison.** When `writeMessage` throws, the handshake is over, and
/// every later call throws `invalidState`.
///
/// **`finish()` works once.** It hands out the transport, and every later
/// call throws `invalidState`.
struct NoiseHandshakeState: Sendable {
    enum Role: Sendable {
        case initiator, responder
    }

    /// `complete` means message 2 is written or read and `finish()` has not
    /// run; `finished` means it has.
    private enum Phase: Sendable {
        case initial, afterMessage1, complete, finished, failed
    }

    private enum DiffieHellman: Sendable {
        case ee, es, se, ss
    }

    private enum Token: Sendable {
        case e, s, psk
        case dh(DiffieHellman)
    }

    private enum Message: Sendable {
        case one, two

        /// The bytes besides the payload: message 1 carries `e` (32), the
        /// encrypted `s` with its tag (48) and the payload's tag (16), and
        /// message 2 carries `e` (32) and the payload's tag (16).
        var overhead: Int {
            let key = NoiseHandshakeState.publicKeyLength
            let tag = NoiseCipherState.tagLength
            switch self {
            case .one: return key + (key + tag) + tag
            case .two: return key + tag
            }
        }

        /// The longest payload that keeps the message within Noise's
        /// 65,535 bytes: 65,439 in message 1 and 65,487 in message 2.
        var maxPayloadLength: Int {
            NoiseTransport.maxMessageLength - overhead
        }
    }

    /// An X25519 public key's raw length.
    static let publicKeyLength = 32

    let pattern: NoisePattern
    let role: Role
    /// The peer's static key: the initiator knows it from the start, and the
    /// responder learns it from message 1.
    private(set) var remoteStatic: Curve25519.KeyAgreement.PublicKey?

    private var phase = Phase.initial
    private var symmetric: NoiseSymmetricState
    private let localStatic: Curve25519.KeyAgreement.PrivateKey
    /// The ephemeral key the vectors inject; nil makes a fresh one.
    private let injectedEphemeral: Curve25519.KeyAgreement.PrivateKey?
    private var localEphemeral: Curve25519.KeyAgreement.PrivateKey?
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    private let psk: SymmetricKey?

    static func initiator(
        pattern: NoisePattern,
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        remoteStatic: Curve25519.KeyAgreement.PublicKey,
        psk: SymmetricKey?,
        prologue: Data,
        ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil
    ) throws -> NoiseHandshakeState {
        try NoiseHandshakeState(
            pattern: pattern,
            role: .initiator,
            staticKey: staticKey,
            remoteStatic: remoteStatic,
            responderStatic: remoteStatic,
            psk: psk,
            prologue: prologue,
            ephemeral: ephemeral
        )
    }

    static func responder(
        pattern: NoisePattern,
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        psk: SymmetricKey?,
        prologue: Data,
        ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil
    ) throws -> NoiseHandshakeState {
        try NoiseHandshakeState(
            pattern: pattern,
            role: .responder,
            staticKey: staticKey,
            remoteStatic: nil,
            responderStatic: staticKey.publicKey,
            psk: psk,
            prologue: prologue,
            ephemeral: ephemeral
        )
    }

    /// Validates the PSK, then mixes in the prologue and the `<- s`
    /// pre-message: the responder's static public key, which the initiator
    /// knows as `remoteStatic` and the responder holds as its own.
    private init(
        pattern: NoisePattern,
        role: Role,
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        remoteStatic: Curve25519.KeyAgreement.PublicKey?,
        responderStatic: Curve25519.KeyAgreement.PublicKey,
        psk: SymmetricKey?,
        prologue: Data,
        ephemeral: Curve25519.KeyAgreement.PrivateKey?
    ) throws {
        guard pattern.usesPSK == (psk != nil), (psk?.bitCount ?? 256) == 256 else {
            throw NoiseError.invalidPSK
        }
        self.pattern = pattern
        self.role = role
        self.remoteStatic = remoteStatic
        self.localStatic = staticKey
        self.injectedEphemeral = ephemeral
        self.psk = psk
        symmetric = NoiseSymmetricState(protocolName: pattern.protocolName)
        symmetric.mixHash(prologue)
        symmetric.mixHash(responderStatic.rawRepresentation)
    }

    /// Writes the next message: the initiator's message 1 or the responder's
    /// message 2. Any throw ends the handshake.
    mutating func writeMessage(payload: Data) throws -> Data {
        do {
            return try write(payload: payload)
        } catch {
            phase = .failed
            throw error
        }
    }

    /// Reads the next message, the responder's message 1 or the initiator's
    /// message 2, and returns its payload. A throw leaves the state as it
    /// was, so a stale or forged frame cannot spoil the real message.
    mutating func readMessage(_ message: Data) throws -> Data {
        var next = self
        let payload = try next.read(message)
        self = next
        return payload
    }

    /// The transport and the handshake hash, once message 2 is written or
    /// read. The initiator sends on the first cipher state of `split()` and
    /// the responder on the second.
    ///
    /// It works once: a second transport would have the same keys at nonce
    /// 0 and reuse AES-GCM nonces, so every later call throws
    /// `invalidState`, as does a call before message 2. A throw changes
    /// nothing.
    mutating func finish() throws -> (transport: NoiseTransport, handshakeHash: Data) {
        guard phase == .complete else {
            throw NoiseError.invalidState
        }
        phase = .finished
        let ciphers = symmetric.split()
        let transport: NoiseTransport
        switch role {
        case .initiator:
            transport = NoiseTransport(send: ciphers.initiatorToResponder, receive: ciphers.responderToInitiator)
        case .responder:
            transport = NoiseTransport(send: ciphers.responderToInitiator, receive: ciphers.initiatorToResponder)
        }
        return (transport, symmetric.handshakeHash)
    }

    // MARK: - Messages

    private func tokens(_ message: Message) -> [Token] {
        switch message {
        case .one:
            return [.e, .dh(.es), .s, .dh(.ss)]
        case .two:
            return pattern.usesPSK ? [.e, .dh(.ee), .dh(.se), .psk] : [.e, .dh(.ee), .dh(.se)]
        }
    }

    private var messageToWrite: Message? {
        switch (role, phase) {
        case (.initiator, .initial): return .one
        case (.responder, .afterMessage1): return .two
        default: return nil
        }
    }

    private var messageToRead: Message? {
        switch (role, phase) {
        case (.responder, .initial): return .one
        case (.initiator, .afterMessage1): return .two
        default: return nil
        }
    }

    private mutating func write(payload: Data) throws -> Data {
        guard let message = messageToWrite else {
            throw NoiseError.invalidState
        }
        guard payload.count <= message.maxPayloadLength else {
            throw NoiseError.messageTooLong
        }
        var bytes = Data()
        for token in tokens(message) {
            try write(token, into: &bytes)
        }
        bytes += try symmetric.encryptAndHash(payload)
        phase = message == .one ? .afterMessage1 : .complete
        return bytes
    }

    /// Reads in place; `readMessage` runs this on a copy. `message` may be a
    /// slice of a relay frame whose startIndex is not 0, so it is only ever
    /// cut with `prefix` and `dropFirst`, never subscripted.
    private mutating func read(_ message: Data) throws -> Data {
        guard let expected = messageToRead else {
            throw NoiseError.invalidState
        }
        guard message.count <= NoiseTransport.maxMessageLength else {
            throw NoiseError.messageTooLong
        }
        guard message.count >= expected.overhead else {
            throw NoiseError.messageTooShort
        }
        var rest = message
        for token in tokens(expected) {
            try read(token, from: &rest)
        }
        let payload = try symmetric.decryptAndHash(rest)
        phase = expected == .one ? .afterMessage1 : .complete
        return payload
    }

    // MARK: - Tokens

    private mutating func write(_ token: Token, into bytes: inout Data) throws {
        switch token {
        case .e:
            let ephemeral = injectedEphemeral ?? Curve25519.KeyAgreement.PrivateKey()
            localEphemeral = ephemeral
            let ephemeralBytes = ephemeral.publicKey.rawRepresentation
            bytes += ephemeralBytes
            mixEphemeral(ephemeralBytes)
        case .s:
            bytes += try symmetric.encryptAndHash(localStatic.publicKey.rawRepresentation)
        case .psk:
            try mixPSK()
        case .dh(let dh):
            try symmetric.mixKey(secret(dh))
        }
    }

    /// The length checks in `read` guarantee the bytes each token takes.
    private mutating func read(_ token: Token, from rest: inout Data) throws {
        switch token {
        case .e:
            let ephemeralBytes = rest.prefix(Self.publicKeyLength)
            rest = rest.dropFirst(Self.publicKeyLength)
            remoteEphemeral = try Self.publicKey(ephemeralBytes)
            mixEphemeral(ephemeralBytes)
        case .s:
            // The cipher always has a key by the `s` token (after `es`), so
            // the key comes encrypted with a tag.
            let length = Self.publicKeyLength + NoiseCipherState.tagLength
            let sealed = rest.prefix(length)
            rest = rest.dropFirst(length)
            remoteStatic = try Self.publicKey(symmetric.decryptAndHash(sealed))
        case .psk:
            try mixPSK()
        case .dh(let dh):
            try symmetric.mixKey(secret(dh))
        }
    }

    /// The `e` token mixes the ephemeral public key into `h`, and in a PSK
    /// pattern into the chaining key too.
    private mutating func mixEphemeral(_ publicKey: Data) {
        symmetric.mixHash(publicKey)
        if pattern.usesPSK {
            symmetric.mixKey(publicKey)
        }
    }

    private mutating func mixPSK() throws {
        guard let psk else {
            throw NoiseError.invalidState
        }
        symmetric.mixKeyAndHash(psk.withUnsafeBytes { Data($0) })
    }

    /// Each side computes the same secret from its own private key and the
    /// peer's public key: `es` is the initiator's ephemeral with the
    /// responder's static, and `se` the initiator's static with the
    /// responder's ephemeral.
    private func secret(_ dh: DiffieHellman) throws -> Data {
        switch (dh, role) {
        case (.ee, _):
            return try NoiseSymmetricState.dh(Self.required(localEphemeral), Self.required(remoteEphemeral))
        case (.es, .initiator), (.se, .responder):
            return try NoiseSymmetricState.dh(Self.required(localEphemeral), Self.required(remoteStatic))
        case (.es, .responder), (.se, .initiator):
            return try NoiseSymmetricState.dh(localStatic, Self.required(remoteEphemeral))
        case (.ss, _):
            return try NoiseSymmetricState.dh(localStatic, Self.required(remoteStatic))
        }
    }

    /// A key the handshake has not reached yet is `invalidState`.
    private static func required<Key>(_ key: Key?) throws -> Key {
        guard let key else {
            throw NoiseError.invalidState
        }
        return key
    }

    private static func publicKey(_ bytes: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        do {
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes)
        } catch {
            throw NoiseError.invalidPublicKey
        }
    }
}
