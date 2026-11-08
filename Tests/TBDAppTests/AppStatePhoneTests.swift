import Foundation
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

/// A `PhoneControlClient` that answers from fixed values and counts calls.
actor FakePhoneClient: PhoneControlClient {
    let status: PhoneStatusResult
    let devices: [PhoneDevice]
    let statusError: (any Error)?
    let relayURLError: (any Error)?
    let allowError: (any Error)?
    let revokeError: (any Error)?
    let pairing: PhonePairingStatus?
    private(set) var statusCalls = 0
    private(set) var relayURLs: [String?] = []
    private(set) var allowedOffers: [UUID] = []
    private(set) var deniedOffers: [UUID] = []

    init(
        status: PhoneStatusResult, devices: [PhoneDevice] = [], statusError: (any Error)? = nil,
        relayURLError: (any Error)? = nil, allowError: (any Error)? = nil, revokeError: (any Error)? = nil,
        pairing: PhonePairingStatus? = nil
    ) {
        self.status = status
        self.devices = devices
        self.statusError = statusError
        self.relayURLError = relayURLError
        self.allowError = allowError
        self.revokeError = revokeError
        self.pairing = pairing
    }

    func phoneStatus() async throws -> PhoneStatusResult {
        statusCalls += 1
        if let statusError { throw statusError }
        return status
    }

    func phoneDevices() async throws -> [PhoneDevice] { devices }

    func phonePairStart() async throws -> PhonePairingStatus {
        guard let pairing else { throw DaemonClientError.rpcError("no offer", code: nil) }
        return pairing
    }

    func phonePairAllow(offerID: UUID) async throws -> PhoneDevice {
        allowedOffers.append(offerID)
        if let allowError { throw allowError }
        return PhoneDevice(id: UUID(), name: "iPhone", publicKey: Data(count: 32),
                           roomID: String(repeating: "A", count: 43), pairedAt: Date())
    }

    func phonePairDeny(offerID: UUID) async throws { deniedOffers.append(offerID) }
    func phoneRevoke(deviceID: UUID) async throws {
        if let revokeError { throw revokeError }
    }
    func setPhoneControlEnabled(_ enabled: Bool) async throws {}

    func setPhoneRelayURL(_ url: String?) async throws {
        relayURLs.append(url)
        if let relayURLError { throw relayURLError }
    }

    func setPhoneLoaderURL(_ url: String?) async throws {}
}

@MainActor
@Suite("AppStatePhone")
struct AppStatePhoneTests {
    private func withState(_ body: (AppState) async throws -> Void) async rethrows {
        let suite = TestDefaultsSuite("TBDAppTests.AppStatePhone")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        try await body(AppState(userDefaults: defaults))
    }

    private func status(
        connected: [UUID] = [], pairing: PhonePairingStatus? = nil
    ) -> PhoneStatusResult {
        PhoneStatusResult(
            enabled: true, relayURL: "https://acme-relay.acme.workers.dev", loaderURLOverride: nil,
            running: true, problem: nil,
            relay: PhoneRelayStatus(state: .connected, version: "1.0.0", bundledVersion: "1.0.0"),
            connectedDeviceIDs: connected, pairing: pairing)
    }

