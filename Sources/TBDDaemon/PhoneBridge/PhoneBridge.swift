import CryptoKit
import Foundation
import TBDShared

/// Why a phone bridge operation failed.
///
/// Each description is a sentence the Phone pane can show as it stands, so
/// it names the problem and, where there is one, the way out.
enum PhoneBridgeError: Error, Equatable, LocalizedError {
    /// The relay's `GET /v1/info` could not be read: the request failed, or
    /// the relay answered with a status other than 200. The text says which.
    case relayCheckFailed(String)
    /// The relay answered, but not as a TBD relay: its body is not the info
    /// object, or its `name` is not `tbd-relay`. The bridge refuses it.
    case notATBDRelay
    /// The relay is a TBD relay whose `api` list lacks the version this
    /// laptop speaks. The payload is the list it offered. The bridge refuses
    /// it.
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
    /// Allow stored the phone, but the message that tells it its room cannot
    /// have reached it, so the pairing was undone and the offer interrupted.
    case pairingNotFinished
    /// The pairing link built for a new offer is one the phone would refuse,
    /// almost always because the saved relay address is not in the form a
    /// pairing link carries. No offer was made.
    case invalidPairingLink
    /// The "Phone control" setting is off.
    case disabled
    /// No relay URL is saved.
    case relayNotSetUp
    /// No loader URL resolves: none is saved, and this build records no
    /// default loader. A pairing link must name the page the phone opens.
    case loaderNotSetUp
    /// Phone control is on and a relay is set, but the bridge is not running.
    /// The payload says why: the laptop key file or the app bundle cannot be
    /// used, or TBD is stopping.
    case notRunning(String)
    /// No `phone_device` row has that ID.
    case noSuchDevice

    /// Whether a relay check that throws this found a relay this laptop
    /// cannot use as it stands, so its links stop until a later check finds
    /// it usable, rather than one it could not read this time.
    var refusesTheRelay: Bool {
        switch self {
        case .notATBDRelay, .unsupportedRelayAPI:
            return true
        default:
            return false
        }
    }

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
        case .pairingNotFinished:
            return "The phone could not be told that pairing finished, so it was not paired. Start pairing again."
        case .invalidPairingLink:
            return "Couldn't make a pairing code a phone can read. Check the relay address in Settings → Phone: "
                + "it must be just an https:// address, such as https://acme-relay.acme.workers.dev."
        case .disabled:
            return "Phone control is off. Turn it on in Settings → Phone."
        case .relayNotSetUp:
            return "Set up a phone relay first."
        case .loaderNotSetUp:
            return "Set a loader URL in Settings → Phone → Advanced before pairing a phone."
        case .notRunning(let reason):
            return "Phone control is not running: \(reason)"
        case .noSuchDevice:
            return "No paired phone with that ID."
        }
    }
}

