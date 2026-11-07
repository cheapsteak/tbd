import Foundation
import os

/// The phone bridge's record: what it logs under `phone-bridge` and at which
/// level (spec section 12). Every file in `PhoneBridge/` logs through
/// ``record(_:)``, so the rule below holds in one place.
///
/// **What a record never carries.** No pairing secret, pairing link, key
/// bytes, confirmation code or message content, and no phone name before the
/// user clicks Allow. A name enters only through the cases that take one,
/// `allowed`, `connected`, `disconnected` and `revoked`, each of which names a
/// phone that has a `phone_device` row. Every `reason` and `detail` is a fixed
/// phrase or an error's description, never text the phone sent.
enum PhoneBridgeLog {
    enum Event: Sendable {
        // Pairing, before Allow.
        case offerCreated
        /// Handshake message 2 went out. `deviceID` is nil in pairing and the
        /// paired phone's ID on its own room. `replacing` is set when the new
        /// handshake replaced one whose first transport message had not
        /// arrived.
        case handshakeAnswered(deviceID: UUID?, replacing: Bool)
        /// A pairing attempt was dropped and the offer keeps waiting.
        case attemptDropped(reason: String)
        /// The pairing phone's `hello` decrypted; the laptop waits for Allow.
        case handshakeCompleted
        case denied
        case expired
        case interrupted(reason: String)
        /// The pairing notification had no worktree to sit on.
        case pairingNoticeSkipped
        /// A binary frame did not lead to a channel. `deviceID` is nil in
        /// pairing and the paired phone's ID on its own room.
        case handshakeRefused(reason: String, deviceID: UUID?)

        // Paired phones.
        case allowed(name: String, deviceID: UUID)
        case connected(name: String, deviceID: UUID)
        case disconnected(name: String, deviceID: UUID)
        /// A paired phone's channel ended from the laptop's side.
        case channelEnded(deviceID: UUID, reason: String)
        case revoked(name: String, deviceID: UUID)

        // Sockets and the bridge.
        /// A frame did not reach the relay. `deviceID` is nil in pairing.
        case frameNotSent(deviceID: UUID?, detail: String)
        case relayRefused(reason: String)
        case started(devices: Int)
        case stopped(reason: String)
        /// Something failed that the user may need to know about. The text is
        /// a fixed phrase and, at most, an error's description and a device
        /// ID.
        case failed(String)
    }

    enum Level: Sendable, Equatable {
        case debug, notice, error
    }

    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    /// The record's text for `event`.
    static func message(_ event: Event) -> String {
        switch event {
        case .offerCreated:
            return "Created a phone pairing offer"
        case .handshakeAnswered(let deviceID, let replacing):
            guard let deviceID else {
                return replacing
                    ? "Answered a phone pairing handshake in place of one whose first message had not arrived; "
                        + "waiting for its first message"
                    : "Answered a phone pairing handshake; waiting for its first message"
            }
            return replacing
                ? "Answered a new handshake from phone \(deviceID) in place of one with nothing decrypted; "
                    + "waiting for its first message"
                : "Answered a handshake from phone \(deviceID); waiting for its first message"
        case .attemptDropped(let reason):
            return "Dropped a phone pairing handshake: \(reason)"
        case .handshakeCompleted:
            return "a phone completed the pairing handshake; waiting for Allow"
        case .denied:
            return "Phone pairing denied"
        case .expired:
            return "Phone pairing offer expired"
        case .interrupted(let reason):
            return "Phone pairing interrupted: \(reason)"
        case .pairingNoticeSkipped:
            return "pairing notification skipped: no repository"
        case .handshakeRefused(let reason, let deviceID):
            guard let deviceID else { return "Refused a phone pairing handshake: \(reason)" }
            return "Refused a phone handshake for device \(deviceID): \(reason)"
        case .allowed(let name, let deviceID):
            return "Allowed phone \(name) (\(deviceID)); it moves to its own room"
        case .connected(let name, let deviceID):
            return "Phone \(name) (\(deviceID)) connected"
        case .disconnected(let name, let deviceID):
            return "Phone \(name) (\(deviceID)) disconnected"
        case .channelEnded(let deviceID, let reason):
            return "Ending the channel with phone \(deviceID): \(reason)"
        case .revoked(let name, let deviceID):
            return "Revoked phone \(name) (\(deviceID))"
        case .frameNotSent(let deviceID, let detail):
            guard let deviceID else { return "A phone pairing frame did not leave: \(detail)" }
            return "A frame for phone \(deviceID) did not leave: \(detail)"
        case .relayRefused(let reason):
            return "Refused the phone relay; its links stop: \(reason)"
        case .started(let devices):
            return "Phone control started with \(devices) paired phone\(devices == 1 ? "" : "s")"
        case .stopped(let reason):
            return "Phone control stopped: \(reason)"
        case .failed(let text):
            return text
        }
    }

    /// The level `event` is logged at. The spec's record (pairing, Allow,
    /// Deny, expiry, revoke, connect and disconnect, refused handshakes and
    /// relays) is `.notice`; a paired room's handshake answers and unsent
    /// frames are `.debug`, because they repeat on every reconnect.
    static func level(_ event: Event) -> Level {
        switch event {
        case .handshakeAnswered(let deviceID, _), .frameNotSent(let deviceID, _):
            return deviceID == nil ? .notice : .debug
        case .failed:
            return .error
        case .offerCreated, .attemptDropped, .handshakeCompleted, .denied, .expired, .interrupted,
             .pairingNoticeSkipped, .handshakeRefused, .allowed, .connected, .disconnected, .channelEnded,
             .revoked, .relayRefused, .started, .stopped:
            return .notice
        }
    }

    /// Logs `event` under `com.tbd.daemon`, category `phone-bridge`.
    static func record(_ event: Event) {
        let text = message(event)
        switch level(event) {
        case .debug:
            logger.debug("\(text, privacy: .public)")
        case .notice:
            logger.notice("\(text, privacy: .public)")
        case .error:
            logger.error("\(text, privacy: .public)")
        }
    }
}
