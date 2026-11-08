import Foundation
import Testing
@testable import TBDShared

@Suite("PhoneRPCWire")
struct PhoneRPCWireTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(value))
    }

    @Test func methodNames() {
        #expect(RPCMethod.phoneStatus == "phone.status")
        #expect(RPCMethod.phonePairStart == "phone.pairStart")
        #expect(RPCMethod.phonePairAllow == "phone.pairAllow")
        #expect(RPCMethod.phonePairDeny == "phone.pairDeny")
        #expect(RPCMethod.phoneDevices == "phone.devices")
        #expect(RPCMethod.phoneRevoke == "phone.revoke")
        #expect(RPCMethod.configSetPhoneControlEnabled == "config.setPhoneControlEnabled")
        #expect(RPCMethod.configSetPhoneRelayURL == "config.setPhoneRelayURL")
        #expect(RPCMethod.configSetPhoneLoaderURL == "config.setPhoneLoaderURL")
        #expect(Set(RPCMethod.phoneAppOnlyMethods).count == 9)
        #expect(RPCMethod.phoneAppOnlyMethods.allSatisfy { $0.hasPrefix("phone.") || $0.hasPrefix("config.setPhone") })
    }

    @Test func unknownStatesDecodeAsUnknown() throws {
        #expect(try decode(PhoneRelayState.self, #""brandNew""#) == .unknown)
        #expect(try decode(PhonePairingState.self, #""brandNew""#) == .unknown)
        #expect(try decode(PhoneRelayState.self, #""updateAvailable""#) == .updateAvailable)
        #expect(try decode(PhonePairingState.self, #""awaitingApproval""#) == .awaitingApproval)
    }

    @Test func statusRoundTrips() throws {
        let status = PhoneStatusResult(
            enabled: true,
            relayURL: "https://acme-relay.acme.workers.dev",
            loaderURLOverride: "https://acme.github.io/loader/",
            running: false,
            problem: "The laptop key file has mode 0644; it must be 0600.",
            relay: PhoneRelayStatus(
                state: .updateAvailable, version: "0.9.0", bundledVersion: "1.0.0",
                detail: "The relay is older than this build."),
            connectedDeviceIDs: [UUID(), UUID()],
            pairing: PhonePairingStatus(
                offerID: UUID(),
                link: "https://acme.github.io/loader/#p=e30",
                expiresAt: Date(timeIntervalSince1970: 1_800_000_300),
                state: .paired,
                confirmationCode: "012345",
                deviceName: "iPhone",
                deviceID: UUID()))
        #expect(try roundTrip(status) == status)
    }

    @Test func deviceListRoundTrips() throws {
        let list = PhoneDeviceListResult(devices: [PhoneDevice(
            id: UUID(), name: "iPhone", publicKey: Data(repeating: 7, count: 32),
            roomID: String(repeating: "A", count: 43),
            pairedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_800_000_060))])
        #expect(try roundTrip(list) == list)
    }

    @Test func phoneStatusChangedRoundTrips() throws {
        let decoded = try roundTrip(StateDelta.phoneStatusChanged)
        guard case .phoneStatusChanged = decoded else {
            Issue.record("decoded \(decoded)")
            return
        }
    }

    /// Every expected address here must also pass the pairing link's relay
    /// rule; `RelayAddressParityTests` (TBDDaemonTests, which can see
    /// `PairingLink`) carries the same cases and checks that.
    @Test(arguments: [
        ("https://acme-relay.acme.workers.dev/", "https://acme-relay.acme.workers.dev"),
        ("  https://ACME-relay.acme.workers.dev  ", "https://acme-relay.acme.workers.dev"),
        ("http://localhost:8787", "http://localhost:8787"),
        ("http://127.0.0.1:8787/", "http://127.0.0.1:8787"),
        ("HTTPS://Acme.Example/", "https://acme.example"),
        ("http://LOCALHOST:8787/", "http://localhost:8787"),
        ("https://acme.example:443", "https://acme.example:443"),
    ])
    func relayURLsNormalize(raw: String, expected: String) throws {
        #expect(try PhoneURLValidation.relay(raw).absoluteString == expected)
    }

    @Test(arguments: [
        ("http://acme.example", PhoneURLValidation.Failure.unsupportedScheme),
        ("http://[::1]:8787", PhoneURLValidation.Failure.unsupportedScheme),
        ("wss://acme.example", PhoneURLValidation.Failure.unsupportedScheme),
        ("https://", PhoneURLValidation.Failure.noHost),
        ("not a url", PhoneURLValidation.Failure.notAURL),
        ("acme.example", PhoneURLValidation.Failure.notAURL),
        ("https://acme.example/?x=1", PhoneURLValidation.Failure.hasQuery),
        ("https://acme.example/#p", PhoneURLValidation.Failure.hasFragment),
        // A pairing link carries a relay as scheme, host and port only.
        ("https://acme.example/relay/", PhoneURLValidation.Failure.hasPath),
        ("https://acme.example/relay", PhoneURLValidation.Failure.hasPath),
        ("https://acme.example//", PhoneURLValidation.Failure.hasPath),
        ("https://user@acme.example", PhoneURLValidation.Failure.hasUserInfo),
        ("https://127.0.0.1", PhoneURLValidation.Failure.badHost),
        ("https://acme_relay.example", PhoneURLValidation.Failure.badHost),
        ("https://xn--acme-9qa.example", PhoneURLValidation.Failure.badHost),
        ("https://acme.example.", PhoneURLValidation.Failure.badHost),
        ("https://acme.example:0", PhoneURLValidation.Failure.badPort),
    ])
    func badRelayURLsAreRefused(raw: String, failure: PhoneURLValidation.Failure) {
        #expect(throws: failure) {
            _ = try PhoneURLValidation.relay(raw)
        }
    }

    @Test func loaderKeepsItsPathAndRefusesAFragment() throws {
        #expect(try PhoneURLValidation.loader("https://acme.github.io/loader/").absoluteString
            == "https://acme.github.io/loader/")
        #expect(try PhoneURLValidation.loader(" https://ACME.github.io/loader ").absoluteString
            == "https://acme.github.io/loader")
        #expect(throws: PhoneURLValidation.Failure.hasFragment) {
            _ = try PhoneURLValidation.loader("https://acme.github.io/#x")
        }
        #expect(throws: PhoneURLValidation.Failure.unsupportedScheme) {
            _ = try PhoneURLValidation.loader("http://acme.github.io/loader/")
        }
    }

    @Test(arguments: [
        PhoneURLValidation.Failure.notAURL, .unsupportedScheme, .noHost, .hasQuery, .hasFragment,
        .hasPath, .hasUserInfo, .badHost, .badPort,
    ])
    func everyURLFailureExplainsItself(failure: PhoneURLValidation.Failure) {
        // `LocalizedError` puts the description where the Phone pane reads it,
        // instead of Foundation's generic "The operation couldn't be completed".
        #expect(failure.localizedDescription == failure.errorDescription)
        #expect(!failure.localizedDescription.isEmpty)
    }
}
