import Foundation

// The app-layer hand-off: what the phone bridge calls once a paired phone's
// channel is established. Plan 04's phone app service implements
// `PhoneAppHandling`; until it does, `UnavailablePhoneApp` stands in.

/// A paired phone with an established channel.
public struct PhonePeer: Sendable, Hashable {
    public let deviceID: UUID
    public let deviceName: String
}

/// The way back to one connected phone.
public protocol PhoneAppOutbox: Sendable {
    /// Sends one {"type":"app","body":<appBody>} loader message. `appBody` is a UTF-8 JSON object.
    /// False when the phone is gone.
    func send(appBody: Data) async -> Bool
}

/// The app layer, as the phone bridge drives it.
public protocol PhoneAppHandling: Sendable {
    func phoneConnected(_ peer: PhonePeer, outbox: any PhoneAppOutbox) async
    /// Called once per `app` message, in arrival order, awaited before the next.
    func handleAppMessage(_ body: Data, from peer: PhonePeer) async
    func phoneDisconnected(_ peer: PhonePeer) async
    func phoneRevoked(deviceID: UUID) async
}

/// Holds the current handler. A channel reads it once, when it becomes
/// established, and keeps that handler for its whole life, so one channel's
/// calls never split across two handlers.
actor PhoneAppHandlerSlot {
    private var handler: any PhoneAppHandling

    init(_ handler: any PhoneAppHandling = UnavailablePhoneApp()) {
        self.handler = handler
    }

    func set(_ handler: any PhoneAppHandling) {
        self.handler = handler
    }

    func current() -> any PhoneAppHandling {
        handler
    }
}

/// Stands in until plan 04. Replies to every request with error code
/// "unavailable".
///
/// It answers only a well-formed request: a JSON object whose `kind` is
/// `"request"` and whose `requestID` is a string. Anything else gets no
/// reply, and so does a request from a phone that is not connected. It keeps
/// each connected phone's outbox, keyed by device ID, from `phoneConnected`
/// until `phoneDisconnected` or `phoneRevoked`.
actor UnavailablePhoneApp: PhoneAppHandling {
    private var outboxes: [UUID: any PhoneAppOutbox] = [:]

    init() {}

    func phoneConnected(_ peer: PhonePeer, outbox: any PhoneAppOutbox) {
        outboxes[peer.deviceID] = outbox
    }

    func handleAppMessage(_ body: Data, from peer: PhonePeer) async {
        guard let outbox = outboxes[peer.deviceID],
              let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              request["kind"] as? String == "request",
              let requestID = request["requestID"] as? String else {
            return
        }
        // A reply too large for one frame (a huge request ID) is refused by
        // the outbox, which returns false; there is nothing more to do.
        _ = await outbox.send(appBody: Self.unavailableReply(requestID: requestID))
    }

    func phoneDisconnected(_ peer: PhonePeer) {
        outboxes[peer.deviceID] = nil
    }

    func phoneRevoked(deviceID: UUID) {
        outboxes[deviceID] = nil
    }

    /// The reply to request `requestID`: error code "unavailable".
    static func unavailableReply(requestID: String) -> Data {
        let text = #"{"kind":"reply","requestID":\#(LoaderHandler.jsonString(requestID)),"#
            + #""error":{"code":"unavailable","message":"This TBD build has no phone app service."}}"#
        return Data(text.utf8)
    }
}
