import CryptoKit
import Foundation
import GRDB
import os
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

private let relayAddress = "https://acme-relay.acme.workers.dev"
private let otherRelayAddress = "https://other-relay.acme.workers.dev"
/// The loader URL the harness saves, because this build has no default.
private let loaderAddress = "https://acme-loader.github.io/"

/// What a TBD relay of this build answers `GET /v1/info` with.
private let currentRelay = PhoneRelayInfo(name: "tbd-relay", version: PhoneBridgeConstants.bundledRelayVersion,
                                          api: [PhoneBridgeConstants.relayAPIVersion])

/// The error code of an `app` reply, if it carries one.
private func errorCode(of reply: [String: Any]) -> String? {
    let body = reply["body"] as? [String: Any]
    let error = body?["error"] as? [String: Any]
    return error?["code"] as? String
}

/// A relay info client whose answer each test sets. It answers
/// `currentRelay` until told otherwise, and can hold its answers.
private actor FakeRelayInfo: RelayInfoFetching {
    private(set) var calls = 0
    private(set) var relays: [URL] = []
    private var reply: Result<PhoneRelayInfo, PhoneBridgeError> = .success(currentRelay)
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    /// How many calls wait on the hold.
    var heldCalls: Int {
        held.count
    }

    func answer(with info: PhoneRelayInfo) {
        reply = .success(info)
    }

    func fail(with error: PhoneBridgeError) {
        reply = .failure(error)
    }

    /// From now on, each call is counted and then waits until `release()`,
    /// when it answers with the reply set by then.
    func hold() {
        holding = true
    }

    /// Stops holding and lets every waiting call answer. Safe to call twice.
    func release() {
        holding = false
        let waiting = held
        held = []
        for call in waiting {
            call.resume()
        }
    }

    func info(relay: URL) async throws -> PhoneRelayInfo {
        calls += 1
        relays.append(relay)
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        return try reply.get()
    }
}

/// What the laptop key file holds when the bridge first reconciles.
private enum KeyFile {
    /// A valid key, made before the bridge starts.
    case present
    /// No file.
    case missing
    /// 32 bytes with mode 0644.
    case loose
}

/// A phone the harness paired by writing its row, with its key.
private struct PairedPhone: Sendable {
    let device: PhoneDevice
    let key: Curve25519.KeyAgreement.PrivateKey
}

/// A phone that paired through the bridge, and what it paired with.
private struct PairedByLink: Sendable {
    let phone: TestPhone
    let device: PhoneDevice
    let link: PairingLink
}

/// One bridge under test, with everything it talks to.
private struct PhoneBridgeHarness: Sendable {
    let db: TBDDatabase
    let keyPath: URL
    /// The laptop key's public half; nil unless the key file was made before
    /// the bridge started.
    let laptopPublicKey: Curve25519.KeyAgreement.PublicKey?
    let relay: FakeRelay
    /// The transport the bridge connects through, when the test asked for one
    /// that can hold the laptop's binary sends; nil means the bare relay.
    let holdingTransport: HoldingTransport?
    let info: FakeRelayInfo
    let app: RecordingPhoneApp
    /// Every delta the bridge broadcast, in order.
    let deltas: FireRecorder<StateDelta>
    let clock: EventDrivenTestClock
    let dates: TestDateSource
    let bridge: PhoneBridge
    /// The phones whose rows the harness wrote, in order.
    let phones: [PairedPhone]
    /// The main worktree of the one repository, when the harness made one.
    let mainWorktreeID: UUID?

    var rooms: Set<String> {
        Set(phones.map(\.device.roomID))
    }

    /// Waits until `condition` holds, or throws naming `what` and the
    /// bridge's status, the open rooms and the app's log as they stand. A
    /// condition that throws counts as not holding yet.
    func waitUntil(_ what: String, _ condition: () async throws -> Bool) async throws {
        let deadline = TestDeadlines.saturatedPass
        switch await pollUntilTrue(timeout: deadline, { (try? await condition()) ?? false }) {
        case .satisfied:
            return
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            let status = (try? await bridge.status()).map { "\($0)" } ?? "unreadable"
            let log = await app.log
            throw BoundedWaitTimeout(
                what: what, observed: "status \(status), open rooms \(relay.openLaptopRooms()), app log \(log)",
                deadline: deadline)
        }
    }

    func waitForPairingState(_ state: PhonePairingState) async throws {
        try await waitUntil("the pairing state \(state)") { try await bridge.status().pairing?.state == state }
    }

    /// The phone with the paired key, joined to its room once the laptop is
    /// there, after a handshake, `hello` and `welcome`.
    func connectedPhone(_ paired: PairedPhone) async throws -> TestPhone {
        let room = paired.device.roomID
        try await waitUntil("the laptop to open the room of \(paired.device.id)") { relay.laptopPresent(room: room) }
        let laptopKey = try #require(laptopPublicKey)
        return try await TestPhone.connected(relay: relay, room: room, key: paired.key, laptopKey: laptopKey)
    }

    /// Starts a pairing offer, parses its link, and waits until the laptop's
    /// socket is in the offer's room.
    func startPairing() async throws -> (offer: PhonePairingStatus, link: PairingLink) {
        let offer = try await bridge.pairStart()
        let text = try #require(offer.link)
        let url = try #require(URL(string: text))
        let link = try PairingLink.parse(url, now: dates.now)
        try await waitUntil("the laptop to join the pairing room") { relay.laptopPresent(room: link.room) }
        return (offer, link)
    }

    /// The laptop public key that a new pairing offer's link carries.
    func pairingLinkKey() async throws -> Data {
        let offer = try await bridge.pairStart()
        let text = try #require(offer.link)
        let url = try #require(URL(string: text))
        let link = try PairingLink.parse(url, now: dates.now)
        return try #require(Base64URL.decode(link.key))
    }

    /// A phone in the offer's room, with the relay's `peer-joined` read.
    func joinedPairingPhone(_ link: PairingLink) async throws -> TestPhone {
        try await TestPhone.joined(relay: relay, room: link.room)
    }

    /// Pairs a phone named `name` the way a person does: scan, `hello`, Allow.
    /// Returns once the phone has read `paired`.
    func pairAPhone(named name: String) async throws -> PairedByLink {
        let (offer, link) = try await startPairing()
        let phone = try await joinedPairingPhone(link)
        try await phone.pair(link: link, deviceName: name)
        try await waitForPairingState(.awaitingApproval)
        let device = try await bridge.pairAllow(offerID: offer.offerID)
        let message = try await phone.next()
        #expect(message["type"] as? String == "paired")
        #expect(message["room"] as? String == device.roomID)
        return PairedByLink(phone: phone, device: device, link: link)
    }

    /// Reconciles while the relay answers as something that is not a TBD
    /// relay, and returns once the reconcile's own check has answered and
    /// every link it started has been refused. So every check made so far
    /// has read that answer, and a reply set from here reaches only checks
    /// made later.
    func reconcileOnARefusedRelay() async throws {
        await info.fail(with: .notATBDRelay)
        await bridge.reconcile()
        await bridge.waitForRelayCheck()
        try await waitUntil("every link to stop on the refused relay") {
            let state = try await bridge.status().relay.state
            let links = await bridge.linkCount
            return state == .incompatible && links == 0
        }
    }

    /// How many `.phoneStatusChanged` deltas the bridge broadcast.
    var statusDeltaCount: Int {
        deltas.values.filter { delta in
            if case .phoneStatusChanged = delta { return true }
            return false
        }.count
    }

    /// The `notificationReceived` deltas the bridge broadcast.
    var notificationDeltas: [NotificationDelta] {
        deltas.values.compactMap { delta -> NotificationDelta? in
            if case .notificationReceived(let notice) = delta { return notice }
            return nil
        }
    }

    /// Adds a repository named `name` with a main worktree, after any added
    /// before it, and returns the main worktree's ID.
    func addRepository(_ name: String, hidden: Bool = false, status: RepoStatus = .ok) async throws -> UUID {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-phone-bridge-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name).path
        let repo = try await db.repos.create(path: path, displayName: name, defaultBranch: "main")
        if hidden {
            try await db.repos.setHidden(id: repo.id, hidden: true)
        }
        if status != .ok {
            try await db.repos.updateStatus(id: repo.id, status: status)
        }
        let main = try await db.worktrees.createMain(repoID: repo.id, name: name, branch: "main", path: path,
                                                     tmuxServer: "tbd-\(name)")
        return main.id
    }

    /// Lets everything the test held go, so `stop()` has nothing to wait on.
    func releaseHolds() async {
        holdingTransport?.release()
        await info.release()
    }
}

