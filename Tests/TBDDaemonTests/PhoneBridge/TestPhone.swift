import CryptoKit
import Foundation

@testable import TBDDaemonLib

/// Why a ``TestPhone`` call failed.
enum TestPhoneError: Error, Equatable, LocalizedError {
    /// The phone has no socket: it has not joined a room.
    case notInARoom
    /// No handshake has completed on the phone's socket, so it cannot
    /// encrypt or decrypt.
    case noChannel
    /// `finishHandshake()` ran with no handshake started.
    case noHandshakeStarted
    /// The room ID is not 32 bytes of base64url.
    case badRoom
    /// The pairing link's key or secret is not base64url.
    case badLink
    /// A decrypted message, or a handshake payload, is not one JSON object.
    case notAJSONObject
    /// Message 2's payload has no string `laptopName`.
    case noLaptopName

    var errorDescription: String? {
        switch self {
        case .notInARoom:
            return "The test phone has not joined a room."
        case .noChannel:
            return "The test phone has no completed handshake on its socket."
        case .noHandshakeStarted:
            return "The test phone was asked to finish a handshake it never started."
        case .badRoom:
            return "The room ID is not 32 bytes of base64url."
        case .badLink:
            return "The pairing link's key or secret is not base64url."
        case .notAJSONObject:
            return "The phone got a message that is not one JSON object."
        case .noLaptopName:
            return "Message 2's payload has no laptopName."
        }
    }
}

/// A phone for the phone bridge's tests: a key, a socket on a ``FakeRelay``,
/// and the phone's side of the Noise channel, built on plan 01's
/// `NoiseInitiator`. It does what the loader does, one step at a time.
///
/// - **Rooms.** `init(relay:room:key:)` and `rejoin(room:)` join a room;
///   `connectIK` and `pair` join the room they name when the phone is not in
///   it already, and otherwise reuse the socket.
/// - **Handshakes.** Each `startIK`, `connectIK` or `pair` call starts a fresh
///   initiator, so a phone can retry on the same socket after a failed
///   attempt. Message 2 is the next binary frame: a frame this handshake
///   cannot read makes the call throw, as a wrong pairing secret does.
/// - **Frames.** `next()` takes the next binary frame and decrypts it;
///   `nextRawFrame()` takes it as it is; `nextSignal()` takes the next text
///   frame. A frame of the other kind that arrives first is kept, in order,
///   for the other call. A wait that gets nothing throws
///   ``FakePhoneSocketTimeout``.
///
/// Calls on one phone are made one at a time. A lock guards its state, so the
/// phone is `Sendable` and a `Task` may hold it.
final class TestPhone: @unchecked Sendable {
    /// The phone's static key: the one a paired `phone_device` row holds.
    let key: Curve25519.KeyAgreement.PrivateKey

    private let relay: FakeRelay
    private let lock = NSLock()
    private var socket: FakePhoneSocket?
    /// The handshake waiting for message 2.
    private var pending: NoiseInitiator?
    /// The channel of the last completed handshake on this socket.
    private var transport: NoiseTransport?
    private var binaryFrames: [Data] = []
    private var signals: [String] = []
    private var message1: Data?

    /// A phone with no socket yet.
    init(relay: FakeRelay, key: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.relay = relay
        self.key = key
    }

    /// A phone with a socket in `room`. It has read nothing: the relay's
    /// `peer-joined` or `peer-absent` is the first signal waiting.
    convenience init(relay: FakeRelay, room: String, key: Curve25519.KeyAgreement.PrivateKey = .init()) throws {
        self.init(relay: relay, key: key)
        try join(room)
    }

    /// The room the phone's socket is in; nil before it joins.
    var room: String? {
        lock.withLock { socket?.room }
    }

    /// The code the phone's socket closed with, from either end; nil while
    /// it is open or before it joins.
    var closeCode: Int? {
        lock.withLock { socket }?.closeCode
    }

    /// The bytes of the last message 1 this phone sent, for replay tests.
    var lastMessage1: Data? {
        lock.withLock { message1 }
    }

    // MARK: Rooms

    /// Closes the phone's socket, if it has one, and joins `room` with a new
    /// socket and the same key. Nothing read on the old socket carries over.
    func rejoin(room: String) async throws {
        close()
        try join(room)
    }

    /// Closes the phone's socket from its end.
    func close() {
        lock.withLock { socket }?.close()
    }

    // MARK: Handshakes

    /// Writes and sends message 1 of a `Noise_IK` handshake with the payload
    /// `{}`, and returns it. `finishHandshake()` reads message 2.
    @discardableResult
    func startIK(room: String, laptopKey: Curve25519.KeyAgreement.PublicKey) async throws -> Data {
        try startHandshake(room: room, pattern: .ik, laptopKey: laptopKey, psk: nil, payload: Data("{}".utf8))
    }

    /// Reads message 2 of the handshake the last `startIK` began, keeps the
    /// channel, and returns the laptop's name from its payload.
    @discardableResult
    func finishHandshake() async throws -> String {
        let reply = try await readMessage2()
        return try Self.laptopName(in: reply.payload)
    }

    /// A whole `Noise_IK` handshake with the laptop whose public key is
    /// `laptopKey`, in `room`. Returns the laptop's name from message 2.
    @discardableResult
    func connectIK(room: String, laptopKey: Curve25519.KeyAgreement.PublicKey) async throws -> String {
        try await startIK(room: room, laptopKey: laptopKey)
        return try await finishHandshake()
    }