    private func device(_ name: String) -> PhoneDevice {
        PhoneDevice(id: UUID(), name: name, publicKey: Data(count: 32),
                    roomID: String(repeating: "B", count: 43), pairedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func refreshStoresStatusAndDevices() async {
        await withState { state in
            let expectedStatus = status(connected: [UUID()])
            let expectedDevices = [device("iPhone")]
            state.phoneClient = FakePhoneClient(status: expectedStatus, devices: expectedDevices)
            await state.refreshPhone()
            #expect(state.phoneStatus == expectedStatus)
            #expect(state.phoneDevices == expectedDevices)
            #expect(state.phoneStatusError == nil)
        }
    }

    @Test func anOlderDaemonLeavesStatusNilWithAnError() async {
        await withState { state in
            state.phoneClient = FakePhoneClient(
                status: status(),
                statusError: DaemonClientError.rpcError("Unknown method: phone.status", code: nil))
            await state.refreshPhone()
            #expect(state.phoneStatus == nil)
            #expect(state.phoneStatusError?.contains("Unknown method") == true)
        }
    }

    @Test func theStatusDeltaRefetches() async {
        await withState { state in
            let fake = FakePhoneClient(status: status())
            state.phoneClient = fake
            state.handleDelta(.phoneStatusChanged)
            // `fake` is an actor, so the closure can be `@Sendable` and leave
            // the main actor for `pollUntilTrue`.
            let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
                await fake.statusCalls == 1
            }
            #expect(outcome == .satisfied)
        }
    }

    @Test func aRelayURLErrorIsReturnedForInlineDisplay() async {
        await withState { state in
            let fake = FakePhoneClient(
                status: status(),
                relayURLError: DaemonClientError.rpcError("That address is not a TBD relay.", code: nil))
            state.phoneClient = fake
            let failure = await state.setPhoneRelayURL("https://acme.example")
            #expect(failure == "That address is not a TBD relay.")
        }
    }

    @Test func aSavedRelayURLReturnsNilAndABlankOneClearsIt() async {
        await withState { state in
            let fake = FakePhoneClient(status: status())
            state.phoneClient = fake
            let saved = await state.setPhoneRelayURL("  https://acme.example  ")
            let cleared = await state.setPhoneRelayURL("   ")
            #expect(saved == nil)
            #expect(cleared == nil)
            let sent = await fake.relayURLs
            #expect(sent == ["https://acme.example", nil])
        }
    }

    @Test func allowAndDenyActOnTheShownOffer() async {
        await withState { state in
            let offerID = UUID()
            let pairing = PhonePairingStatus(
                offerID: offerID, link: "https://tbd-phone.github.io/#p=AAAA",
                expiresAt: Date(timeIntervalSince1970: 1_800_000_300), state: .waitingForPhone)
            let fake = FakePhoneClient(status: status(pairing: pairing), pairing: pairing)
            state.phoneClient = fake
            await state.refreshPhone()
            let failure = await state.startPhonePairing()
            #expect(failure == nil)
            #expect(state.phoneStatus?.pairing?.offerID == offerID)
            await state.allowPhonePairing()
            await state.denyPhonePairing()
            let allowed = await fake.allowedOffers
            let denied = await fake.deniedOffers
            #expect(allowed == [offerID])
            #expect(denied == [offerID])
            #expect(state.phonePairingError == nil)
        }
    }

    @Test func aFailedAllowLeavesTheReasonForThePairingSheet() async {
        await withState { state in
            let pairing = PhonePairingStatus(
                offerID: UUID(), link: nil, expiresAt: Date(timeIntervalSince1970: 1_800_000_300),
                state: .awaitingApproval, confirmationCode: "123456", deviceName: "iPhone")
            let reason = "The pairing code expired. Start pairing again for a new code."
            let fake = FakePhoneClient(
                status: status(pairing: pairing),
                allowError: DaemonClientError.rpcError(reason, code: nil), pairing: pairing)
            state.phoneClient = fake
            await state.refreshPhone()
            await state.allowPhonePairing()
            #expect(state.phonePairingError == reason)
            // A new offer starts without the old offer's failure.
            let failure = await state.startPhonePairing()
            #expect(failure == nil)
            #expect(state.phonePairingError == nil)
        }
    }

    @Test func aFailedRevokeLeavesTheReasonForThePhonePane() async {
        await withState { state in
            let reason = "Couldn't confirm this request came from the TBD app"
            let paired = device("iPhone")
            let fake = FakePhoneClient(
                status: status(), devices: [paired], revokeError: DaemonClientError.rpcError(reason, code: nil))
            state.phoneClient = fake
            await state.refreshPhone()
            await state.revokePhone(deviceID: paired.id)
            #expect(state.phoneRevokeError == reason)
            #expect(state.phoneDevices == [paired])
        }
    }

    @Test func openPhoneSettingsSelectsThePhoneTab() async {
        await withState { state in
            var opened = 0
            state.settingsWindowOpener = { opened += 1 }
            state.openPhoneSettings(relaySetup: true)
            #expect(state.settingsTab == .phone)
            #expect(state.phoneRelaySetupRequested)
            #expect(opened == 1)
        }
    }

    @Test func chipPresentation() {
        #expect(PhoneChipPresentation.make(status: nil) == nil)
        #expect(PhoneChipPresentation.make(status: status(connected: [])) == nil)
        #expect(PhoneChipPresentation.make(status: status(connected: [UUID()]))?.title == "Phone connected")
        #expect(PhoneChipPresentation.make(status: status(connected: [UUID(), UUID()]))?.title
            == "2 phones connected")
    }
}