/// Builds a bridge on a fake relay, an in-memory database and a key file in a
/// temporary folder, runs `body`, and stops the bridge whatever happens, so
/// no task outlives the test.
///
/// - `enabled`: false leaves the "Phone control" setting unset (NULL).
/// - `devices`: how many paired phones' rows to write first.
/// - `installRecorder`: false leaves the bridge's stub app handler in place.
/// - `mainWorktree`: true adds one repository with a main worktree, where the
///   pairing notification goes.
/// - `holdSends`: true puts a ``HoldingTransport`` between the bridge and the
///   relay, as `holdingTransport`.
/// - `loaderURL`: the loader URL override to save; nil saves none, which
///   leaves no loader URL, since this build records no default.
/// - `bundleLoader`: how the bridge loads the phone app bundle; nil loads the
///   shipped one.
private func withBridge(enabled: Bool = true, relayURL: String? = relayAddress,
                        loaderURL: String? = loaderAddress, devices: Int = 0,
                        keyFile: KeyFile = .present, installRecorder: Bool = true, mainWorktree: Bool = false,
                        holdSends: Bool = false, bundleLoader: (@Sendable () throws -> PhoneAppBundle)? = nil,
                        _ body: (PhoneBridgeHarness) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-phone-bridge-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let keyPath = TBDConstants.phoneLaptopKeyPath(environment: ["TBD_HOME": root.path])
    var laptopPublicKey: Curve25519.KeyAgreement.PublicKey?
    switch keyFile {
    case .present:
        laptopPublicKey = try LaptopKeyStore(path: keyPath).loadOrCreate().publicKey
    case .missing:
        break
    case .loose:
        try FileManager.default.createDirectory(at: keyPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try PhoneTestVectors.randomBytes(LaptopKeyStore.keyByteCount).write(to: keyPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyPath.path)
    }

    let db = try TBDDatabase(inMemory: true)
    if enabled {
        try await db.config.setPhoneControlEnabled(true)
    }
    try await db.config.setPhoneRelayURL(relayURL)
    if let loaderURL {
        try await db.config.setPhoneLoaderURL(loaderURL)
    }
    let dates = TestDateSource()
    var phones: [PairedPhone] = []
    for index in 0..<devices {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let device = PhoneDevice(id: UUID(), name: "acme-phone-\(index)", publicKey: key.publicKey.rawRepresentation,
                                 roomID: try PhoneRoom.newToken(), pairedAt: dates.now.addingTimeInterval(-3_600))
        try await db.phoneDevices.insert(device)
        phones.append(PairedPhone(device: device, key: key))
    }
    var mainWorktreeID: UUID?
    if mainWorktree {
        let repo = try await db.repos.create(path: root.appendingPathComponent("acme").path, displayName: "acme",
                                             defaultBranch: "main")
        let main = try await db.worktrees.createMain(repoID: repo.id, name: "acme", branch: "main", path: repo.path,
                                                     tmuxServer: "tbd-acme")
        mainWorktreeID = main.id
    }

    let relay = FakeRelay()
    let holdingTransport = holdSends ? HoldingTransport(relay: relay) : nil
    let transport: any RelayTransport
    if let holdingTransport {
        transport = holdingTransport
    } else {
        transport = relay
    }
    let info = FakeRelayInfo()
    let app = RecordingPhoneApp()
    let deltas = FireRecorder<StateDelta>()
    let clock = EventDrivenTestClock()
    let bridge = PhoneBridge(
        db: db, keyStore: LaptopKeyStore(path: keyPath, now: dates.provider), transport: transport, infoClient: info,
        bundleLoader: bundleLoader ?? { try PhoneAppBundle.loadShipped() },
        laptopName: { "acme-laptop" }, broadcast: { deltas.record($0) }, now: dates.provider,
        backoff: PhoneBackoff(jitter: { $0 }), clock: clock)
    if installRecorder {
        await bridge.setAppHandler(app)
    }
    let harness = PhoneBridgeHarness(
        db: db, keyPath: keyPath, laptopPublicKey: laptopPublicKey, relay: relay,
        holdingTransport: holdingTransport, info: info, app: app, deltas: deltas, clock: clock, dates: dates,
        bridge: bridge, phones: phones, mainWorktreeID: mainWorktreeID)
    do {
        try await body(harness)
    } catch {
        await harness.releaseHolds()
        await bridge.stop()
        throw error
    }
    await harness.releaseHolds()
    await bridge.stop()
}

@Suite("PhoneBridge", .clockDriven)
struct PhoneBridgeTests {
    // MARK: Phone control off

    @Test func flagOffOpensNoSocketsAndRefusesPairing() async throws {
        try await withBridge(enabled: false, devices: 2) { h in
            await h.bridge.reconcile()
            await #expect(throws: PhoneBridgeError.disabled) { try await h.bridge.pairStart() }
            // A phone joining its own room finds no laptop there.
            let phone = try TestPhone(relay: h.relay, room: h.phones[0].device.roomID, key: h.phones[0].key)
            let signal = try await phone.nextSignal()
            #expect(signal == "peer-absent")
            #expect(h.relay.connectAttempts.isEmpty)
            let calls = await h.info.calls
            #expect(calls == 0)
            let log = await h.app.log
            #expect(log.isEmpty)
            let links = await h.bridge.linkCount
            #expect(links == 0)
            let status = try await h.bridge.status()
            #expect(status.enabled == false && status.running == false && status.problem == nil)
            // A defined state, never `unknown`, which means one a newer daemon
            // added: the relay has no answer, because nothing checks it.
            #expect(status.relay.state == .checking)
            let armed = await watchForSleeper(on: h.clock, upTo: .milliseconds(200))
            #expect(!armed)
        }
    }

    @Test func withNoLoaderURLPairingIsRefusedAndOpensNoRoom() async throws {
        try await withBridge(loaderURL: nil) { h in
            await h.bridge.reconcile()
            await #expect(throws: PhoneBridgeError.loaderNotSetUp) { try await h.bridge.pairStart() }
            let refused = try await h.bridge.status()
            #expect(refused.pairing == nil)
            #expect(refused.loaderURLOverride == nil)
            #expect(h.relay.connectAttempts.isEmpty)

            // Saving an override is all pairing needs.
            try await h.db.config.setPhoneLoaderURL(loaderAddress)
            let started = try await h.bridge.pairStart()
            let text = try #require(started.link)
            #expect(text.hasPrefix(loaderAddress + "#"))
            let paired = try await h.pairAPhone(named: "iPhone")
            let rowIDs = try await h.db.phoneDevices.list().map(\.id)
            #expect(rowIDs == [paired.device.id])
        }
    }

    @Test func flagOnWithoutARelayOpensNoSockets() async throws {
        try await withBridge(relayURL: nil, devices: 1) { h in
            await h.bridge.reconcile()
            await #expect(throws: PhoneBridgeError.relayNotSetUp) { try await h.bridge.pairStart() }
            #expect(h.relay.connectAttempts.isEmpty)
            let calls = await h.info.calls
            #expect(calls == 0)
            let status = try await h.bridge.status()
            #expect(status.enabled && status.running == false && status.relay.state == .notSetUp)
        }
    }

    // MARK: Phone control on

    @Test func flagOnChecksTheRelayThenOpensOneLinkPerDevice() async throws {
        try await withBridge(devices: 2) { h in
            await h.bridge.reconcile()
            let running = try await h.bridge.status()
            #expect(running.running && running.problem == nil)
            try await h.waitUntil("both device rooms to open") { h.relay.openLaptopRooms() == h.rooms }
            #expect(h.relay.connectAttempts.count == 2)
            // One check before each link's connect, beside the reconcile's own.
            let calls = await h.info.calls
            #expect(calls >= 2)
            let relays = await h.info.relays
            #expect(relays.allSatisfy { $0.absoluteString == relayAddress })
            try await h.waitUntil("the relay to show as connected") {
                try await h.bridge.status().relay.state == .connected
            }
            let status = try await h.bridge.status()
            #expect(status.relay.version == currentRelay.version)
            #expect(status.connectedDeviceIDs.isEmpty)
        }
    }

    @Test func aRelayWithoutAPI1IsRefusedAndShown() async throws {
        try await withBridge(devices: 2) { h in
            await h.info.answer(with: PhoneRelayInfo(name: "tbd-relay", version: "1.0.0", api: [2]))
            await h.bridge.reconcile()
            try await h.waitUntil("both links to stop on the refused relay") {
                let state = try await h.bridge.status().relay.state
                let links = await h.bridge.linkCount
                return state == .incompatible && links == 0
            }
            #expect(h.relay.connectAttempts.isEmpty)
            let status = try await h.bridge.status()
            #expect(status.relay.detail == PhoneBridgeError.unsupportedRelayAPI([2]).localizedDescription)
            await #expect(throws: PhoneBridgeError.unsupportedRelayAPI([2])) { try await h.bridge.pairStart() }
            #expect(h.relay.connectAttempts.isEmpty)

            // The relay is redeployed; saving its address reconciles again.
            await h.info.answer(with: currentRelay)
            await h.bridge.reconcile()
            try await h.waitUntil("both rooms to open on the fixed relay") { h.relay.openLaptopRooms() == h.rooms }
            try await h.waitUntil("the relay to show as connected") {
                try await h.bridge.status().relay.state == .connected
            }
        }
    }

    /// A 200 whose body is not a TBD relay's info object is refused as a
    /// wrong name is: the links stop rather than retry, pairing is refused,
    /// and a check that finds the relay usable, here a reconcile's, is what
    /// starts them.
    @Test func anAnswerFromSomethingThatIsNotATBDRelayIsRefusedAndShown() async throws {
        try await withBridge(devices: 2) { h in
            await h.info.fail(with: .notATBDRelay)
            await h.bridge.reconcile()
            try await h.waitUntil("both links to stop on the refused relay") {
                let state = try await h.bridge.status().relay.state
                let links = await h.bridge.linkCount
                return state == .incompatible && links == 0
            }
            #expect(h.relay.connectAttempts.isEmpty)
            let status = try await h.bridge.status()
            #expect(status.relay.detail == PhoneBridgeError.notATBDRelay.localizedDescription)
            await #expect(throws: PhoneBridgeError.notATBDRelay) { try await h.bridge.pairStart() }
            let pairing = try await h.bridge.status().pairing
            #expect(pairing == nil)
            #expect(h.relay.connectAttempts.isEmpty)

            // The address is fixed; saving it reconciles again.
            await h.info.answer(with: currentRelay)
            await h.bridge.reconcile()
            try await h.waitUntil("both rooms to open on the fixed relay") { h.relay.openLaptopRooms() == h.rooms }
            try await h.waitUntil("the relay to show as connected") {
                try await h.bridge.status().relay.state == .connected
            }
        }
    }

    @Test func aRecheckOfAnIncompatibleRelayKeepsRefusingPairingUntilItAnswers() async throws {
        try await withBridge { h in
            await h.info.answer(with: PhoneRelayInfo(name: "tbd-relay", version: "1.0.0", api: [2]))
            await h.bridge.reconcile()
            try await h.waitUntil("the relay to show as incompatible") {
                try await h.bridge.status().relay.state == .incompatible
            }

            // The relay is redeployed and its address saved again, so the
            // bridge checks it again; its answer is held, so the check stays
            // in flight.
            await h.info.answer(with: currentRelay)
            await h.info.hold()
            await h.bridge.reconcile()
            try await h.waitUntil("the re-check to wait on the relay") { await h.info.heldCalls == 1 }
            let checking = try await h.bridge.status()
            #expect(checking.relay.state == .checking)
            // Until the relay answers, it is still the one found unusable: no
            // offer, so no QR code that the relay would then interrupt.
            await #expect(throws: PhoneBridgeError.unsupportedRelayAPI([2])) { try await h.bridge.pairStart() }
            let pairing = try await h.bridge.status().pairing
            #expect(pairing == nil)

            // A usable answer clears the refusal.
            await h.info.release()
            try await h.waitUntil("the relay to show as connected") {
                try await h.bridge.status().relay.state == .connected
            }
            let offer = try await h.bridge.pairStart()
            #expect(offer.state == .waitingForPhone)
        }
    }

    /// One bad answer does not stop the phones for good. The bridge asks the
    /// refused relay again on its own, and once the relay answers as a TBD
    /// relay, the links start again with nothing saved.
    @Test func aRefusedRelayThatAnswersAgainComesBackAfterOneRecheck() async throws {
        try await withBridge(devices: 1) { h in
            try await h.reconcileOnARefusedRelay()
            #expect(h.relay.connectAttempts.isEmpty)

            // The relay answers as a TBD relay again, as after a redeploy.
            // The re-check's timer is the only sleeper.
            await h.info.answer(with: currentRelay)
            try await h.clock.requireAdvanceWhenArmed(by: PhoneBridgeConstants.refusedRelayRecheckInterval)
            let room = h.phones[0].device.roomID
            try await h.waitUntil("the room to open on the relay that answers again") {
                h.relay.laptopPresent(room: room)
            }
            try await h.waitUntil("the relay to show as connected") {
                try await h.bridge.status().relay.state == .connected
            }
            let offer = try await h.bridge.pairStart()
            #expect(offer.state == .waitingForPhone)
        }
    }

    @Test func aRelayThatStaysRefusedIsAskedAgainAndOpensNoLink() async throws {
        try await withBridge(devices: 1) { h in
            try await h.reconcileOnARefusedRelay()
            let before = await h.info.calls
            try await h.clock.requireAdvanceWhenArmed(by: PhoneBridgeConstants.refusedRelayRecheckInterval)
            try await h.waitUntil("the re-check to ask the relay") { await h.info.calls == before + 1 }

            // Still refused: the re-check waits for the next interval, and no
            // link starts.
            try await h.clock.requireSleeperArmed()
            let links = await h.bridge.linkCount
            #expect(links == 0)
            #expect(h.relay.connectAttempts.isEmpty)
            let status = try await h.bridge.status()
            #expect(status.relay.state == .incompatible)
            await #expect(throws: PhoneBridgeError.notATBDRelay) { try await h.bridge.pairStart() }
        }
    }

    /// A reconcile while the relay stands refused, such as a settings save's,
    /// starts no link; only a check that finds the relay usable does.
    @Test func aReconcileWhileTheRelayStandsRefusedOpensNoLink() async throws {
        try await withBridge(devices: 1) { h in
            try await h.reconcileOnARefusedRelay()

            // From here a check waits, so a link started again would stay in
            // place, waiting on its own check.
            await h.info.hold()
            await h.bridge.reconcile()
            let links = await h.bridge.linkCount
            #expect(links == 0)
            #expect(h.relay.connectAttempts.isEmpty)
            // The reconcile asks the relay itself; until it answers, the
            // refusal stands.
            try await h.waitUntil("the reconcile's check to wait on the relay") { await h.info.heldCalls == 1 }
            await #expect(throws: PhoneBridgeError.notATBDRelay) { try await h.bridge.pairStart() }
        }
    }

    @Test func savingARelayURLAsksTheRelayOnce() async throws {
        try await withBridge(relayURL: nil) { h in
            let url = try #require(URL(string: relayAddress))
            // The check `config.setPhoneRelayURL` makes before it saves.
            let info = try await h.bridge.checkRelay(url)
            try await h.db.config.setPhoneRelayURL(relayAddress)
            // From here a request would wait, and so show as one.
            await h.info.hold()
            await h.bridge.reconcile(afterSavingRelay: url, checkedAs: info)
            let status = try await h.bridge.status()
            #expect(status.running && status.relay.state == .connected)
            #expect(status.relay.version == currentRelay.version)
            let calls = await h.info.calls
            #expect(calls == 1)
            let held = await h.info.heldCalls
            #expect(held == 0)
        }
    }

    @Test func aSavedRelaysCheckIsNotTakenForAnother() async throws {
        try await withBridge { h in
            let other = try #require(URL(string: otherRelayAddress))
            let info = try await h.bridge.checkRelay(other)
            // `relayAddress` is the saved relay, so the bridge asks it itself.
            await h.info.hold()
            await h.bridge.reconcile(afterSavingRelay: other, checkedAs: info)
            try await h.waitUntil("the bridge to check the saved relay") { await h.info.heldCalls == 1 }
            let relays = await h.info.relays
            let checked = relays.map(\.absoluteString)
            #expect(checked == [otherRelayAddress, relayAddress])
            let status = try await h.bridge.status()
            #expect(status.relay.state == .checking)
        }
    }

    /// A check the bridge started is still out when the relay URL is saved
    /// again. The save's answer is the newer one, so the older check, which
    /// answers last, changes nothing: neither the status nor a refusal.
    @Test(arguments: [PhoneBridgeError.relayCheckFailed("HTTP 503"), .notATBDRelay])
    func aCheckThatBeganBeforeASaveCannotOverwriteTheSavesAnswer(failure: PhoneBridgeError) async throws {
        try await withBridge { h in
            // The first reconcile's own check waits on the relay.
            await h.info.hold()
            await h.bridge.reconcile()
            try await h.waitUntil("the reconcile's check to wait on the relay") { await h.info.heldCalls == 1 }

            // The relay URL is saved again; the save's check found it usable.
            let url = try #require(URL(string: relayAddress))
            await h.bridge.reconcile(afterSavingRelay: url, checkedAs: currentRelay)
            let seeded = try await h.bridge.status()
            #expect(seeded.relay.state == .connected)

            // The older check answers last, with a failure.
            await h.info.fail(with: failure)
            await h.info.release()
            await h.bridge.waitForRelayCheck()
            let after = try await h.bridge.status()
            #expect(after.relay.state == .connected)
            #expect(after.relay.detail == nil)
            // No refusal stands, so pairing starts.
            let offer = try await h.bridge.pairStart()
            #expect(offer.state == .waitingForPhone)
        }
    }

    @Test func aRefusedLinksSlowStopHoldsUpNoOtherLink() async throws {
        try await withBridge(devices: 2, holdSends: true) { h in
            let transport = try #require(h.holdingTransport)
            // However the test ends, nothing stays held.
            defer { transport.release() }
            await h.bridge.reconcile()
            let slow = h.phones[0]
            let other = h.phones[1]
            try await h.waitUntil("both rooms to open") { h.relay.openLaptopRooms() == h.rooms }
            _ = try await h.connectedPhone(slow)
            try await h.waitUntil("the first phone to show as connected") {
                try await h.bridge.status().connectedDeviceIDs == [slow.device.id]
            }

            // A frame for the first phone that cannot leave keeps its
            // connection's writer, and so its stop, waiting.
            transport.hold(room: slow.device.roomID)
            let latest = await h.app.lastOutbox
            let outbox = try #require(latest)
            let queued = await outbox.send(appBody: Data(#"{"note":"held"}"#.utf8))
            #expect(queued)
            try await h.waitUntil("the frame to reach the socket") { transport.heldSends == 1 }

            // The relay, redeployed without API 1, drops the first phone's
            // room socket. That link's next check refuses the relay, and its
            // connection's stop waits behind the held frame.
            await h.info.answer(with: PhoneRelayInfo(name: "tbd-relay", version: "1.0.0", api: [2]))
            h.relay.closeLaptop(room: slow.device.roomID, code: 1011)
            try await h.clock.advanceUntil("the first link to be refused", by: .seconds(1)) {
                await h.bridge.linkCount == 1
            }

            // The other phone's room socket stayed open, and its
            // connection's events still reach the status.
            _ = try await h.connectedPhone(other)
            try await h.waitUntil("the other phone to show as connected") {
                try await h.bridge.status().connectedDeviceIDs == [other.device.id]
            }
        }
    }

    /// A reconcile reads the paired phones before it waits on anything. A
    /// link the relay refuses while it waits, here on another link's stop,
    /// is not started again from that list.
    @Test func aLinkRefusedDuringAReconcileIsNotStartedAgainByIt() async throws {
        try await withBridge(devices: 2, holdSends: true) { h in
            let transport = try #require(h.holdingTransport)
            // However the test ends, nothing stays held.
            defer { transport.release() }
            await h.bridge.reconcile()
            let gone = h.phones[0]
            let refused = h.phones[1]
            try await h.waitUntil("both rooms to open") { h.relay.openLaptopRooms() == h.rooms }
            _ = try await h.connectedPhone(gone)
            try await h.waitUntil("the first phone to show as connected") {
                try await h.bridge.status().connectedDeviceIDs == [gone.device.id]
            }

            // A frame for the first phone that cannot leave keeps its
            // connection's stop waiting.
            transport.hold(room: gone.device.roomID)
            let latest = await h.app.lastOutbox
            let outbox = try #require(latest)
            let queued = await outbox.send(appBody: Data(#"{"note":"held"}"#.utf8))
            #expect(queued)
            try await h.waitUntil("the frame to reach the socket") { transport.heldSends == 1 }

            // The first phone's row goes, so the next reconcile stops its
            // link, and waits there.
            try await h.db.phoneDevices.delete(id: gone.device.id)
            let bridge = h.bridge
            let pass = Task { await bridge.reconcile() }
            try await h.waitUntil("the reconcile to stop the first link") { await bridge.linkCount == 1 }

            // Meanwhile the relay, redeployed without API 1, drops the other
            // phone's socket, and that link's next check refuses it.
            await h.info.answer(with: PhoneRelayInfo(name: "tbd-relay", version: "1.0.0", api: [2]))
            h.relay.closeLaptop(room: refused.device.roomID, code: 1011)
            try await h.clock.advanceUntil("the other link to be refused", by: .seconds(1)) {
                await bridge.linkCount == 0
            }

            // From here a check waits, so a link started again would stay
            // in place, waiting on it.
            await h.info.hold()
            transport.release()
            await pass.value
            let links = await bridge.linkCount
            #expect(links == 0)
            let held = await h.info.heldCalls
            #expect(held == 0)
            let status = try await bridge.status()
            #expect(status.relay.state == .incompatible)
        }
    }

    @Test func anUnreachableInfoBacksOffAndRetries() async throws {
        try await withBridge(devices: 1) { h in
            await h.info.fail(with: .relayCheckFailed("HTTP 503"))
            await h.bridge.reconcile()
            // The reconcile's own check and the link's first both fail; the
            // link backs off for 1 s.
            try await h.waitUntil("the relay to show as unreachable") {
                try await h.bridge.status().relay.state == .unreachable
            }
            let status = try await h.bridge.status()
            #expect(status.relay.detail == PhoneBridgeError.relayCheckFailed("HTTP 503").localizedDescription)
            try await h.waitUntil("the link's first check") { await h.info.calls >= 2 }
            try await h.clock.requireAdvanceWhenArmed(by: .seconds(1))
            try await h.waitUntil("the link's second check") { await h.info.calls >= 3 }
            // That check failed too; the next waits 2 s, and finds the relay.
            await h.info.answer(with: currentRelay)
            try await h.clock.requireAdvanceWhenArmed(by: .seconds(2))
            let room = h.phones[0].device.roomID
            try await h.waitUntil("the room to open") { h.relay.laptopPresent(room: room) }
            #expect(h.relay.connectAttempts.count == 1)
        }
    }

    @Test func theRelayIsNotShownAsConnectedWhileEveryRoomSocketIsDown() async throws {
        try await withBridge(devices: 1) { h in
            await h.bridge.reconcile()
            let room = h.phones[0].device.roomID
            try await h.waitUntil("the room to open") { h.relay.laptopPresent(room: room) }
            try await h.waitUntil("the relay to show as connected") {
                try await h.bridge.status().relay.state == .connected
            }

            // The relay drops the only room socket; the link backs off on the
            // test clock, so it stays down until the clock moves.
            h.relay.closeLaptop(room: room, code: 1011)
            try await h.waitUntil("the relay to show as connecting again") {
                try await h.bridge.status().relay.state == .checking
            }
            let down = try await h.bridge.status()
            #expect(down.running && down.relay.version == currentRelay.version)

            try await h.clock.advanceUntil("the room to open again", by: .seconds(1)) {
                h.relay.laptopPresent(room: room)
            }
            try await h.waitUntil("the relay to show as connected again") {
                try await h.bridge.status().relay.state == .connected
            }
        }
    }

    @Test func turningTheFlagOffClosesEverySocketWithoutRevoked() async throws {
        try await withBridge(devices: 1) { h in
            await h.bridge.reconcile()
            let paired = h.phones[0]
            let phone = try await h.connectedPhone(paired)
            try await h.waitUntil("the phone to show as connected") {
                try await h.bridge.status().connectedDeviceIDs == [paired.device.id]
            }
            try await h.db.config.setPhoneControlEnabled(false)
            await h.bridge.reconcile()
            #expect(h.relay.openLaptopRooms().isEmpty)
            let left = try await phone.nextSignal()
            #expect(left == "peer-left")
            try await h.waitUntil("the channel to end") { await h.app.log.contains("disconnected") }
            let log = await h.app.log
            #expect(log == ["connected", "disconnected"])
            // Message 2 and `welcome`, and nothing after them: no `revoked`.
            #expect(h.relay.laptopFrames(room: paired.device.roomID).count == 2)
            // The phone stays paired.
            let row = try await h.db.phoneDevices.device(id: paired.device.id)
            #expect(row?.id == paired.device.id)
            let status = try await h.bridge.status()
            #expect(status.running == false && status.connectedDeviceIDs.isEmpty)
        }
    }

    // MARK: Revoking

    @Test func revokeWhileConnectedSendsRevokedThenCloses() async throws {
        try await withBridge(devices: 1) { h in
            await h.bridge.reconcile()
            let paired = h.phones[0]
            let phone = try await h.connectedPhone(paired)
            try await h.waitUntil("the phone to show as connected") {
                try await h.bridge.status().connectedDeviceIDs == [paired.device.id]
            }
            try await h.bridge.revoke(deviceID: paired.device.id)
            let message = try await phone.next()
            #expect(message["type"] as? String == "revoked")
            let left = try await phone.nextSignal()
            #expect(left == "peer-left")
            let row = try await h.db.phoneDevices.device(id: paired.device.id)
            #expect(row == nil)
            let status = try await h.bridge.status()
            #expect(!status.connectedDeviceIDs.contains(paired.device.id))
            let links = await h.bridge.linkCount
            #expect(links == 0)
            #expect(h.relay.openLaptopRooms().isEmpty)
            let log = await h.app.log
            #expect(log == ["connected", "disconnected", "revoked:\(paired.device.id)"])
        }
    }

    @Test func revokeDeletesTheRowBeforeTheLinkIsTornDown() async throws {
        try await withBridge(devices: 1, holdSends: true) { h in
            let transport = try #require(h.holdingTransport)
            // However the test ends, nothing stays held.
            defer { transport.release() }
            await h.bridge.reconcile()
            let paired = h.phones[0]
            let deviceID = paired.device.id
            let phone = try await h.connectedPhone(paired)
            try await h.waitUntil("the phone to show as connected") {
                try await h.bridge.status().connectedDeviceIDs == [deviceID]
            }

            // `revoked` cannot leave, so the revoke waits inside the
            // connection, with the link still up, until the test releases
            // it: the flush limit is on the test clock, which never moves.
            transport.hold()
            let bridge = h.bridge
            let revoking = Task { try await bridge.revoke(deviceID: deviceID) }
            try await h.waitUntil("`revoked` to reach the socket") { transport.heldSends == 1 }
            #expect(h.relay.laptopPresent(room: paired.device.roomID))
            let row = try await h.db.phoneDevices.device(id: deviceID)
            #expect(row == nil)

            transport.release()
            try await revoking.value
            let message = try await phone.next()
            #expect(message["type"] as? String == "revoked")
            let links = await h.bridge.linkCount
            #expect(links == 0)
            let log = await h.app.log
            #expect(log == ["connected", "disconnected", "revoked:\(deviceID)"])
        }
    }

    /// A channel's calls never split across two handlers, `phoneRevoked`
    /// included: a phone connected under one handler is revoked on it after
    /// another is set, and a phone with no channel is revoked on the new one.
    @Test func revokeGoesToTheHandlerTheChannelKept() async throws {
        try await withBridge(devices: 2) { h in
            await h.bridge.reconcile()
            let onlinePhone = h.phones[0]
            let offlinePhone = h.phones[1]
            let phone = try await h.connectedPhone(onlinePhone)
            try await h.waitUntil("the phone to show as connected") {
                try await h.bridge.status().connectedDeviceIDs == [onlinePhone.device.id]
            }
            let later = RecordingPhoneApp()
            await h.bridge.setAppHandler(later)

            try await h.bridge.revoke(deviceID: onlinePhone.device.id)
            let message = try await phone.next()
            #expect(message["type"] as? String == "revoked")
            let first = await h.app.log
            #expect(first == ["connected", "disconnected", "revoked:\(onlinePhone.device.id)"])
            let laterFirst = await later.log
            #expect(laterFirst.isEmpty)

            try await h.bridge.revoke(deviceID: offlinePhone.device.id)
            let second = await h.app.log
            #expect(second == first)
            let laterSecond = await later.log
            #expect(laterSecond == ["revoked:\(offlinePhone.device.id)"])
        }
    }

    @Test func revokeWhileOfflineDeletesTheRow() async throws {
        try await withBridge(devices: 1) { h in
            await h.bridge.reconcile()
            let paired = h.phones[0]
            let room = paired.device.roomID
            try await h.waitUntil("the room to open") { h.relay.laptopPresent(room: room) }
            try await h.bridge.revoke(deviceID: paired.device.id)
            let row = try await h.db.phoneDevices.device(id: paired.device.id)
            #expect(row == nil)
            #expect(!h.relay.laptopPresent(room: room))
            #expect(h.relay.laptopFrames(room: room).isEmpty)
            let log = await h.app.log
            #expect(log == ["revoked:\(paired.device.id)"])
        }
    }

    @Test func revokeOfAnUnknownDeviceThrows() async throws {
        try await withBridge(devices: 1) { h in
            await h.bridge.reconcile()
            await #expect(throws: PhoneBridgeError.noSuchDevice) { try await h.bridge.revoke(deviceID: UUID()) }
            let rows = try await h.db.phoneDevices.list()
            #expect(rows == [h.phones[0].device])
            let log = await h.app.log
            #expect(log.isEmpty)
        }
    }

    // MARK: The app handler

    @Test func aHandlerSetLaterServesTheNextConnection() async throws {
        try await withBridge(devices: 1, installRecorder: false) { h in
            await h.bridge.reconcile()
            let paired = h.phones[0]
            let first = try await h.connectedPhone(paired)
            try await first.sendRequest("r1")
            let reply = try await first.next()
            #expect(reply["type"] as? String == "app")
            #expect(errorCode(of: reply) == "unavailable")
            first.close()

            await h.bridge.setAppHandler(h.app)
            let second = try await h.connectedPhone(paired)
            try await second.sendRequest("r2")
            try await h.waitUntil("r2 to reach the new handler") { await h.app.log.contains("message:r2") }
            let log = await h.app.log
            #expect(log == ["connected", "message:r2"])
        }
    }

    // MARK: Pairing

    @Test func endToEndPairThenLoadTheBundle() async throws {
        try await withBridge(installRecorder: false) { h in
            await h.bridge.reconcile()
            let paired = try await h.pairAPhone(named: "iPhone")
            let phone = paired.phone
            let room = paired.device.roomID
            let left = try await phone.nextSignal()
            #expect(left == "peer-left")
            try await h.waitUntil("the laptop to open only the new room") { h.relay.openLaptopRooms() == [room] }

            try await phone.rejoin(room: room)
            let joined = try await phone.nextSignal()
            #expect(joined == "peer-joined")
            let laptopKey = try #require(h.laptopPublicKey)
            try await phone.connectIK(room: room, laptopKey: laptopKey)
            try await phone.sendHello()
            let welcome = try await phone.next()
            #expect(welcome["type"] as? String == "welcome")
            let offered = try #require(welcome["bundle"] as? [String: Any])
            let sha = try #require(offered["sha256"] as? String)

            try await phone.send(json: ["type": "bundle.get", "sha256": sha])
            var chunks: [Data] = []
            var count = 1
            while chunks.count < count {
                let chunk = try await phone.next()
                try #require(chunk["type"] as? String == "bundle.chunk")
                count = try #require(chunk["count"] as? Int)
                let text = try #require(chunk["data"] as? String)
                let piece = try #require(Data(base64Encoded: text))
                chunks.append(piece)
            }
            let compressed = chunks.reduce(Data(), +)
            let inflated = try (compressed as NSData).decompressed(using: .zlib) as Data
            let shipped = try PhoneAppBundle.loadShipped()
            #expect(inflated == shipped.source)
            let digest = SHA256.hash(data: inflated).map { String(format: "%02x", $0) }.joined()
            #expect(digest == sha)

            try await phone.sendRequest("r1")
            let reply = try await phone.next()
            #expect(errorCode(of: reply) == "unavailable")
            try await h.waitUntil("the phone to show as connected") {
                try await h.bridge.status().connectedDeviceIDs == [paired.device.id]
            }
            let names = try await h.db.phoneDevices.list().map(\.name)
            #expect(names == ["iPhone"])
        }
    }

    @Test func thePairingRoomIsNeverListenedToAgain() async throws {
        try await withBridge { h in
            await h.bridge.reconcile()
            let paired = try await h.pairAPhone(named: "iPhone")
            let pairingRoom = paired.link.room
            let room = paired.device.roomID
            let relay = h.relay
            try await h.waitUntil("the laptop to open the phone's room") { relay.openLaptopRooms() == [room] }

            // The paired phone's own key, on the old pairing room, finds no
            // laptop there.
            let stranger = try TestPhone(relay: relay, room: pairingRoom, key: paired.phone.key)
            let absent = try await stranger.nextSignal()
            #expect(absent == "peer-absent")

            // However often the phone's link drops and comes back, it comes
            // back to the phone's room only.
            for _ in 0..<3 {
                relay.closeLaptop(room: room, code: 1011)
                try await h.clock.advanceUntil("the laptop to rejoin the phone's room", by: .seconds(1)) {
                    relay.laptopPresent(room: room)
                }
            }
            let attempts = relay.connectAttempts
            #expect(attempts.filter { $0.url.path.hasSuffix(pairingRoom) }.count == 1)
            #expect(attempts.filter { $0.url.path.hasSuffix(room) }.count == 4)
            #expect(!relay.laptopPresent(room: pairingRoom))
        }
    }

    @Test func aUsedCodeFindsNoLaptop() async throws {
        try await withBridge { h in
            await h.bridge.reconcile()
            let paired = try await h.pairAPhone(named: "iPhone")
            let left = try await paired.phone.nextSignal()
            #expect(left == "peer-left")
            let second = try TestPhone(relay: h.relay, room: paired.link.room)
            let signal = try await second.nextSignal()
            #expect(signal == "peer-absent")
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.count == 1)
        }
    }

    @Test func aCodeAfterDenyFindsNoLaptop() async throws {
        try await withBridge { h in
            await h.bridge.reconcile()
            let (offer, link) = try await h.startPairing()
            let phone = try await h.joinedPairingPhone(link)
            try await phone.pair(link: link, deviceName: "iPhone")
            try await h.waitForPairingState(.awaitingApproval)
            try await h.bridge.pairDeny(offerID: offer.offerID)
            try await h.waitUntil("the laptop to leave the pairing room") { !h.relay.laptopPresent(room: link.room) }
            let second = try TestPhone(relay: h.relay, room: link.room)
            let signal = try await second.nextSignal()
            #expect(signal == "peer-absent")
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
        }
    }

    // MARK: The pairing notification

    /// The app names the offer whose phone it showed. A replaced offer's ID,
    /// arriving after a newer offer's phone reached the prompt, is refused,
    /// and the newer offer is left as it was.
    @Test func anAllowOrDenyNamingAReplacedOfferIsRefused() async throws {
        try await withBridge { h in
            await h.bridge.reconcile()
            let (stale, _) = try await h.startPairing()
            let (live, link) = try await h.startPairing()
            #expect(stale.offerID != live.offerID)
            let phone = try await h.joinedPairingPhone(link)
            try await phone.pair(link: link, deviceName: "iPhone")
            try await h.waitForPairingState(.awaitingApproval)

            let bridge = h.bridge
            await #expect(throws: PhoneBridgeError.noSuchOffer) { try await bridge.pairAllow(offerID: stale.offerID) }
            await #expect(throws: PhoneBridgeError.noSuchOffer) { try await bridge.pairDeny(offerID: stale.offerID) }
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
            let pending = try await bridge.status().pairing
            #expect(pending?.offerID == live.offerID)
            #expect(pending?.state == .awaitingApproval)

            // The live offer still pairs.
            let device = try await bridge.pairAllow(offerID: live.offerID)
            #expect(device.name == "iPhone")
            let stored = try await h.db.phoneDevices.list().map(\.id)
            #expect(stored == [device.id])
        }
    }

    @Test func pairingPostsExactlyOneNotification() async throws {
        try await withBridge(mainWorktree: true) { h in
            await h.bridge.reconcile()
            let worktreeID = try #require(h.mainWorktreeID)
            _ = try await h.pairAPhone(named: "iPhone")
            let unread = try await h.db.notifications.unread(worktreeID: worktreeID)
            #expect(unread.count == 1)
            let notice = try #require(unread.first)
            #expect(notice.type == .attentionNeeded)
            #expect(notice.message
                == "Phone 'iPhone' was paired with this laptop. If this wasn't you, revoke it in Settings → Phone.")
            let deltas = h.notificationDeltas
            #expect(deltas.count == 1)
            #expect(deltas.first?.notificationID == notice.id && deltas.first?.worktreeID == worktreeID)
            #expect(deltas.first?.message == notice.message && deltas.first?.type == .attentionNeeded)
        }
    }

    @Test func denyPostsNoNotification() async throws {
        try await withBridge(mainWorktree: true) { h in
            await h.bridge.reconcile()
            let worktreeID = try #require(h.mainWorktreeID)
            let (offer, link) = try await h.startPairing()
            let phone = try await h.joinedPairingPhone(link)
            try await phone.pair(link: link, deviceName: "iPhone")
            try await h.waitForPairingState(.awaitingApproval)
            try await h.bridge.pairDeny(offerID: offer.offerID)
            try await h.waitForPairingState(.denied)
            let unread = try await h.db.notifications.unread(worktreeID: worktreeID)
            #expect(unread.isEmpty)
            #expect(h.notificationDeltas.isEmpty)
        }
    }

    @Test func expiryPostsNoNotification() async throws {
        try await withBridge(mainWorktree: true) { h in
            await h.bridge.reconcile()
            let worktreeID = try #require(h.mainWorktreeID)
            _ = try await h.startPairing()
            // The pairing room's keepalive and the offer's expiry.
            try await h.clock.requireSleepersArmed(count: 2)
            await h.clock.advance(by: .seconds(300))
            try await h.waitForPairingState(.expired)
            let unread = try await h.db.notifications.unread(worktreeID: worktreeID)
            #expect(unread.isEmpty)
            #expect(h.notificationDeltas.isEmpty)
        }
    }

    @Test func aPairingWhosePairedSendFailsPostsNoNotificationAndOpensNoRoom() async throws {
        try await withBridge(mainWorktree: true, holdSends: true) { h in
            let transport = try #require(h.holdingTransport)
            // However the test ends, nothing stays held.
            defer { transport.release() }
            let worktreeID = try #require(h.mainWorktreeID)
            await h.bridge.reconcile()
            let (offer, link) = try await h.startPairing()
            let phone = try await h.joinedPairingPhone(link)
            try await phone.pair(link: link, deviceName: "iPhone")
            try await h.waitForPairingState(.awaitingApproval)

            // `paired` is held at the socket and then fails there.
            transport.hold()
            let bridge = h.bridge
            let offerID = offer.offerID
            let allowing = Task { try await bridge.pairAllow(offerID: offerID) }
            try await h.waitUntil("`paired` to reach the socket") { transport.heldSends == 1 }
            transport.release(failing: true)
            await #expect(throws: PhoneBridgeError.pairingNotFinished) { try await allowing.value }

            // `onPaired` never ran: no row, no notification, no device room.
            try await h.waitForPairingState(.interrupted)
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
            let unread = try await h.db.notifications.unread(worktreeID: worktreeID)
            #expect(unread.isEmpty)
            #expect(h.notificationDeltas.isEmpty)
            let links = await h.bridge.linkCount
            #expect(links == 0)
        }
    }

    @Test func aLinkOpenedForTheRowOfAnUndoneAllowStops() async throws {
        try await withBridge(holdSends: true) { h in
            let transport = try #require(h.holdingTransport)
            // However the test ends, nothing stays held.
            defer { transport.release() }
            await h.bridge.reconcile()
            let (offer, link) = try await h.startPairing()
            let phone = try await h.joinedPairingPhone(link)
            try await phone.pair(link: link, deviceName: "iPhone")
            try await h.waitForPairingState(.awaitingApproval)

            // Allow stores the row, then waits on `paired`, which is held in
            // the pairing room only, so the device room can still open.
            transport.hold(room: link.room)
            let bridge = h.bridge
            let offerID = offer.offerID
            let allowing = Task { try await bridge.pairAllow(offerID: offerID) }
            try await h.waitUntil("`paired` to reach the socket") { transport.heldSends == 1 }

            // A reconcile now, such as a settings save's, lists the row Allow
            // stored and opens a link for it.
            await bridge.reconcile()
            let stored = try await h.db.phoneDevices.list()
            #expect(stored.count == 1)
            let opened = await bridge.linkCount
            #expect(opened == 1)

            // `paired` fails, so Allow deletes the row again; the link it
            // left must not outlive the row.
            transport.release(failing: true)
            await #expect(throws: PhoneBridgeError.pairingNotFinished) { try await allowing.value }
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
            // Allow returns only after the undo's reconcile.
            let links = await bridge.linkCount
            #expect(links == 0)
            let status = try await bridge.status()
            #expect(status.running && status.connectedDeviceIDs.isEmpty)
        }
    }

    /// Allow's own delete of an undone pairing's row fails. The undo's
    /// reconcile deletes the row again before it lists the phones, so the
    /// phone, which never heard `paired`, stays unpaired and gets no link.
    @Test func theUndoDeletesARowAllowCouldNotDeleteBeforeItOpensLinks() async throws {
        try await withBridge(holdSends: true) { h in
            let transport = try #require(h.holdingTransport)
            // However the test ends, nothing stays held.
            defer { transport.release() }
            await h.bridge.reconcile()
            let (offer, link) = try await h.startPairing()
            let phone = try await h.joinedPairingPhone(link)
            try await phone.pair(link: link, deviceName: "iPhone")
            try await h.waitForPairingState(.awaitingApproval)

            // The first delete of a phone's row fails; later ones succeed. A
            // function decides, because a trigger's own writes would roll
            // back with the delete it aborts.
            let deletes = OSAllocatedUnfairLock(initialState: 0)
            let failFirstDelete = DatabaseFunction("tbd_test_fail_first_phone_delete", argumentCount: 0) { _ in
                let first = deletes.withLock { calls in
                    calls += 1
                    return calls == 1
                }
                let fail: Int = first ? 1 : 0
                return fail
            }
            try await h.db.writerForTests.write { database in
                database.add(function: failFirstDelete)
                try database.execute(sql: """
                    CREATE TEMP TRIGGER induced_first_phone_device_delete_failure
                    BEFORE DELETE ON phone_device
                    WHEN tbd_test_fail_first_phone_delete()
                    BEGIN SELECT RAISE(ABORT, 'induced phone_device delete failure'); END
                    """)
            }

            // `paired` is held at the socket and then fails there, so Allow
            // undoes the pairing, and its delete is the one that fails.
            transport.hold()
            let bridge = h.bridge
            let offerID = offer.offerID
            let allowing = Task { try await bridge.pairAllow(offerID: offerID) }
            try await h.waitUntil("`paired` to reach the socket") { transport.heldSends == 1 }
            transport.release(failing: true)
            await #expect(throws: PhoneBridgeError.pairingNotFinished) { try await allowing.value }

            // Allow returns only after the undo's reconcile, which deleted
            // the row on the second try and so opened no link for it.
            let attempts = deletes.withLock { $0 }
            #expect(attempts == 2)
            let rows = try await h.db.phoneDevices.list()
            #expect(rows.isEmpty)
            let links = await bridge.linkCount
            #expect(links == 0)
        }
    }

    @Test func thePairingNotificationSkipsHiddenRepositoriesAndPrefersHealthyOnes() async throws {
        try await withBridge { h in
            // Listed in this order; each has a main worktree.
            _ = try await h.addRepository("acme-hidden", hidden: true)
            _ = try await h.addRepository("acme-missing", status: .missing)
            let healthy = try await h.addRepository("acme-healthy")
            await h.bridge.reconcile()
            _ = try await h.pairAPhone(named: "iPhone")
            let summary = try await h.db.notifications.unreadSummaryByWorktree()
            #expect(Array(summary.keys) == [healthy])
            let posted = h.notificationDeltas.map(\.worktreeID)
            #expect(posted == [healthy])
        }
    }

    @Test func withNoHealthyRepositoryThePairingNotificationFallsBackToAShownOne() async throws {
        try await withBridge { h in
            _ = try await h.addRepository("acme-hidden", hidden: true)
            let missing = try await h.addRepository("acme-missing", status: .missing)
            await h.bridge.reconcile()
            _ = try await h.pairAPhone(named: "iPhone")
            let summary = try await h.db.notifications.unreadSummaryByWorktree()
            #expect(Array(summary.keys) == [missing])
            let posted = h.notificationDeltas.map(\.worktreeID)
            #expect(posted == [missing])
        }
    }

    @Test func aPairingWithNoRepositoryPostsNothingAndAllowStillSucceeds() async throws {
        try await withBridge { h in
            await h.bridge.reconcile()
            let paired = try await h.pairAPhone(named: "iPhone")
            #expect(paired.device.name == "iPhone")
            let rowIDs = try await h.db.phoneDevices.list().map(\.id)
            #expect(rowIDs == [paired.device.id])
            let summary = try await h.db.notifications.unreadSummaryByWorktree()
            #expect(summary.isEmpty)
            #expect(h.notificationDeltas.isEmpty)
            // The bridge goes on to open the new phone's room.
            let room = paired.device.roomID
            try await h.waitUntil("the laptop to open the phone's room") { h.relay.laptopPresent(room: room) }
        }
    }

    @Test func anAllowThatLandsAfterStopStoresAndNotifiesButOpensNoLink() async throws {
        try await withBridge(mainWorktree: true, holdSends: true) { h in
            let transport = try #require(h.holdingTransport)
            // However the test ends, nothing stays held.
            defer { transport.release() }
            let worktreeID = try #require(h.mainWorktreeID)
            await h.bridge.reconcile()
            let (offer, link) = try await h.startPairing()
            let phone = try await h.joinedPairingPhone(link)
            try await phone.pair(link: link, deviceName: "iPhone")
            try await h.waitForPairingState(.awaitingApproval)

            // Allow stores the row, then waits for `paired` to leave, which
            // the transport holds: the flush limit is on the test clock,
            // which never moves.
            transport.hold()
            let bridge = h.bridge
            let offerID = offer.offerID
            let allowing = Task { try await bridge.pairAllow(offerID: offerID) }
            try await h.waitUntil("`paired` to reach the socket") { transport.heldSends == 1 }

            // TBD stops while that Allow is still in progress. The commit
            // cannot finish until the release below, so the Allow's
            // `onPaired` runs only after `stop()` has stopped everything
            // and is waiting for that commit.
            let stopping = Task { await bridge.stop() }
            try await h.waitUntil("the bridge to stop") { try await bridge.status().running == false }
            transport.release()
            let device = try await allowing.value
            await stopping.value

            let row = try await h.db.phoneDevices.device(id: device.id)
            #expect(row?.name == "iPhone")
            let unread = try await h.db.notifications.unread(worktreeID: worktreeID)
            #expect(unread.count == 1)
            let message = try #require(unread.first?.message)
            #expect(message == PhoneBridge.pairingNotice(deviceName: "iPhone"))
            #expect(h.notificationDeltas.count == 1)
            // The reconcile `onPaired` makes changes nothing after `stop()`.
            let links = await bridge.linkCount
            #expect(links == 0)
            let room = device.roomID
            let openedTheRoom = h.relay.connectAttempts.contains { $0.url.path.hasSuffix(room) }
            #expect(!openedTheRoom)
            let status = try await bridge.status()
            #expect(status.running == false)
        }
    }

    // MARK: Restarts and the key file

    @Test func changingTheRelayURLRestartsEveryLink() async throws {
        try await withBridge(devices: 2) { h in
            await h.bridge.reconcile()
            try await h.waitUntil("both rooms to open") { h.relay.openLaptopRooms() == h.rooms }
            try await h.db.config.setPhoneRelayURL(otherRelayAddress)
            await h.bridge.reconcile()
            try await h.waitUntil("both rooms to open on the new relay") {
                h.relay.connectAttempts.count == 4 && h.relay.openLaptopRooms() == h.rooms
            }
            let hosts = h.relay.connectAttempts.map { $0.url.host }
            #expect(hosts == ["acme-relay.acme.workers.dev", "acme-relay.acme.workers.dev",
                              "other-relay.acme.workers.dev", "other-relay.acme.workers.dev"])
            let checked = await h.info.relays
            #expect(checked.last?.absoluteString == otherRelayAddress)
        }
    }

    @Test func aBundleAPhoneWouldRefuseStopsTheBridgeWithAReason() async throws {
        // Compressed, any bundle is over a 1-byte limit.
        let oversized: @Sendable () throws -> PhoneAppBundle = {
            try PhoneAppBundle(source: Data("acme".utf8), maxCompressedBytes: 1)
        }
        try await withBridge(devices: 1, bundleLoader: oversized) { h in
            await h.bridge.reconcile()
            let status = try await h.bridge.status()
            #expect(status.running == false)
            let problem = try #require(status.problem)
            #expect(problem.hasPrefix("The phone app bundle is "))
            #expect(problem.hasSuffix(" a phone accepts, so TBD cannot serve it."))
            #expect(h.relay.connectAttempts.isEmpty)
            await #expect(throws: PhoneBridgeError.notRunning(problem)) { try await h.bridge.pairStart() }
        }
    }

    @Test func aLooseKeyFileStopsTheBridgeWithAReason() async throws {
        try await withBridge(devices: 1, keyFile: .loose) { h in
            await h.bridge.reconcile()
            let status = try await h.bridge.status()
            #expect(status.running == false)
            #expect(status.problem?.contains("0644") == true)
            #expect(h.relay.connectAttempts.isEmpty)
            let reason = LaptopKeyStoreError.permissionMismatch(mode: 0o644).localizedDescription
            await #expect(throws: PhoneBridgeError.notRunning(reason)) { try await h.bridge.pairStart() }
            // The file is left as it was.
            let attributes = try FileManager.default.attributesOfItem(atPath: h.keyPath.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        }
    }

    @Test func aKeyFileReplacedWhileRunningIsReadAfterTurningPhoneControlOffAndOn() async throws {
        try await withBridge { h in
            await h.bridge.reconcile()
            let first = try await h.pairingLinkKey()
            #expect(first == h.laptopPublicKey?.rawRepresentation)

            // The key file is replaced while the daemon runs.
            try FileManager.default.removeItem(at: h.keyPath)
            let replacement = try LaptopKeyStore(path: h.keyPath).loadOrCreate().publicKey.rawRepresentation
            #expect(replacement != first)

            try await h.db.config.setPhoneControlEnabled(false)
            await h.bridge.reconcile()
            try await h.db.config.setPhoneControlEnabled(true)
            await h.bridge.reconcile()
            let second = try await h.pairingLinkKey()
            #expect(second == replacement)
        }
    }

    @Test func aMissingKeyWithPairedPhonesIsNotRegenerated() async throws {
        try await withBridge(devices: 2, keyFile: .missing) { h in
            await h.bridge.reconcile()
            let status = try await h.bridge.status()
            #expect(status.running == false)
            #expect(status.problem?.contains("missing") == true)
            #expect(!FileManager.default.fileExists(atPath: h.keyPath.path))
            #expect(h.relay.connectAttempts.isEmpty)

            // Revoking works while the bridge is stopped. With a phone still
            // paired, the key is not made again.
            try await h.bridge.revoke(deviceID: h.phones[0].device.id)
            let halfway = try await h.bridge.status()
            #expect(halfway.running == false)
            #expect(halfway.problem?.contains("missing") == true)
            #expect(!FileManager.default.fileExists(atPath: h.keyPath.path))
            #expect(h.relay.connectAttempts.isEmpty)

            // With no phone left, a new key unpairs nobody: revoking the last
            // phone starts the bridge with one at once, and pairing works.
            try await h.bridge.revoke(deviceID: h.phones[1].device.id)
            let after = try await h.bridge.status()
            #expect(after.running && after.problem == nil)
            #expect(FileManager.default.fileExists(atPath: h.keyPath.path))
            let offer = try await h.bridge.pairStart()
            #expect(offer.state == .waitingForPhone)
        }
    }

    // MARK: Serialized reconciles

    /// A settings read that fails reaches the `phone.status` caller, so a
    /// failing database never shows phone control as off and not set up
    /// while the bridge runs.
    @Test func aSettingsReadThatFailsReachesTheStatusCaller() async throws {
        try await withBridge(devices: 1) { h in
            await h.bridge.reconcile()
            let running = try await h.bridge.status()
            #expect(running.enabled && running.running)
            try await h.db.writerForTests.write { conn in
                try conn.execute(sql: "DROP TABLE config")
            }
            let bridge = h.bridge
            await #expect(throws: (any Error).self) { _ = try await bridge.status() }
        }
    }

    @Test func concurrentReconcilesSettleOnTheLastConfig() async throws {
        try await withBridge(devices: 1) { h in
            let db = h.db
            let bridge = h.bridge
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<10 {
                    group.addTask {
                        try await db.config.setPhoneControlEnabled(index.isMultiple(of: 2))
                        await bridge.reconcile()
                    }
                }
                try await group.waitForAll()
            }
            try await h.db.config.setPhoneControlEnabled(false)
            await h.bridge.reconcile()
            #expect(h.relay.openLaptopRooms().isEmpty)
            let links = await h.bridge.linkCount
            #expect(links == 0)
            let status = try await h.bridge.status()
            #expect(status.running == false)
            // Nothing outlives the last reconcile: no link backs off or keeps
            // its socket alive.
            let armed = await watchForSleeper(on: h.clock, upTo: .milliseconds(200))
            #expect(!armed)

            try await h.db.config.setPhoneControlEnabled(true)
            await h.bridge.reconcile()
            let room = h.phones[0].device.roomID
            try await h.waitUntil("the room to open once") { h.relay.openLaptopRooms() == [room] }
            let restarted = await h.bridge.linkCount
            #expect(restarted == 1)
        }
    }

    // MARK: The status delta

    @Test func eachReconcileBroadcastsTheStatusOnce() async throws {
        try await withBridge { h in
            await h.bridge.reconcile()
            try await h.waitUntil("the relay to show as connected") {
                try await h.bridge.status().relay.state == .connected
            }

            // Turning phone control off: one delta.
            let beforeOff = h.statusDeltaCount
            try await h.db.config.setPhoneControlEnabled(false)
            await h.bridge.reconcile()
            #expect(h.statusDeltaCount == beforeOff + 1)

            // Turning it on again: one delta, which shows the new relay check
            // in flight. The check's answer is held, so nothing else lands.
            await h.info.hold()
            let beforeOn = h.statusDeltaCount
            try await h.db.config.setPhoneControlEnabled(true)
            await h.bridge.reconcile()
            try await h.waitUntil("the relay check to wait on the relay") { await h.info.heldCalls == 1 }
            #expect(h.statusDeltaCount == beforeOn + 1)
            let status = try await h.bridge.status()
            #expect(status.running && status.relay.state == .checking)

            // The answer is a change of its own, and broadcasts when it lands.
            await h.info.release()
            try await h.waitUntil("the relay to show as connected again") {
                try await h.bridge.status().relay.state == .connected
            }
            #expect(h.statusDeltaCount == beforeOn + 2)
        }
    }

    // MARK: Relay status

    struct RelayStatusCase: Sendable, CustomTestStringConvertible {
        let label: String
        var relayURL: String? = relayAddress
        let check: PhoneBridge.RelayCheck?
        var linksOpen = 0
        var linksFailing = 0
        var linksConnecting = 0
        let state: PhoneRelayState
        var version: String?
        var detail: String?

        var testDescription: String { label }
    }

    static let relayStatusCases: [RelayStatusCase] = [
        RelayStatusCase(label: "no relay", relayURL: nil, check: nil, state: .notSetUp),
        RelayStatusCase(label: "no relay over a stale answer", relayURL: nil, check: .ok(currentRelay), linksOpen: 1,
                        state: .notSetUp),
        RelayStatusCase(label: "not checked yet", check: nil, state: .checking),
        RelayStatusCase(label: "checking", check: .inFlight, state: .checking),
        RelayStatusCase(label: "check failed", check: .failed("timeout"), state: .unreachable, detail: "timeout"),
        RelayStatusCase(label: "incompatible", check: .incompatible("API [2]"), state: .incompatible,
                        detail: "API [2]"),
        RelayStatusCase(label: "older relay", check: .ok(PhoneRelayInfo(name: "tbd-relay", version: "0.9.0", api: [1])),
                        linksOpen: 1, state: .updateAvailable, version: "0.9.0"),
        RelayStatusCase(label: "no room socket opens", check: .ok(currentRelay), linksFailing: 2,
                        state: .unreachable, version: "1.0.0", detail: "cannot open a room socket"),
        RelayStatusCase(label: "one room socket opens", check: .ok(currentRelay), linksOpen: 1, linksFailing: 1,
                        state: .connected, version: "1.0.0"),
        RelayStatusCase(label: "every room socket connecting", check: .ok(currentRelay), linksConnecting: 2,
                        state: .checking, version: "1.0.0"),
        RelayStatusCase(label: "an older relay with every room socket connecting",
                        check: .ok(PhoneRelayInfo(name: "tbd-relay", version: "0.9.0", api: [1])), linksConnecting: 1,
                        state: .checking, version: "0.9.0"),
        RelayStatusCase(label: "one room socket open, one connecting", check: .ok(currentRelay), linksOpen: 1,
                        linksConnecting: 1, state: .connected, version: "1.0.0"),
        RelayStatusCase(label: "one room socket failing, one connecting", check: .ok(currentRelay), linksFailing: 1,
                        linksConnecting: 1, state: .unreachable, version: "1.0.0",
                        detail: "cannot open a room socket"),
        RelayStatusCase(label: "no phones", check: .ok(currentRelay), state: .connected, version: "1.0.0"),
        RelayStatusCase(label: "newer relay", check: .ok(PhoneRelayInfo(name: "tbd-relay", version: "1.1.0", api: [1])),
                        state: .connected, version: "1.1.0"),
        RelayStatusCase(label: "unreadable version", check: .ok(PhoneRelayInfo(name: "tbd-relay", version: "dev", api: [1])),
                        state: .connected, version: "dev"),
    ]

    @Test(arguments: PhoneBridgeTests.relayStatusCases)
    func relayStatusDerivation(_ c: RelayStatusCase) {
        let status = PhoneBridge.relayStatus(relayURL: c.relayURL, check: c.check, linksOpen: c.linksOpen,
                                             linksFailing: c.linksFailing, linksConnecting: c.linksConnecting)
        #expect(status.state == c.state)
        #expect(status.version == c.version)
        #expect(status.detail == c.detail)
        #expect(status.bundledVersion == PhoneBridgeConstants.bundledRelayVersion)
    }

    // MARK: The record

    /// Whether `event` names a phone the user allowed. The switch has no
    /// default, so a new event fails to compile here until someone decides
    /// whether it may carry a name.
    private static func namesAnAllowedPhone(_ event: PhoneBridgeLog.Event) -> Bool {
        switch event {
        case .allowed, .connected, .disconnected, .revoked:
            return true
        case .offerCreated, .handshakeAnswered, .attemptDropped, .handshakeCompleted, .denied, .expired,
             .interrupted, .pairingNoticeSkipped, .handshakeRefused, .channelEnded, .frameNotSent, .relayRefused,
             .started, .stopped, .failed:
            return false
        }
    }

    /// The name of `event`'s case. Every case is listed, with no default.
    private static func caseName(_ event: PhoneBridgeLog.Event) -> String {
        switch event {
        case .offerCreated: return "offerCreated"
        case .handshakeAnswered: return "handshakeAnswered"
        case .attemptDropped: return "attemptDropped"
        case .handshakeCompleted: return "handshakeCompleted"
        case .denied: return "denied"
        case .expired: return "expired"
        case .interrupted: return "interrupted"
        case .pairingNoticeSkipped: return "pairingNoticeSkipped"
        case .handshakeRefused: return "handshakeRefused"
        case .allowed: return "allowed"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .channelEnded: return "channelEnded"
        case .revoked: return "revoked"
        case .frameNotSent: return "frameNotSent"
        case .relayRefused: return "relayRefused"
        case .started: return "started"
        case .stopped: return "stopped"
        case .failed: return "failed"
        }
    }

    /// How many cases `caseName` lists. Raise it with the switch.
    private static let eventCaseCount = 19

    @Test func recordMessagesNeverCarrySecretsOrAnUnapprovedName() {
        let name = "iPhone"
        let id = UUID()
        // Each case, with every reason a fixed phrase as the callers pass
        // it. No case has a field for a secret, a link, key bytes, a code or
        // message content, so none can carry one.
        let events: [PhoneBridgeLog.Event] = [
            .offerCreated,
            .handshakeAnswered(deviceID: nil, replacing: false),
            .handshakeAnswered(deviceID: nil, replacing: true),
            .handshakeAnswered(deviceID: id, replacing: false),
            .handshakeAnswered(deviceID: id, replacing: true),
            .attemptDropped(reason: "no first message within the handshake timeout"),
            .handshakeCompleted,
            .denied,
            .expired,
            .interrupted(reason: "the phone left before Allow"),
            .pairingNoticeSkipped(reason: "no repository"),
            .pairingNoticeSkipped(reason: "no shown repository has a main worktree"),
            .handshakeRefused(reason: "the first message did not decrypt", deviceID: nil),
            .handshakeRefused(reason: "an unknown phone key", deviceID: id),
            .allowed(name: name, deviceID: id),
            .connected(name: name, deviceID: id),
            .disconnected(name: name, deviceID: id),
            .channelEnded(deviceID: id, reason: "a frame failed to decrypt; reopening the room socket"),
            .revoked(name: name, deviceID: id),
            .frameNotSent(deviceID: nil, detail: "the socket closed"),
            .frameNotSent(deviceID: id, detail: "the socket closed"),
            .relayRefused(reason: PhoneBridgeError.unsupportedRelayAPI([2]).localizedDescription),
            .started(devices: 2),
            .stopped(reason: "phone control is off"),
            .failed("Could not read the phone control settings"),
        ]
        let covered = Set(events.map { Self.caseName($0) })
        #expect(covered.count == Self.eventCaseCount)
        for event in events {
            let message = PhoneBridgeLog.message(event)
            #expect(!message.isEmpty)
            if Self.namesAnAllowedPhone(event) {
                #expect(message.contains(name) && message.contains(id.uuidString), "\(message)")
            } else {
                #expect(!message.contains(name), "\(message)")
            }
        }
        #expect(PhoneBridgeLog.message(.started(devices: 1)) == "Phone control started with 1 paired phone")
        #expect(PhoneBridgeLog.message(.pairingNoticeSkipped(reason: "no shown repository has a main worktree"))
            == "pairing notification skipped: no shown repository has a main worktree")
    }

    @Test func recordLevels() {
        let id = UUID()
        #expect(PhoneBridgeLog.level(.failed("x")) == .error)
        #expect(PhoneBridgeLog.level(.handshakeAnswered(deviceID: id, replacing: false)) == .debug)
        #expect(PhoneBridgeLog.level(.frameNotSent(deviceID: id, detail: "x")) == .debug)
        #expect(PhoneBridgeLog.level(.handshakeAnswered(deviceID: nil, replacing: false)) == .notice)
        #expect(PhoneBridgeLog.level(.frameNotSent(deviceID: nil, detail: "x")) == .notice)
        #expect(PhoneBridgeLog.level(.allowed(name: "iPhone", deviceID: id)) == .notice)
        #expect(PhoneBridgeLog.level(.revoked(name: "iPhone", deviceID: id)) == .notice)
    }
}