    /// Pairs as the loader does: a `Noise_IKpsk2` handshake with the link's
    /// key and secret in the link's room, with `{"deviceName":…}` in message
    /// 1; then, unless `sendHello` is false, the loader's `hello` as the
    /// first transport message. Returns the confirmation code the phone
    /// computed from its own handshake hash, and the laptop's name from
    /// message 2. Throws when message 2 cannot be read, as with a wrong
    /// secret.
    @discardableResult
    func pair(link: PairingLink, deviceName: String, sendHello: Bool = true) async throws
        -> (code: String, laptopName: String) {
        guard let keyBytes = Base64URL.decode(link.key), let secret = Base64URL.decode(link.secret) else {
            throw TestPhoneError.badLink
        }
        let laptopKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyBytes)
        let payload = try JSONSerialization.data(withJSONObject: ["deviceName": deviceName])
        try startHandshake(room: link.room, pattern: .ikpsk2, laptopKey: laptopKey,
                           psk: SymmetricKey(data: secret), payload: payload)
        let reply = try await readMessage2()
        let code = PhoneConfirmationCode.make(handshakeHash: reply.handshakeHash)
        let laptopName = try Self.laptopName(in: reply.payload)
        if sendHello {
            try await self.sendHello()
        }
        return (code, laptopName)
    }

    // MARK: Sending

    /// Sends `{"type":"hello","loaderVersion":"1.0.0","protocols":[1]}`.
    func sendHello() async throws {
        try await send(json: ["type": "hello", "loaderVersion": "1.0.0", "protocols": [1]])
    }

    /// Encrypts `json` on the channel and sends it as one binary frame.
    func send(json: [String: Any]) async throws {
        try sendEncrypted(JSONSerialization.data(withJSONObject: json))
    }

    /// Sends `bytes` as one binary frame, unencrypted.
    func sendRaw(_ bytes: Data) async throws {
        try currentSocket().send(.binary(bytes))
    }

    // MARK: Receiving

    /// Decrypts the next binary frame, which must hold one JSON object.
    func next() async throws -> [String: Any] {
        let frame = try await nextBinaryFrame()
        let plaintext = try lock.withLock { () throws -> Data in
            guard var channel = transport else { throw TestPhoneError.noChannel }
            let opened = try channel.decrypt(frame)
            transport = channel
            return opened
        }
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw TestPhoneError.notAJSONObject
        }
        return object
    }

    /// The next binary frame as it arrived, not decrypted: a message 2 that
    /// answered a replayed message 1, for instance, which the loader tries
    /// and drops.
    func nextRawFrame() async throws -> Data {
        try await nextBinaryFrame()
    }

    /// The next text frame: a relay signal.
    func nextSignal() async throws -> String {
        while true {
            if let kept = lock.withLock({ () -> String? in signals.isEmpty ? nil : signals.removeFirst() }) {
                return kept
            }
            switch try await currentSocket().next() {
            case .text(let text):
                return text
            case .binary(let bytes):
                lock.withLock { binaryFrames.append(bytes) }
            }
        }
    }

    // MARK: Internals

    private func join(_ room: String) throws {
        let joined = try relay.joinAsPhone(room: room)
        lock.withLock {
            socket = joined
            pending = nil
            transport = nil
            binaryFrames = []
            signals = []
        }
    }

    private func currentSocket() throws -> FakePhoneSocket {
        guard let open = lock.withLock({ socket }) else { throw TestPhoneError.notInARoom }
        return open
    }

    /// Joins `room` unless the phone's socket is in it, then writes and sends
    /// message 1 with a fresh initiator.
    @discardableResult
    private func startHandshake(room: String, pattern: NoisePattern, laptopKey: Curve25519.KeyAgreement.PublicKey,
                                psk: SymmetricKey?, payload: Data) throws -> Data {
        if self.room != room {
            close()
            try join(room)
        }
        guard let roomBytes = PhoneRoom.roomBytes(room) else { throw TestPhoneError.badRoom }
        var initiator = try NoiseInitiator(pattern: pattern, staticKey: key, remoteStatic: laptopKey, psk: psk,
                                           prologue: PhoneChannelPrologue.make(roomID: roomBytes))
        let message = try initiator.writeMessage1(payload: payload)
        lock.withLock {
            pending = initiator
            transport = nil
            message1 = message
        }
        try currentSocket().send(.binary(message))
        return message
    }

    /// Reads the next binary frame as message 2 of the pending handshake and
    /// keeps the channel. A frame it cannot read throws, and the handshake
    /// stays pending.
    private func readMessage2() async throws -> (payload: Data, handshakeHash: Data) {
        guard var initiator = lock.withLock({ pending }) else { throw TestPhoneError.noHandshakeStarted }
        let frame = try await nextBinaryFrame()
        let reply = try initiator.readMessage2(frame)
        lock.withLock {
            pending = nil
            transport = reply.transport
        }
        return (reply.payload, reply.handshakeHash)
    }

    private func sendEncrypted(_ plaintext: Data) throws {
        let open = try currentSocket()
        let frame = try lock.withLock { () throws -> Data in
            guard var channel = transport else { throw TestPhoneError.noChannel }
            let sealed = try channel.encrypt(plaintext)
            transport = channel
            return sealed
        }
        try open.send(.binary(frame))
    }

    private func nextBinaryFrame() async throws -> Data {
        while true {
            if let kept = lock.withLock({ () -> Data? in binaryFrames.isEmpty ? nil : binaryFrames.removeFirst() }) {
                return kept
            }
            switch try await currentSocket().next() {
            case .binary(let bytes):
                return bytes
            case .text(let text):
                lock.withLock { signals.append(text) }
            }
        }
    }

    private static func laptopName(in payload: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw TestPhoneError.notAJSONObject
        }
        guard let name = object["laptopName"] as? String else { throw TestPhoneError.noLaptopName }
        return name
    }
}