/// The phone bridge: phone control's one owner in the daemon
/// (`docs/specs/2026-11-07-phone-control-design.md`, section 5).
///
/// It runs only while the "Phone control" setting is on **and** a relay URL
/// is saved. Then it owns one ``PairingService`` and one ``PhoneConnection``
/// per paired phone, all on the saved relay. Otherwise it opens no socket,
/// and `pairStart` is refused.
///
/// **Serialized changes.** `reconcile()`, `revoke`, `pairStart` and `stop()`
/// run one at a time, in the order they were called: each waits for the one
/// before it to finish. So two RPCs that change the setting at once never
/// interleave a start with a stop, and whichever reconcile runs last acts on
/// the settings as they are by then. `pairAllow` and `pairDeny` are not in
/// that line, because Allow reconciles when it ends, paired or undone, and
/// so waits on it. `stop()` also takes effect the moment it is called: a
/// reconcile in progress, or one ahead of it in the line, ends at its next
/// check, after whatever it is waiting on, and starts nothing.
///
/// **Reconciling.**
/// 1. With phone control off or no relay set, everything stops.
/// 2. The paired phones are listed before the laptop key is loaded: with
///    phones paired, a missing key file is never created again, because a new
///    key would unpair every phone without a word. The key and the app bundle
///    are each loaded once; a failure is kept as `problem`, and the bridge
///    does not run until a later reconcile loads them. A halt or `stop()`
///    forgets the key, so the next start reads the file as it is then.
/// 3. A changed relay URL stops everything and starts again on the new one,
///    with a new pairing service and a fresh relay check.
/// 4. The relay is checked on its own when this address has no answer yet or
///    its last answer was a failure or a refusal, so the Phone pane has a
///    status with no phone paired, and saving the URL again checks a relay
///    that failed.
///    Saving the URL checks the relay before it saves it, so that reconcile
///    takes the save's answer as the check rather than ask again. Every link
///    checks it again before each connect. The newest answer stands: one
///    from a check that began before another check or the save, and lands
///    after its answer, changes nothing.
/// 5. Each paired phone without a link gets one, unless the relay stands
///    refused; each link whose phone is gone is stopped.
///
/// **The status delta.** Each `reconcile()` broadcasts `.phoneStatusChanged`
/// once, when it is done, whatever it did; nothing it does on the way
/// broadcasts one of its own. So the RPC handler that saves a setting and
/// reconciles sends none, and one toggle reaches the app as one delta. A
/// change that comes later, such as the relay check's answer, broadcasts
/// when it lands.
///
/// **A refused relay** (one whose answer is not a TBD relay's info object, or
/// that lacks API 1) stops each link it refuses, and pairing is refused. No
/// reconcile starts a link while the refusal stands, nor once the relay has
/// been refused since the reconcile began, so a link refused while it waits
/// is not started again from the list it read before. The refusal stands
/// until a check finds the relay usable: the one a save of the relay URL
/// makes, the one each reconcile makes while the relay is refused, or the
/// re-check the bridge runs on its own every `refusedRelayRecheckInterval`
/// on the injected clock, so one bad answer does not stop every phone for
/// good. The check that clears the refusal reconciles, and the links start
/// again. A refused connection stops in a task of its own, so its stop
/// never holds up another link's events; halting and `stop()` wait for it.
///
/// **Revoking** deletes the phone's row before anything else, so no later
/// handshake from that phone is accepted, whatever its link is doing. Then
/// `revoked` goes to the phone, if it is connected, and the link stops.
/// `phoneRevoked` goes last, to the handler the phone's channel kept when it
/// had one, else to the current one.
/// Turning phone control off and `stop()` never send `revoked`. A bridge
/// that a problem keeps from running reconciles after a revoke, in the same
/// line of changes: a key file missing while phones were paired is what
/// revoking every phone fixes, so the last revoke starts the bridge with a
/// new key.
///
/// **Every pairing raises a TBD notification** naming the phone, so a pairing
/// the user did not make is visible.
///
/// **An undone Allow** stored the phone's row and deleted it again, because
/// `paired` cannot have reached the phone. A reconcile in between listed the
/// row and opened a link for it, so the undo reconciles, and that link stops.
/// Before it lists the phones, that reconcile deletes the row once more, in
/// case Allow's own delete failed; were the row left, the phone, which never
/// heard `paired`, would stay paired and get a link. If that delete fails too,
/// the failure is logged and the row stays until the user revokes it.
///
/// `stop()` is immediate and final: no task or socket outlives it, and a
/// later `reconcile()`, such as the one a late Allow makes, changes nothing
/// but that delete.
actor PhoneBridge: PhoneBridgeControlling {
    /// The latest answer of the relay check (`GET /v1/info`).
    enum RelayCheck: Sendable, Equatable {
        case inFlight
        case ok(PhoneRelayInfo)
        /// The relay could not be read this time: the request failed, or the
        /// answer was not a 200 the laptop would read. The links back off and
        /// try again.
        case failed(String)
        /// The relay is not one this laptop can use: its answer is not a TBD
        /// relay's info object, or it lacks API 1. The links stop.
        case incompatible(String)
    }

    /// One paired phone's connection, and what its events last said.
    private struct Link {
        let connection: PhoneConnection
        /// Tells this connection's events from those of one it replaced.
        let token: UUID
        /// Whether its room socket is open (`true`), failing to open
        /// (`false`), or neither: connecting for the first time, or again
        /// after the socket closed.
        var isOpen: Bool?
        /// Whether the phone's channel is established.
        var isConnected = false
    }

    /// A relay check's answer from the save that just stored `url`.
    private struct RelaySeed: Sendable {
        let url: URL
        let info: PhoneRelayInfo
    }

    /// One event of one connection, in the order the connection emitted it.
    private struct LinkEvent: Sendable {
        let deviceID: UUID
        let token: UUID
        let event: PhoneConnection.Event
    }

    /// The running bridge's relay and what every link on it shares.
    private struct Running {
        let relayURL: URL
        let laptopKey: Curve25519.KeyAgreement.PrivateKey
        let laptopName: String
        let bundle: PhoneAppBundle
        let pairing: PairingService
    }

    private let db: TBDDatabase
    private let keyStore: LaptopKeyStore
    private let transport: any RelayTransport
    private let infoClient: any RelayInfoFetching
    private let bundleLoader: @Sendable () throws -> PhoneAppBundle
    private let currentLaptopName: @Sendable () -> String
    private let broadcast: @Sendable (StateDelta) -> Void
    private let now: @Sendable () -> Date
    private let backoff: PhoneBackoff
    private let clock: any Clock<Duration>
    /// The handler every connection reads when a channel becomes established.
    private let appSlot: PhoneAppHandlerSlot
    /// Every connection's events, handled one at a time by `pump`, so one
    /// connection's `connected` and `disconnected` are never seen out of
    /// order.
    private let linkEvents: AsyncStream<LinkEvent>
    private let linkEventSink: AsyncStream<LinkEvent>.Continuation

    /// Nil while the bridge is not running.
    private var running: Running?
    /// The paired phones' links, by device ID.
    private var links: [UUID: Link] = [:]
    private var check: RelayCheck?
    /// The error of the relay check's last `.incompatible` answer;
    /// `pairStart` throws it, and no reconcile starts a link while it
    /// stands. It stands while a re-check is in flight and when one fails,
    /// and clears only when the relay answers as usable or the bridge stops
    /// or moves to another relay, so no pairing slips through the window of
    /// a re-check.
    private var refusal: PhoneBridgeError?
    /// How many times the relay check has refused the relay. A reconcile
    /// reads it as it begins and starts no link once it has moved.
    private var relayRefusals: UInt64 = 0
    /// The number of the newest relay check started, or seed taken. Each
    /// check takes the next number as it starts, so the numbers rise in the
    /// order the checks began.
    private var checkSequence: UInt64 = 0
    /// The number of the newest check or seed whose answer stands. An answer
    /// from a check with a lower number began before that one and is stale.
    private var answeredSequence: UInt64 = 0
    /// The rows of undone Allows, which the next reconcile deletes again.
    private var undoneRows: Set<UUID> = []
    private var checkTask: Task<Void, Never>?
    /// While the relay stands refused, checks it again every
    /// `refusedRelayRecheckInterval`; nil otherwise.
    private var recheckTask: Task<Void, Never>?
    /// The re-checks that a check, a seed or a stop replaced, in line, so
    /// `stopEverything` waits for every one.
    private var endedRechecks: Task<Void, Never>?
    /// Why the bridge is not running although phone control is on and a
    /// relay is set.
    private var problem: String?
    /// The laptop key, read when the bridge last started; nil while it is
    /// not running, so a key file replaced or removed meanwhile is read anew.
    private var loadedKey: Curve25519.KeyAgreement.PrivateKey?
    private var loadedBundle: PhoneAppBundle?
    /// The last serialized change; the next one waits for it.
    private var tail: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    /// The stops of connections whose link the relay check refused, by an
    /// ID of their own. Each removes itself when done.
    private var refusedStops: [UUID: Task<Void, Never>] = [:]
    private var isStopped = false

    init(db: TBDDatabase, keyStore: LaptopKeyStore, transport: any RelayTransport,
         infoClient: any RelayInfoFetching,
         bundleLoader: @escaping @Sendable () throws -> PhoneAppBundle = { try PhoneAppBundle.loadShipped() },
         laptopName: @escaping @Sendable () -> String = { LaptopName.current() },
         broadcast: @escaping @Sendable (StateDelta) -> Void,
         now: @escaping @Sendable () -> Date = Date.init,
         backoff: PhoneBackoff = PhoneBackoff(), clock: any Clock<Duration> = ContinuousClock()) {
        self.db = db
        self.keyStore = keyStore
        self.transport = transport
        self.infoClient = infoClient
        self.bundleLoader = bundleLoader
        self.currentLaptopName = laptopName
        self.broadcast = broadcast
        self.now = now
        self.backoff = backoff
        self.clock = clock
        self.appSlot = PhoneAppHandlerSlot()
        let (stream, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
        self.linkEvents = stream
        self.linkEventSink = continuation
    }

    /// How many paired phones have a link. For tests and diagnostics.
    var linkCount: Int {
        links.count
    }

    /// Whether `stop()` has been called. For tests and diagnostics.
    var hasStopped: Bool {
        isStopped
    }

    /// Waits until the relay check a reconcile last started, and every one
    /// before it, has answered. For tests and diagnostics.
    func waitForRelayCheck() async {
        await checkTask?.value
    }

    // MARK: - PhoneBridgeControlling

    func reconcile() async {
        await serialized { await self.reconcileAndAnnounce() }
    }

    func reconcile(afterSavingRelay url: URL, checkedAs info: PhoneRelayInfo) async {
        // `info` is what `checkRelay` returned, which it returns only for a
        // relay `RelayCompatibility.check` found usable. The seed stands only
        // for `url`: `reconcileNow` takes it only while `url` is the saved
        // relay.
        let seed = RelaySeed(url: url, info: info)
        await serialized { await self.reconcileAndAnnounce(seed: seed) }
    }

    func checkRelay(_ url: URL) async throws -> PhoneRelayInfo {
        let info = try await infoClient.info(relay: url)
        try RelayCompatibility.check(info)
        return info
    }

    /// Throws when the saved settings cannot be read, as `phone.status` does
    /// with no bridge: a status made without them would show phone control
    /// off and not set up while it may be running.
    func status() async throws -> PhoneStatusResult {
        let config = try await db.config.get()
        let pairing = await running?.pairing.status
        // Everything below reads the bridge's state in one turn.
        let relayURL = config.phoneRelayURL
        // A stopped bridge checks nothing and runs no link, so its relay has
        // no answer: `checking`, which `running == false` qualifies. Never
        // `unknown`, which means a state a newer daemon added.
        let states = links.values.map(\.isOpen)
        let relay = Self.relayStatus(
            relayURL: relayURL, check: running == nil ? nil : check,
            linksOpen: states.filter { $0 == true }.count,
            linksFailing: states.filter { $0 == false }.count,
            linksConnecting: states.filter { $0 == nil }.count)
        let connected = links.filter { $0.value.isConnected }.map { $0.key }.sorted { $0.uuidString < $1.uuidString }
        return PhoneStatusResult(
            enabled: config.phoneControlEnabled,
            relayURL: relayURL, loaderURLOverride: config.phoneLoaderURL,
            running: running != nil, problem: problem, relay: relay,
            connectedDeviceIDs: connected, pairing: pairing)
    }

    /// Starts a pairing offer. Throws `.disabled` with phone control off,
    /// `.relayNotSetUp` with no relay, `.loaderNotSetUp` when no loader URL
    /// resolves, `.notRunning` when the bridge cannot run, and the relay
    /// check's error when the relay was last found not usable and no check
    /// has found it usable since. A refusal opens no pairing room.
    func pairStart() async throws -> PhonePairingStatus {
        try await serialized { await self.pairStartNow() }.get()
    }

    func pairAllow(offerID: UUID) async throws -> PhoneDevice {
        guard let pairing = running?.pairing else { throw PhoneBridgeError.noSuchOffer }
        return try await pairing.allow(offerID: offerID)
    }

    func pairDeny(offerID: UUID) async throws {
        guard let pairing = running?.pairing else { throw PhoneBridgeError.noSuchOffer }
        try await pairing.deny(offerID: offerID)
    }

    /// Unpairs a phone. Throws `.noSuchDevice` for an ID with no row. Works
    /// while the bridge is stopped, so a user whose key file is missing can
    /// revoke every phone and start again: while a problem keeps the bridge
    /// from running, each revoke reconciles, and the one that leaves no
    /// phone paired starts it.
    func revoke(deviceID: UUID) async throws {
        try await serialized { await self.revokeNow(deviceID) }.get()
    }

    // MARK: - The hand-off and stopping

    /// Sets the app layer's handler. A channel reads it when it becomes
    /// established, so it serves the channels established from now on, and
    /// the revokes of phones with no established channel.
    func setAppHandler(_ handler: any PhoneAppHandling) async {
        await appSlot.set(handler)
    }

    /// Stops every link and the pairing service, sending nothing, and waits
    /// for every task. Final: the bridge never runs again.
    ///
    /// It takes effect the moment it is called, ahead of the line of
    /// changes: from then on the bridge loads no key and starts no link,
    /// check or pairing room. A reconcile in progress ends at its next check,
    /// after whatever it is waiting on, and `stop()` waits for it, in the
    /// line, before it stops everything.
    func stop() async {
        isStopped = true
        loadedKey = nil
        await serialized { await self.stopEverything(reason: "TBD is stopping") }
        linkEventSink.finish()
        await pump?.value
        await finishRefusedStops()
    }

    // MARK: - The relay's status

    /// The relay's status for the Phone pane, from the saved relay URL, the
    /// relay check's latest answer, and how many links have their room
    /// socket open, are failing to open it, or are connecting it, for the
    /// first time or again. With no answer, as always while the bridge is
    /// stopped, the state is `checking`.
    ///
    /// A usable answer means `connected` only while a room socket is open or
    /// no phone is paired. With every link failing to open its socket, the
    /// relay is `unreachable`; with none open and some connecting, such as
    /// while the relay has dropped every socket and the links back off, it
    /// is `checking`, because each link checks the relay before it connects
    /// again.
    static func relayStatus(relayURL: String?, check: RelayCheck?, linksOpen: Int, linksFailing: Int,
                            linksConnecting: Int) -> PhoneRelayStatus {
        let bundled = PhoneBridgeConstants.bundledRelayVersion
        guard relayURL != nil else {
            return PhoneRelayStatus(state: .notSetUp, bundledVersion: bundled)
        }
        switch check {
        case .none, .some(.inFlight):
            return PhoneRelayStatus(state: .checking, bundledVersion: bundled)
        case .some(.failed(let detail)):
            return PhoneRelayStatus(state: .unreachable, bundledVersion: bundled, detail: detail)
        case .some(.incompatible(let detail)):
            return PhoneRelayStatus(state: .incompatible, bundledVersion: bundled, detail: detail)
        case .some(.ok(let info)):
            if linksOpen == 0 && linksFailing > 0 {
                return PhoneRelayStatus(state: .unreachable, version: info.version, bundledVersion: bundled,
                                        detail: "cannot open a room socket")
            }
            if linksOpen == 0 && linksConnecting > 0 {
                return PhoneRelayStatus(state: .checking, version: info.version, bundledVersion: bundled)
            }
            if PhoneRelayVersion.isOlder(info.version, than: bundled) == true {
                return PhoneRelayStatus(state: .updateAvailable, version: info.version, bundledVersion: bundled)
            }
            return PhoneRelayStatus(state: .connected, version: info.version, bundledVersion: bundled)
        }
    }

    /// The pairing notification's text.
    static func pairingNotice(deviceName: String) -> String {
        "Phone '\(deviceName)' was paired with this laptop. If this wasn't you, revoke it in Settings → Phone."
    }

    // MARK: - Serialized changes

    /// Runs `work` after every change called before it has finished, and
    /// returns its result. The work runs in a task of its own, so a caller
    /// that is cancelled does not cut it short.
    private func serialized<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        await enqueue(work).value
    }

    /// Puts `work` in the line of changes, after every change called before
    /// it, and returns its task without waiting for it.
    @discardableResult
    private func enqueue<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> Task<T, Never> {
        let previous = tail
        let task = Task<T, Never> {
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return task
    }

    /// Puts a reconcile in the line of changes without waiting for it. A
    /// check that finds a refused relay usable again calls this from outside
    /// the line, and must not wait on it: `stopEverything`, in the line,
    /// waits for that check. `stop()`, being in the line too, waits for the
    /// reconcile.
    private func enqueueReconcile() {
        guard !isStopped else { return }
        enqueue { await self.reconcileAndAnnounce() }
    }

    /// A reconcile, then its one status delta.
    private func reconcileAndAnnounce(seed: RelaySeed? = nil) async {
        await reconcileNow(seed: seed)
        broadcast(.phoneStatusChanged)
    }

    /// Brings the bridge in line with the saved settings. Broadcasts
    /// nothing: its caller sends the one delta once it is done. A `seed` for
    /// the saved relay stands as its check.
    private func reconcileNow(seed: RelaySeed? = nil) async {
        // `stop()` takes effect at once, outside the line of changes, so a
        // reconcile it overtakes checks after each await and ends there,
        // before it reads the key or starts anything.
        await removeUndoneRows()
        guard !isStopped else { return }
        startPump()
        let refusalsAtStart = relayRefusals
        let config: Config
        do {
            config = try await db.config.get()
        } catch {
            PhoneBridgeLog.record(.failed("Could not read the phone control settings: \(error.localizedDescription)"))
            return
        }
        guard !isStopped else { return }
        guard config.phoneControlEnabled else {
            await halt(reason: "phone control is off", problem: nil)
            return
        }
        guard let relayText = config.phoneRelayURL, let relayURL = URL(string: relayText) else {
            await halt(reason: "no relay is set up", problem: nil)
            return
        }
        // Listed before the key is loaded: with phones paired, a missing key
        // file is refused rather than created again.
        let devices: [PhoneDevice]
        do {
            devices = try await db.phoneDevices.list()
        } catch {
            guard !isStopped else { return }
            await halt(reason: "the paired phones could not be read",
                       problem: "TBD could not read the paired phones: \(error.localizedDescription)")
            return
        }
        guard !isStopped else { return }
        let key: Curve25519.KeyAgreement.PrivateKey
        if let loadedKey {
            key = loadedKey
        } else {
            do {
                key = try keyStore.loadOrCreate(createIfMissing: devices.isEmpty)
            } catch {
                await halt(reason: "the laptop key file cannot be used", problem: error.localizedDescription)
                return
            }
            loadedKey = key
        }
        let bundle: PhoneAppBundle
        if let loadedBundle {
            bundle = loadedBundle
        } else {
            do {
                bundle = try bundleLoader()
            } catch {
                await halt(reason: "the phone app bundle cannot be served", problem: error.localizedDescription)
                return
            }
            loadedBundle = bundle
        }
        problem = nil

        if let current = running, current.relayURL != relayURL {
            await stopEverything(reason: "the relay address changed")
            guard !isStopped else { return }
        }
        let current: Running
        if let running {
            current = running
        } else {
            let laptopName = currentLaptopName()
            current = Running(relayURL: relayURL, laptopKey: key, laptopName: laptopName, bundle: bundle,
                              pairing: makePairing(relayURL: relayURL, laptopKey: key, laptopName: laptopName))
            running = current
            PhoneBridgeLog.record(.started(devices: devices.count))
        }
        if let seed, seed.url.absoluteString == relayURL.absoluteString {
            // The save asked this relay a moment ago; asking again would only
            // repeat its answer. The seed takes a number of its own, so a
            // check that began before it and answers after it is stale. It
            // replaces any re-check of a refused relay.
            cancelRelayRecheck()
            setCheck(.ok(seed.info), for: relayURL, sequence: nextCheckSequence(), announce: false)
        } else if needsRelayCheck {
            startRelayCheck(relayURL)
        }

        let paired = Set(devices.map(\.id))
        let gone = links.filter { !paired.contains($0.key) }
        for deviceID in gone.keys {
            links[deviceID] = nil
        }
        await Self.stopAll(gone.values.map(\.connection))
        for device in devices where links[device.id] == nil {
            // No link starts while the relay stands refused; the check that
            // finds it usable again reconciles. And `devices` was read before
            // this pass's awaits: a link the relay refused meanwhile has left
            // `links`, and starting it from that list would undo the refusal.
            guard !isStopped, refusal == nil, relayRefusals == refusalsAtStart else { break }
            await startLink(for: device, in: current)
        }
    }

    private func pairStartNow() async -> Result<PhonePairingStatus, any Error> {
        do {
            let config = try await db.config.get()
            guard config.phoneControlEnabled else { throw PhoneBridgeError.disabled }
            guard let relayText = config.phoneRelayURL else { throw PhoneBridgeError.relayNotSetUp }
            // Checked before anything starts: with no loader, no link can
            // name the page the phone opens.
            guard let loaderText = config.resolvedPhoneLoaderURL else { throw PhoneBridgeError.loaderNotSetUp }
            if running?.relayURL.absoluteString != relayText {
                // Not started yet, or started on another relay.
                await reconcileAndAnnounce()
            }
            // A `stop()` that overtook this call while it waited opens no
            // pairing room.
            guard let current = running, !isStopped else {
                throw PhoneBridgeError.notRunning(problem ?? (isStopped ? "TBD is stopping." : "it has not started."))
            }
            if let refusal {
                throw refusal
            }
            let loaderURL = try PhoneURLValidation.loader(loaderText)
            return .success(try await current.pairing.start(loaderURL: loaderURL))
        } catch {
            return .failure(error)
        }
    }

    private func revokeNow(_ deviceID: UUID) async -> Result<Void, any Error> {
        do {
            guard let device = try await db.phoneDevices.device(id: deviceID) else {
                throw PhoneBridgeError.noSuchDevice
            }
            // The row goes first, before anything waits on the link: a
            // handler slow to return can never leave the phone paired.
            try await db.phoneDevices.delete(id: deviceID)
            // `phoneRevoked` goes to the handler that heard the channel's
            // `phoneDisconnected`, so one channel's calls never split across
            // two handlers; with no established channel, to the current one.
            let channelHandler = await links[deviceID]?.connection.revokeAndStop()
            links[deviceID] = nil
            let handler: any PhoneAppHandling
            if let channelHandler {
                handler = channelHandler
            } else {
                handler = await appSlot.current()
            }
            await handler.phoneRevoked(deviceID: deviceID)
            PhoneBridgeLog.record(.revoked(name: device.name, deviceID: deviceID))
            // The revoke may have removed what kept the bridge from running.
            if running == nil, problem != nil {
                await reconcileNow()
            }
            broadcast(.phoneStatusChanged)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Stops everything and keeps `problem` as the reason the bridge is not
    /// running. The reconcile that halts tells the app. The laptop key is
    /// forgotten, so the next start reads its file again.
    private func halt(reason: String, problem: String?) async {
        self.problem = problem
        if let problem {
            PhoneBridgeLog.record(.failed("Phone control cannot run: \(problem)"))
        }
        loadedKey = nil
        await stopEverything(reason: reason)
    }

    /// Stops the relay check, every link and the pairing service, sending
    /// nothing, and waits for them and for every refused link's stop. The
    /// next start checks the relay afresh, and every check begun before
    /// this is stale.
    private func stopEverything(reason: String) async {
        let checking = checkTask
        checkTask = nil
        checking?.cancel()
        cancelRelayRecheck()
        let rechecks = endedRechecks
        endedRechecks = nil
        check = nil
        refusal = nil
        answeredSequence = checkSequence
        let stopping = running
        running = nil
        let closing = links.values.map(\.connection)
        links = [:]
        await checking?.value
        await rechecks?.value
        await Self.stopAll(closing)
        await finishRefusedStops()
        await stopping?.pairing.cancel()
        if stopping != nil || !closing.isEmpty {
            PhoneBridgeLog.record(.stopped(reason: reason))
        }
    }

    private static func stopAll(_ connections: [PhoneConnection]) async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections {
                group.addTask { await connection.stop() }
            }
        }
    }

    // MARK: - Links and pairing

    private func startLink(for device: PhoneDevice, in current: Running) async {
        let token = UUID()
        let deviceID = device.id
        let sink = linkEventSink
        let connection = PhoneConnection(
            device: device, relayURL: current.relayURL, transport: transport, laptopKey: current.laptopKey,
            laptopName: current.laptopName, devices: db.phoneDevices, bundle: current.bundle, appSlot: appSlot,
            preflight: preflight(for: current.relayURL),
            onEvent: { event in sink.yield(LinkEvent(deviceID: deviceID, token: token, event: event)) },
            now: now, backoff: backoff, clock: clock)
        links[deviceID] = Link(connection: connection, token: token)
        await connection.start()
    }

    private func makePairing(relayURL: URL, laptopKey: Curve25519.KeyAgreement.PrivateKey,
                             laptopName: String) -> PairingService {
        let broadcast = self.broadcast
        return PairingService(
            relayURL: relayURL, transport: transport, laptopKey: laptopKey, laptopName: laptopName,
            devices: db.phoneDevices, preflight: preflight(for: relayURL),
            onChange: { broadcast(.phoneStatusChanged) },
            onPaired: { [weak self] device in await self?.paired(device) },
            onPairingUndone: { [weak self] deviceID in await self?.pairingUndone(deviceID: deviceID) },
            now: now, backoff: backoff, clock: clock)
    }

    /// A phone was stored after Allow. This can run after `stop()`, on the
    /// Allow caller's task: the notification still goes out, because the row
    /// exists, and the reconcile then changes nothing.
    private func paired(_ device: PhoneDevice) async {
        await postPairingNotice(for: device)
        await reconcile()
    }

    /// Allow tried to delete the row `deviceID` it stored. A reconcile that
    /// ran while the row existed opened a link for it; this one, in the line
    /// of changes, deletes the row again first, in case Allow's delete
    /// failed, then finds it gone and stops that link. Like `paired`, it can
    /// run after `stop()`, on the Allow caller's task, and then only deletes
    /// the row.
    private func pairingUndone(deviceID: UUID) async {
        undoneRows.insert(deviceID)
        await reconcile()
    }

    /// Deletes the rows of undone Allows again. Allow's own delete has
    /// usually removed the row already, and then this deletes nothing. A row
    /// this cannot delete either stays paired, so the failure is logged, and
    /// the user can revoke the phone in Settings.
    private func removeUndoneRows() async {
        let rows = undoneRows
        undoneRows = []
        for deviceID in rows {
            do {
                try await db.phoneDevices.delete(id: deviceID)
            } catch {
                PhoneBridgeLog.record(.failed(
                    "Could not remove phone \(deviceID), whose pairing did not finish; it stays paired until "
                        + "it is revoked in Settings: \(error.localizedDescription)"))
            }
        }
    }

    /// Posts `pairingNotice` as an `.attentionNeeded` TBD notification. A
    /// notification belongs to a worktree and a pairing has none, so it goes
    /// on a main worktree: hidden repositories are skipped, and healthy
    /// (`.ok`) ones come before the rest, each group in the order the
    /// database lists them. With no such worktree, nothing is posted.
    private func postPairingNotice(for device: PhoneDevice) async {
        do {
            let repos = try await db.repos.list()
            let shown = repos.filter { !$0.hidden }
            let candidates = shown.filter { $0.status == .ok } + shown.filter { $0.status != .ok }
            var target: UUID?
            for repo in candidates {
                if let main = try await db.worktrees.list(repoID: repo.id, status: .main).first {
                    target = main.id
                    break
                }
            }
            guard let worktreeID = target else {
                PhoneBridgeLog.record(.pairingNoticeSkipped(
                    reason: repos.isEmpty ? "no repository" : "no shown repository has a main worktree"))
                return
            }
            let notification = try await db.notifications.create(
                worktreeID: worktreeID, type: .attentionNeeded, message: Self.pairingNotice(deviceName: device.name))
            broadcast(.notificationReceived(NotificationDelta(
                notificationID: notification.id, worktreeID: notification.worktreeID,
                type: notification.type, message: notification.message,
                terminalID: notification.terminalID)))
        } catch {
            PhoneBridgeLog.record(.failed(
                "Could not post the pairing notification for phone \(device.id): \(error.localizedDescription)"))
        }
    }

    // MARK: - The relay check

    /// The check every link runs before each connect, pairing links included.
    private func preflight(for relayURL: URL) -> @Sendable () async -> RelayPreflight {
        { [weak self] in
            guard let self else { return .retryLater("phone control has stopped") }
            return await self.checkRelay(at: relayURL)
        }
    }

    /// Whether a reconcile checks the relay on its own: when it has not been
    /// checked on this address, or its last answer was a failure. A link that
    /// is running checks before every connect, but a reconcile with no link,
    /// such as the one saving the relay URL makes, must not show a stale
    /// failure.
    private var needsRelayCheck: Bool {
        switch check {
        case .none, .some(.failed), .some(.incompatible):
            return true
        case .some(.inFlight), .some(.ok):
            return false
        }
    }

    /// Checks the relay in a task of its own. The task first waits for the
    /// one it replaces, so awaiting `checkTask` awaits every check started.
    /// Only a reconcile starts one, and its own delta shows the check in
    /// flight; the answer broadcasts when it lands. It replaces any re-check
    /// of a refused relay.
    private func startRelayCheck(_ relayURL: URL) {
        if running?.relayURL == relayURL {
            check = .inFlight
        }
        cancelRelayRecheck()
        let previous = checkTask
        previous?.cancel()
        checkTask = Task {
            await previous?.value
            _ = await self.checkRelay(at: relayURL)
        }
    }

    /// Reads the relay's info and judges it, keeping the answer as `check`.
    /// An answer that is not a TBD relay's info object is a refusal, as a
    /// wrong `name` or a missing API is; a relay that could not be read this
    /// time is a failure the links retry.
    ///
    /// The check takes its number as it starts. When a check that began
    /// later, or a later seed, has answered first, this answer is stale: it
    /// changes nothing, and the link that asked acts on the answer that
    /// stands instead.
    ///
    /// An answer that clears a refusal puts a reconcile in line, which starts
    /// the links the refusal stopped.
    private func checkRelay(at relayURL: URL) async -> RelayPreflight {
        let sequence = nextCheckSequence()
        let answer: RelayCheck
        var newRefusal: PhoneBridgeError?
        do {
            let info = try await infoClient.info(relay: relayURL)
            try RelayCompatibility.check(info)
            answer = .ok(info)
        } catch is CancellationError {
            return .retryLater("the relay check was cancelled")
        } catch let error as PhoneBridgeError where error.refusesTheRelay {
            answer = .incompatible(error.localizedDescription)
            newRefusal = error
        } catch {
            answer = .failed(error.localizedDescription)
        }
        let wasRefused = refusal != nil
        guard setCheck(answer, for: relayURL, sequence: sequence, refusal: newRefusal) else {
            // Stale, or the bridge has stopped or moved to another relay. On
            // this relay the newer answer stands; otherwise the link is
            // stopping, and its own answer will do.
            if running?.relayURL == relayURL, let standing = check {
                return Self.verdict(of: standing)
            }
            return Self.verdict(of: answer)
        }
        if case .incompatible(let detail) = answer {
            PhoneBridgeLog.record(.relayRefused(reason: detail))
        }
        if wasRefused, refusal == nil {
            enqueueReconcile()
        }
        return Self.verdict(of: answer)
    }

    /// What a link does on the relay check's `answer`: connect, back off and
    /// try again, or stop.
    private static func verdict(of answer: RelayCheck) -> RelayPreflight {
        switch answer {
        case .ok:
            return .proceed
        case .inFlight:
            return .retryLater("the relay is being checked again")
        case .failed(let detail):
            return .retryLater(detail)
        case .incompatible(let detail):
            return .refuse(detail)
        }
    }

    /// A number for a relay check starting now, or a seed taken now.
    private func nextCheckSequence() -> UInt64 {
        checkSequence &+= 1
        return checkSequence
    }

    /// Keeps `answer`, from the check or seed numbered `sequence`, as the
    /// relay check, and returns whether it did. It does not when the bridge
    /// has stopped or moved to another relay since the check began, or when
    /// a check that began later, or a later seed, has answered already: that
    /// answer is newer, so this one is stale and changes nothing, refusal
    /// included.
    ///
    /// An `.incompatible` answer keeps `newRefusal` as the refusal, and arms
    /// the re-check that asks the relay again on its own; only an `.ok`
    /// answer clears it. One that failed leaves the refusal as it was: it
    /// says nothing about whether the relay is usable now.
    ///
    /// A changed answer broadcasts the status, unless `announce` is false
    /// because a reconcile in progress will.
    @discardableResult
    private func setCheck(_ answer: RelayCheck, for relayURL: URL, sequence: UInt64,
                          refusal newRefusal: PhoneBridgeError? = nil, announce: Bool = true) -> Bool {
        guard running?.relayURL == relayURL, sequence > answeredSequence else { return false }
        answeredSequence = sequence
        switch answer {
        case .ok:
            refusal = nil
        case .incompatible:
            refusal = newRefusal
            relayRefusals &+= 1
            armRelayRecheck(relayURL)
        case .inFlight, .failed:
            break
        }
        if check != answer {
            check = answer
            if announce {
                broadcast(.phoneStatusChanged)
            }
        }
        return true
    }

    // MARK: - Re-checking a refused relay

    /// Arms the re-check of the refused relay at `relayURL`, unless one is
    /// armed already: one bad answer, such as a TLS-inspecting proxy's or a
    /// relay's in the middle of a redeploy, must not stop every phone until
    /// the user saves the relay again. Every `refusedRelayRecheckInterval`
    /// on the injected clock the task asks the relay again, until an answer
    /// clears the refusal, which reconciles. `stop()`, a halt, and a
    /// reconcile that checks the relay itself or takes a save's answer end
    /// it.
    private func armRelayRecheck(_ relayURL: URL) {
        guard recheckTask == nil, !isStopped else { return }
        let clock = self.clock
        recheckTask = Task { [weak self] in
            while true {
                do {
                    try await clock.sleep(for: PhoneBridgeConstants.refusedRelayRecheckInterval)
                } catch {
                    return
                }
                guard let bridge = self, await bridge.recheckRefusedRelay(relayURL) else { return }
            }
        }
    }

    /// One re-check of the refused relay at `relayURL`, on the re-check's
    /// task. Returns whether to ask again later: the relay still stands
    /// refused, or could not be read this time.
    private func recheckRefusedRelay(_ relayURL: URL) async -> Bool {
        // A cancelled re-check was replaced, and its handle has gone with it.
        guard !Task.isCancelled else { return false }
        guard running?.relayURL == relayURL, refusal != nil else {
            recheckTask = nil
            return false
        }
        // An answer that clears the refusal reconciles from `checkRelay`.
        _ = await checkRelay(at: relayURL)
        guard !Task.isCancelled else { return false }
        guard refusal == nil else { return true }
        recheckTask = nil
        return false
    }

    /// Ends the re-check of a refused relay, if one is armed, in line behind
    /// any ended before it, so `stopEverything` can wait for all of them.
    private func cancelRelayRecheck() {
        guard let rechecking = recheckTask else { return }
        recheckTask = nil
        rechecking.cancel()
        let earlier = endedRechecks
        endedRechecks = Task {
            await earlier?.value
            await rechecking.value
        }
    }

    // MARK: - Link events

    private func startPump() {
        guard pump == nil, !isStopped else { return }
        pump = Task { await self.drainLinkEvents() }
    }

    /// Handles each event in one actor turn, awaiting nothing, so no
    /// connection can hold up the events of another.
    private func drainLinkEvents() async {
        for await item in linkEvents {
            handle(item)
        }
    }

    private func handle(_ item: LinkEvent) {
        // An event of a connection that is gone, or that another replaced,
        // says nothing about the current one.
        guard var link = links[item.deviceID], link.token == item.token else { return }
        let before = (link.isOpen, link.isConnected)
        switch item.event {
        case .linkOpened:
            link.isOpen = true
        case .linkClosed:
            link.isOpen = nil
        case .linkConnectFailed:
            link.isOpen = false
        case .connected:
            link.isConnected = true
        case .disconnected:
            link.isConnected = false
        case .handshakeRefused:
            // The connection has recorded it; the status does not change.
            return
        case .linkRefused:
            // The relay was refused, and the link has stopped for good. The
            // reconcile that follows the check clearing the refusal starts a
            // new one.
            links[item.deviceID] = nil
            broadcast(.phoneStatusChanged)
            stopRefused(link.connection)
            return
        }
        links[item.deviceID] = link
        if before != (link.isOpen, link.isConnected) {
            broadcast(.phoneStatusChanged)
        }
    }

    /// Stops a refused link's connection, so its writer task ends, in a task
    /// of its own: a stop that waits on a send still leaving must not keep
    /// the pump from the other links' events.
    private func stopRefused(_ connection: PhoneConnection) {
        let id = UUID()
        refusedStops[id] = Task { await self.runRefusedStop(id: id, connection) }
    }

    private func runRefusedStop(id: UUID, _ connection: PhoneConnection) async {
        await connection.stop()
        refusedStops[id] = nil
    }

    /// Waits until every refused link's stop has finished.
    private func finishRefusedStops() async {
        while let stopping = refusedStops.values.first {
            await stopping.value
        }
    }
}
