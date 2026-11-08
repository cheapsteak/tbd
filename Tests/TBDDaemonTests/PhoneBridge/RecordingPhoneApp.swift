import Foundation

@testable import TBDDaemonLib

/// A `PhoneAppHandling` that records every call, for the tests of the code
/// that drives one. It can also hold one message on a gate, so a test can
/// see what happens while the app layer is still busy with it.
actor RecordingPhoneApp: PhoneAppHandling {
    /// Every call, in order: `connected`, `message:<requestID>` (`message:?`
    /// for a body with no string `requestID`), `disconnected`, and
    /// `revoked:<deviceID>`.
    private(set) var log: [String] = []
    /// The peer of every `phoneConnected`, in order.
    private(set) var peers: [PhonePeer] = []
    /// The outbox the latest `phoneConnected` handed over.
    private(set) var lastOutbox: (any PhoneAppOutbox)?
    /// The request ID the gate holds, while it is closed.
    private var gatedRequestID: String?
    private var heldCalls: [CheckedContinuation<Void, Never>] = []

    init() {}

    /// Closes the gate on `requestID`: a message with that request ID is
    /// logged, then waits until `openGate()`.
    func closeGate(on requestID: String) {
        gatedRequestID = requestID
    }

    /// Opens the gate and lets every held message return.
    func openGate() {
        gatedRequestID = nil
        let released = heldCalls
        heldCalls = []
        for call in released {
            call.resume()
        }
    }

    func phoneConnected(_ peer: PhonePeer, outbox: any PhoneAppOutbox) {
        log.append("connected")
        peers.append(peer)
        lastOutbox = outbox
    }

    func handleAppMessage(_ body: Data, from peer: PhonePeer) async {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let requestID = object?["requestID"] as? String
        log.append("message:\(requestID ?? "?")")
        guard let gated = gatedRequestID, gated == requestID else {
            return
        }
        await withCheckedContinuation { heldCalls.append($0) }
    }

    func phoneDisconnected(_ peer: PhonePeer) {
        log.append("disconnected")
    }

    func phoneRevoked(deviceID: UUID) {
        log.append("revoked:\(deviceID)")
    }
}
