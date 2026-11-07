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
        }
    }
}
