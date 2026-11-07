import Foundation

/// Why a phone bridge operation failed.
///
/// Each description is a sentence the Phone pane can show as it stands, so
/// it names the problem and, where there is one, the way out.
enum PhoneBridgeError: Error, Equatable, LocalizedError {
    /// The relay's `GET /v1/info` could not be read: the request failed, or
    /// the relay answered with a status other than 200. The text says which.
    case relayCheckFailed(String)
    /// The relay answered, but not as a TBD relay: its body is not the info
    /// object, or its `name` is not `tbd-relay`.
    case notATBDRelay
    /// The relay is a TBD relay whose `api` list lacks the version this
    /// laptop speaks. The payload is the list it offered.
    case unsupportedRelayAPI([Int])
    /// A message for the phone would not fit one transport message:
    /// serialized, envelope included, it is over
    /// `NoiseTransport.maxPlaintextLength` bytes.
    case messageTooLarge
    /// An `app` body handed to the bridge is not exactly one JSON object.
    case notAJSONObject
    /// No pairing offer with that ID is open: it was never made, another
    /// offer replaced it, or it ended without expiring (paired, denied or
    /// interrupted).
    case noSuchOffer
    /// The pairing offer reached the end of its 5 minutes.
    case offerExpired
    /// The pairing offer is open, but no phone has finished pairing with it
    /// yet, so there is nothing to allow.
    case notAwaitingApproval
    /// The pairing link built for a new offer is one the phone would refuse,
    /// almost always because the saved relay address is not in the form a
    /// pairing link carries. No offer was made.
    case invalidPairingLink

    var errorDescription: String? {
        switch self {
        case .relayCheckFailed(let detail):
            return "Could not reach the relay: \(detail)"
        case .notATBDRelay:
            return "That address is not a TBD relay."
        case .unsupportedRelayAPI(let offered):
            return "This relay offers API \(offered), but this TBD needs API \(PhoneBridgeConstants.relayAPIVersion). "
                + "Deploy the relay again from the guide."
        case .messageTooLarge:
            return "A message for the phone is larger than one encrypted frame can carry."
        case .notAJSONObject:
            return "A message for the phone app is not one JSON object."
        case .noSuchOffer:
            return "That pairing request is no longer open. Start pairing again."
        case .offerExpired:
            return "The pairing code expired. Start pairing again for a new code."
        case .notAwaitingApproval:
            return "No phone has finished pairing yet. Wait until the phone shows its code."
        case .invalidPairingLink:
            return "Couldn't make a pairing code a phone can read. Check the relay address in Settings → Phone: "
                + "it must be just an https:// address, such as https://acme-relay.acme.workers.dev."
        }
    }
}
