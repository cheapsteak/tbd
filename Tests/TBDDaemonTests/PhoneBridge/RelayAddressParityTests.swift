import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Relay addresses as a user might paste them, each with the same address
/// after only the normalizing `PhoneURLValidation.relay` may do: trim
/// whitespace, lowercase the scheme and the host, and drop one trailing `/`.
private enum RelayAddressCases {
    /// The first seven are the cases in `PhoneRPCWireTests.relayURLsNormalize`.
    static let accepted: [(String, String)] = [
        ("https://acme-relay.acme.workers.dev/", "https://acme-relay.acme.workers.dev"),
        ("  https://ACME-relay.acme.workers.dev  ", "https://acme-relay.acme.workers.dev"),
        ("http://localhost:8787", "http://localhost:8787"),
        ("http://127.0.0.1:8787/", "http://127.0.0.1:8787"),
        ("HTTPS://Acme.Example/", "https://acme.example"),
        ("http://LOCALHOST:8787/", "http://localhost:8787"),
        ("https://acme.example:443", "https://acme.example:443"),
        ("https://localhost", "https://localhost"),
        ("http://127.0.0.1", "http://127.0.0.1"),
        ("https://123.acme.example:65535", "https://123.acme.example:65535"),
        ("https://\(String(repeating: "a", count: 63)).example", "https://\(String(repeating: "a", count: 63)).example"),
    ]

    static let refused: [(String, String)] = [
        ("https://acme.example/relay/", "https://acme.example/relay"),
        ("https://acme.example/relay", "https://acme.example/relay"),
        ("https://acme.example//", "https://acme.example/"),
        ("https://acme.example/?x=1", "https://acme.example/?x=1"),
        ("https://acme.example/#p", "https://acme.example/#p"),
        ("https://user@acme.example", "https://user@acme.example"),
        ("https://acme.example:", "https://acme.example:"),
        ("https://acme.example:0", "https://acme.example:0"),
        ("https://acme.example:08787", "https://acme.example:08787"),
        ("https://acme.example:65536", "https://acme.example:65536"),
        ("https://127.0.0.1", "https://127.0.0.1"),
        ("https://[::1]:8787", "https://[::1]:8787"),
        ("https://acme_relay.example", "https://acme_relay.example"),
        ("https://xn--acme-9qa.example", "https://xn--acme-9qa.example"),
        ("https://-acme.example", "https://-acme.example"),
        ("https://acme.example.", "https://acme.example."),
        ("https://acme.123", "https://acme.123"),
        ("https://\(String(repeating: "a", count: 64)).example", "https://\(String(repeating: "a", count: 64)).example"),
        ("https://exämple.example", "https://exämple.example"),
        // A Kelvin sign lowercases to an ASCII "k" in Unicode, but the relay
        // rule is ASCII only, so it must stay refused.
        ("https://\u{212A}acme.example", "https://\u{212A}acme.example"),
        ("http://acme.example", "http://acme.example"),
        ("wss://acme.example", "wss://acme.example"),
    ]
}

/// `PhoneURLValidation.relay` (TBDShared) must accept exactly the relays the
/// pairing link's rule (`PairingLink`) accepts, or the laptop would save a
/// relay whose QR codes no phone can read.
@Suite("Phone channel: relay address parity")
struct RelayAddressParityTests {
    private static let loaderURL = URL(string: "https://acme-loader.github.io/")!
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: RelayAddressCases.accepted)
    func anAcceptedRelayFitsAPairingLink(raw: String, normalized: String) throws {
        let saved = try PhoneURLValidation.relay(raw).absoluteString
        #expect(saved == normalized)
        #expect(Self.pairingLinkAccepts(saved), "\(saved)")
    }

    @Test(arguments: RelayAddressCases.refused)
    func aRefusedRelayIsOneAPairingLinkRefuses(raw: String, normalized: String) {
        #expect(throws: PhoneURLValidation.Failure.self) {
            _ = try PhoneURLValidation.relay(raw)
        }
        #expect(!Self.pairingLinkAccepts(normalized), "\(normalized)")
    }

    /// Whether a pairing link built with `relay` parses back unchanged.
    private static func pairingLinkAccepts(_ relay: String) -> Bool {
        let link = PairingLink(
            v: PairingLink.currentVersion,
            relay: relay,
            room: Base64URL.encode(Data(repeating: 1, count: 32)),
            secret: Base64URL.encode(Data(repeating: 2, count: 32)),
            key: Base64URL.encode(Data(repeating: 3, count: 32)),
            name: "Acme Mini",
            exp: 2_000_000_000
        )
        let parsed = try? PairingLink.parse(link.url(loaderURL: loaderURL), now: now)
        return parsed == link
    }
}
