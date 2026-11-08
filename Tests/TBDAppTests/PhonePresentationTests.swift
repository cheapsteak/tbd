import AppKit
import CoreImage
import Foundation
import Testing
import TBDShared
@testable import TBDApp

@Suite("PhonePresentation")
struct PhonePresentationTests {
    private func status(
        enabled: Bool = true, relayURL: String? = "https://acme-relay.acme.workers.dev",
        running: Bool = true, problem: String? = nil, relayState: PhoneRelayState = .connected
    ) -> PhoneStatusResult {
        PhoneStatusResult(
            enabled: enabled, relayURL: relayURL, loaderURLOverride: nil, running: running,
            problem: problem,
            relay: PhoneRelayStatus(state: relayState, version: "1.0.0", bundledVersion: "1.0.0"),
            connectedDeviceIDs: [], pairing: nil)
    }

    @Test func relayLines() {
        #expect(PhonePresentation.relayLine(.init(state: .notSetUp, version: nil, bundledVersion: "1.0.0", detail: nil))
            == "Not set up")
        #expect(PhonePresentation.relayLine(.init(state: .connected, version: "1.0.0", bundledVersion: "1.0.0", detail: nil))
            == "Connected (relay 1.0.0)")
        #expect(PhonePresentation.relayLine(.init(state: .unreachable, version: nil, bundledVersion: "1.0.0", detail: "timeout"))
            == "Unreachable: timeout")
        let api2 = "This relay offers API [2], but this TBD needs API 1. Deploy the relay again from the guide."
        #expect(PhonePresentation.relayLine(.init(state: .incompatible, version: "2.0.0", bundledVersion: "1.0.0", detail: api2))
            == "Not usable: \(api2)")
        #expect(PhonePresentation.relayLine(.init(state: .updateAvailable, version: "0.9.0", bundledVersion: "1.0.0", detail: nil))
            == "Relay update available (relay 0.9.0, this TBD expects 1.0.0)")
    }

    @Test func aStoppedBridgeSaysItsRelayIsNotChecked() {
        #expect(PhonePresentation.relayLine(for: status(enabled: false, running: false, relayState: .checking))
            == "Not checked while phone control is off")
        #expect(PhonePresentation.relayLine(for: status(running: false, problem: "The laptop key file is missing.",
                                                        relayState: .checking))
            == "Not checked while phone control is not running")
        // A state a newer daemon added reads the same.
        #expect(PhonePresentation.relayLine(for: status(running: false, relayState: .unknown))
            == "Not checked while phone control is not running")
        #expect(PhonePresentation.relayLine(for: status(relayURL: nil, running: false, relayState: .notSetUp)) == nil)
        #expect(PhonePresentation.relayLine(for: status()) == "Connected (relay 1.0.0)")
        #expect(PhonePresentation.relayLine(for: status(relayState: .checking)) == "Checking…")
    }

    @Test func pairingNeedsFlagRelayAndARunningBridge() {
        let blocked: [PhoneStatusResult?] = [
            nil,
            status(enabled: false),
            status(relayURL: nil, relayState: .notSetUp),
            status(running: false, problem: "The laptop key file is missing."),
            status(relayState: .incompatible),
        ]
        for candidate in blocked {
            #expect(!PhonePresentation.canPair(candidate))
            #expect(PhonePresentation.pairDisabledReason(candidate) != nil)
        }
        #expect(PhonePresentation.canPair(status()))
        #expect(PhonePresentation.pairDisabledReason(status()) == nil)
        #expect(PhonePresentation.pairDisabledReason(status(running: false, problem: "The laptop key file is missing."))
            == "The laptop key file is missing.")
    }

    @Test func countdownAndCode() {
        #expect(PhonePresentation.countdown(remaining: 299.4) == "4:59")
        #expect(PhonePresentation.countdown(remaining: 65) == "1:05")
        #expect(PhonePresentation.countdown(remaining: -3) == "0:00")
        #expect(PhonePresentation.formatCode("012345") == "012 345")
        #expect(PhonePresentation.approvalPrompt(name: "iPhone", code: "123456")
            == "Allow 'iPhone' to control this laptop? Code 123 456")
    }

    @Test func endedOffersAndStatusErrors() {
        #expect(PhonePresentation.endedSentence(.denied) == "Pairing was denied.")
        #expect(PhonePresentation.endedSentence(.expired) == "The code expired.")
        #expect(PhonePresentation.endedSentence(.interrupted) == "The code was used by another device. Start again.")
        #expect(PhonePresentation.isLive(.waitingForPhone))
        #expect(PhonePresentation.isLive(.awaitingApproval))
        #expect(!PhonePresentation.isLive(.paired))
        #expect(!PhonePresentation.isLive(.expired))
        #expect(PhonePresentation.statusErrorLine("Unknown method: phone.status")
            == "This daemon does not support phone control. Restart TBD.")
        #expect(PhonePresentation.statusErrorLine("phone control is managed only from the TBD app")
            .contains("managed only from the TBD app"))
    }

    @Test func deviceRowsSayWhetherEachPhoneIsConnected() throws {
        let pairedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let room = String(repeating: "A", count: 43)
        let connected = PhoneDevice(id: UUID(), name: "iPhone", publicKey: Data(count: 32), roomID: room,
                                    pairedAt: pairedAt, lastSeenAt: pairedAt)
        let seen = PhoneDevice(id: UUID(), name: "Pixel", publicKey: Data(count: 32), roomID: room,
                               pairedAt: pairedAt, lastSeenAt: pairedAt)
        let never = PhoneDevice(id: UUID(), name: "iPad", publicKey: Data(count: 32), roomID: room,
                                pairedAt: pairedAt)
        let rows = PhonePresentation.deviceRows(
            [connected, seen, never], connected: [connected.id], now: pairedAt.addingTimeInterval(3600))
        let names = rows.map(\.name)
        #expect(names == ["iPhone", "Pixel", "iPad"])
        try #require(rows.count == 3)
        #expect(rows[0].seenText == "Connected")
        #expect(rows[0].isConnected)
        #expect(rows[1].seenText.hasPrefix("Last seen "))
        #expect(rows[2].seenText == "Never connected")
        #expect(rows[2].pairedText.hasPrefix("Paired "))
    }

    /// The pane rebuilds its rows once a minute and keeps them only when they
    /// differ, so a later `now` must give a different "Last seen".
    @Test func lastSeenMovesOnWithNow() throws {
        let lastSeen = Date(timeIntervalSince1970: 1_800_000_000)
        let phone = PhoneDevice(id: UUID(), name: "Pixel", publicKey: Data(count: 32),
                                roomID: String(repeating: "A", count: 43), pairedAt: lastSeen, lastSeenAt: lastSeen)
        let soon = PhonePresentation.deviceRows([phone], connected: [], now: lastSeen.addingTimeInterval(60))
        let later = PhonePresentation.deviceRows([phone], connected: [], now: lastSeen.addingTimeInterval(3 * 3600))
        #expect(soon != later)
        let soonText = try #require(soon.first).seenText
        let laterText = try #require(later.first).seenText
        #expect(soonText.hasPrefix("Last seen "))
        #expect(laterText.hasPrefix("Last seen "))
        #expect(soonText != laterText)
    }

    @Test func theQRCodeReadsBack() throws {
        let link = "https://tbd-phone.github.io/#p=" + String(repeating: "A", count: 420)
        let image = try #require(PhoneQRCode.image(for: link))
        let tiff = try #require(image.tiffRepresentation)
        let ci = try #require(CIImage(data: tiff))
        let detector = try #require(CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let message = (detector.features(in: ci).first as? CIQRCodeFeature)?.messageString
        #expect(message == link)
    }
}
