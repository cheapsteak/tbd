import Foundation
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

/// A `PhoneControlClient` that answers from fixed values and counts calls.
actor FakePhoneClient: PhoneControlClient {
    private(set) var status: PhoneStatusResult
    let devices: [PhoneDevice]
    let statusError: (any Error)?
    let relayURLError: (any Error)?
    let allowError: (any Error)?
    let revokeError: (any Error)?
    let pairing: PhonePairingStatus?
    /// How many `phone.status` calls, from the first, are refused as a
    /// daemon still recording the app's identity refuses them.
    let refusedStatusCalls: Int
    /// Whether `phone.status` waits, from its first call, until
    /// `releaseStatus()`.
    private var holdsStatus: Bool
    private var heldStatus: [CheckedContinuation<Void, Never>] = []
    private(set) var statusCalls = 0
    private(set) var relayURLs: [String?] = []
    private(set) var allowedOffers: [UUID] = []
    private(set) var deniedOffers: [UUID] = []

    init(
        status: PhoneStatusResult, devices: [PhoneDevice] = [], statusError: (any Error)? = nil,
        relayURLError: (any Error)? = nil, allowError: (any Error)? = nil, revokeError: (any Error)? = nil,
        pairing: PhonePairingStatus? = nil, refusedStatusCalls: Int = 0, holdsStatus: Bool = false
    ) {
        self.status = status
        self.devices = devices
        self.statusError = statusError
        self.relayURLError = relayURLError
        self.allowError = allowError
        self.revokeError = revokeError
        self.pairing = pairing
        self.refusedStatusCalls = refusedStatusCalls
        self.holdsStatus = holdsStatus
    }

    static let identityRefusal = "phone control is managed only from the TBD app"

    /// From now on, `phone.status` answers `newStatus`, as the daemon does
    /// once it has a new offer.
    func setStatus(_ newStatus: PhoneStatusResult) {
        status = newStatus
    }

    /// How many `phone.status` calls are waiting for `releaseStatus()`.
    var heldStatusCalls: Int { heldStatus.count }

    /// Lets every held `phone.status` call answer, and the later ones answer
    /// at once.
    func releaseStatus() {
        holdsStatus = false
        let held = heldStatus
        heldStatus = []
        for call in held { call.resume() }
    }

    func phoneStatus() async throws -> PhoneStatusResult {
        if holdsStatus {
            await withCheckedContinuation { heldStatus.append($0) }
        }
        statusCalls += 1
        if statusCalls <= refusedStatusCalls {
            throw DaemonClientError.rpcError(Self.identityRefusal, code: nil)
        }
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
    private func withState(
        phoneRetryClock: any Clock<Duration> = ContinuousClock(),
        _ body: (AppState) async throws -> Void
    ) async rethrows {
        let suite = TestDefaultsSuite("TBDAppTests.AppStatePhone")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        try await body(AppState(userDefaults: defaults, phoneRetryClock: phoneRetryClock))
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

    @Test(.clockDriven) func aRefusedConnectTimeStatusIsRetriedUntilItAnswers() async throws {
        let clock = EventDrivenTestClock()
        try await withState(phoneRetryClock: clock) { state in
            let expected = status(connected: [UUID()])
            let fake = FakePhoneClient(status: expected, refusedStatusCalls: 2)
            state.phoneClient = fake
            state.isConnected = true

            state.refreshPhoneAtConnect()
            let refresh = try #require(state.phoneConnectRefreshTask)
            // The retries arm on the main actor, so their guards take the
            // saturated-pass budget. The first retry arms once the first
            // read has been refused.
            try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
            #expect(state.phoneStatus == nil)
            #expect(state.phoneStatusError == FakePhoneClient.identityRefusal)

            let delays = AppState.phoneConnectRetryDelays
            try await clock.requireAdvanceWhenArmed(by: delays[0], timeout: TestDeadlines.saturatedPass)
            try await clock.requireAdvanceWhenArmed(by: delays[1], timeout: TestDeadlines.saturatedPass)
            // The third call answers, and the retries end there.
            await refresh.value
            #expect(state.phoneStatus == expected)
            #expect(state.phoneStatusError == nil)
            let calls = await fake.statusCalls
            #expect(calls == 3)
            #expect(!clock.hasSleeper)
        }
    }

    @Test(.clockDriven) func aDisconnectStopsTheConnectTimeRetries() async throws {
        let clock = EventDrivenTestClock()
        try await withState(phoneRetryClock: clock) { state in
            let fake = FakePhoneClient(status: status(), refusedStatusCalls: 10)
            state.phoneClient = fake
            state.isConnected = true

            state.refreshPhoneAtConnect()
            let refresh = try #require(state.phoneConnectRefreshTask)
            try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
            // The disconnect cancels the retry's sleep; nothing advances it.
            state.isConnected = false
            #expect(state.phoneConnectRefreshTask == nil)
            await refresh.value
            let calls = await fake.statusCalls
            #expect(calls == 1)
            #expect(!clock.hasSleeper)
            #expect(state.phoneStatus == nil)
        }
    }

    @Test func aConnectTimeStatusThatAnswersSchedulesNoRetry() async {
        let clock = EventDrivenTestClock()
        await withState(phoneRetryClock: clock) { state in
            let expected = status()
            let fake = FakePhoneClient(status: expected)
            state.phoneClient = fake
            state.isConnected = true
            state.refreshPhoneAtConnect()
            await state.phoneConnectRefreshTask?.value
            #expect(state.phoneStatus == expected)
            let calls = await fake.statusCalls
            #expect(calls == 1)
            #expect(!clock.hasSleeper)
        }
    }

    /// The phone status belongs to the daemon that answered it. Once the
    /// connection is lost, a "Phone connected" chip would show a phone the
    /// app can no longer see, so status, devices and chip all go.
    @Test func aLostConnectionForgetsThePhoneStatus() async {
        await withState { state in
            let paired = device("iPhone")
            state.phoneClient = FakePhoneClient(status: status(connected: [paired.id]), devices: [paired])
            state.isConnected = true
            await state.refreshPhone()
            #expect(PhoneChipPresentation.make(status: state.phoneStatus) != nil)
            #expect(state.phoneDevices == [paired])

            state.handleConnectionError(DaemonClientError.daemonNotRunning)
            #expect(!state.isConnected)
            #expect(state.phoneStatus == nil)
            #expect(state.phoneDevices.isEmpty)
            #expect(PhoneChipPresentation.make(status: state.phoneStatus) == nil)
        }
    }

    /// A read the old daemon answers after the connection is lost does not
    /// put its status back.
    @Test(.fastPassBounded) func aReadAnsweredAfterTheConnectionIsLostDoesNotLand() async {
        await withState { state in
            let fake = FakePhoneClient(status: status(connected: [UUID()]), holdsStatus: true)
            state.phoneClient = fake
            state.isConnected = true
            let reading = Task { await state.refreshPhone() }
            let held = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
                await fake.heldStatusCalls == 1
            }
            #expect(held == .satisfied)

            state.isConnected = false
            await fake.releaseStatus()
            await reading.value
            #expect(state.phoneStatus == nil)
            #expect(state.phoneDevices.isEmpty)
        }
    }

    /// The poll tick's plain reconnect reads the phone status again, and
    /// returns while that read is still waiting on the daemon.
    @Test(.fastPassBounded) func thePollTicksReconnectReadsThePhoneStatusWithoutWaitingForIt() async {
        await withState { state in
            let expected = status(connected: [UUID()])
            let fake = FakePhoneClient(status: expected, holdsStatus: true)
            state.phoneClient = fake
            state.isConnected = true

            await state.pollTickDidReconnect()
            let held = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
                await fake.heldStatusCalls == 1
            }
            #expect(held == .satisfied)
            #expect(state.phoneStatus == nil)

            await fake.releaseStatus()
            await state.phoneConnectRefreshTask?.value
            #expect(state.phoneStatus == expected)
        }
    }

    /// An answered subscription may come from a daemon that replaced the old
    /// one with no disconnect the app saw, so it reads the phone status again.
    @Test func anAnsweredSubscriptionReadsThePhoneStatus() async {
        await withState { state in
            let expected = status(connected: [UUID()])
            let fake = FakePhoneClient(status: expected)
            state.phoneClient = fake
            // `startSubscription` re-seeds program status and re-reports the
            // composer drafts; both are answered here, so the test sends no
            // RPC of its own for them.
            state.programStatusListFetcher = { @MainActor in [] }
            state.composerDraftsSetter = { _ in }
            let attempts = SubscribeAttempts(connectingFrom: 0)
            state.deltaSubscriber = { onConnected, _ in attempts.run(onConnected: onConnected) }

            state.startSubscription()
            let read = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
                await fake.statusCalls >= 1
            }
            #expect(read == .satisfied)
            await state.phoneConnectRefreshTask?.value
            #expect(state.phoneStatus == expected)
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

    @Test func allowAndDenyActOnTheOfferTheyAreGiven() async {
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
            await state.allowPhonePairing(offerID: offerID)
            await state.denyPhonePairing(offerID: offerID)
            let allowed = await fake.allowedOffers
            let denied = await fake.deniedOffers
            #expect(allowed == [offerID])
            #expect(denied == [offerID])
            #expect(state.phonePairingError == nil)
        }
    }

    /// The sheet showed offer A's phone; by the time its Deny or Allow runs,
    /// the daemon reports a newer offer B. The call still names A, so B, whose
    /// phone the user never saw, is neither denied nor allowed.
    @Test func aDenyOrAllowLandingAfterANewerOfferLeavesTheNewerOfferAlone() async {
        await withState { state in
            let expiry = Date(timeIntervalSince1970: 1_800_000_300)
            let shown = PhonePairingStatus(
                offerID: UUID(), link: nil, expiresAt: expiry, state: .awaitingApproval,
                confirmationCode: "123456", deviceName: "iPhone")
            let newer = PhonePairingStatus(
                offerID: UUID(), link: nil, expiresAt: expiry, state: .awaitingApproval,
                confirmationCode: "654321", deviceName: "acme-other-phone")
            let fake = FakePhoneClient(status: status(pairing: shown))
            state.phoneClient = fake
            await state.refreshPhone()
            #expect(state.phoneStatus?.pairing?.offerID == shown.offerID)

            // Offer B is published before the user's click lands.
            await fake.setStatus(status(pairing: newer))
            await state.refreshPhone()
            #expect(state.phoneStatus?.pairing?.offerID == newer.offerID)

            await state.denyPhonePairing(offerID: shown.offerID)
            await state.allowPhonePairing(offerID: shown.offerID)
            let denied = await fake.deniedOffers
            let allowed = await fake.allowedOffers
            #expect(denied == [shown.offerID])
            #expect(allowed == [shown.offerID])
            #expect(state.phoneStatus?.pairing == newer)
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
            await state.allowPhonePairing(offerID: pairing.offerID)
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
