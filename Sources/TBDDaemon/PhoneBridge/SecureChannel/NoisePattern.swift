import Foundation

/// The two Noise handshake patterns the phone channel uses. The phone is the
/// initiator and the laptop the responder in both.
enum NoisePattern: Sendable {
    /// Pairing: the one-time pairing secret is the PSK.
    case ikpsk2
    /// Every later connection, between keys that already know each other.
    case ik

    /// The Noise protocol name, which seeds the handshake hash.
    var protocolName: String {
        switch self {
        case .ikpsk2: return "Noise_IKpsk2_25519_AESGCM_SHA256"
        case .ik: return "Noise_IK_25519_AESGCM_SHA256"
        }
    }

    var usesPSK: Bool {
        self == .ikpsk2
    }
}
