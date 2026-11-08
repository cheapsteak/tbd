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
    /// The "Phone control" setting is off.
    case disabled
    /// No relay URL is saved.
    case relayNotSetUp
    /// Phone control is on and a relay is set, but the bridge is not running.
    /// The payload says why: the laptop key file or the app bundle cannot be
    /// used, or TBD is stopping.
    case notRunning(String)
    /// No `phone_device` row has that ID.
    case noSuchDevice

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
        case .disabled:
            return "Phone control is off. Turn it on in Settings → Phone."
        case .relayNotSetUp:
            return "Set up a phone relay first."
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
/// that line, because Allow's `onPaired` reconciles, and so waits on it.
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
///    its last answer was a failure, so the Phone pane has a status with no
///    phone paired, and saving the URL again checks a relay that failed.
///    Saving the URL checks the relay before it saves it, so that reconcile
///    takes the save's answer as the check rather than ask again. Every link
///    checks it again before each connect.
/// 5. Each paired phone without a link gets one; each link whose phone is
///    gone is stopped.
///
/// **The status delta.** Each `reconcile()` broadcasts `.phoneStatusChanged`
/// once, when it is done, whatever it did; nothing it does on the way
/// broadcasts one of its own. So the RPC handler that saves a setting and
/// reconciles sends none, and one toggle reaches the app as one delta. A
/// change that comes later, such as the relay check's answer, broadcasts
/// when it lands.
///
/// **A refused relay** stops each link it refuses, for good; a later
/// reconcile starts them again. Saving the relay URL is how the user asks.
/// The refused connection stops in a task of its own, so its stop never
/// holds up another link's events; halting and `stop()` wait for it.
///
/// **Revoking** deletes the phone's row before anything else, so no later
/// handshake from that phone is accepted, whatever its link is doing. Then
/// `revoked` goes to the phone, if it is connected, and the link stops.
/// Turning phone control off and `stop()` never send `revoked`. A bridge
/// that a problem keeps from running reconciles after a revoke, in the same
/// line of changes: a key file missing while phones were paired is what
/// revoking every phone fixes, so the last revoke starts the bridge with a
/// new key.
///
/// **Every pairing raises a TBD notification** naming the phone, so a pairing
/// the user did not make is visible.
///
/// `stop()` is final: no task or socket outlives it, and a later
/// `reconcile()`, such as the one a late Allow's `onPaired` makes, changes
/// nothing.
actor PhoneBridge: PhoneBridgeControlling {
    /// The latest answer of the relay check (`GET /v1/info`).
    enum RelayCheck: Sendable, Equatable {
        case inFlight
        case ok(PhoneRelayInfo)
        /// The relay could not be reached, or did not answer with an info
        /// object. The links back off and try again.
        case failed(String)
        /// The relay is not one this laptop can use. The links stop.
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

    /// The handler `phoneRevoked` goes to: the one `setAppHandler` last set.
    private var handler: any PhoneAppHandling
    /// Nil while the bridge is not running.
    private var running: Running?
    /// The paired phones' links, by device ID.
    private var links: [UUID: Link] = [:]
    private var check: RelayCheck?
    /// The error of the relay check's last `.incompatible` answer;
    /// `pairStart` throws it. It stands while a re-check is in flight and
    /// when one fails, and clears only when the relay answers as usable or
    /// the bridge stops or moves to another relay, so no pairing slips
    /// through the window of a re-check.
    private var refusal: PhoneBridgeError?
    private var checkTask: Task<Void, Never>?
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
        let stub = UnavailablePhoneApp()
        self.handler = stub
        self.appSlot = PhoneAppHandlerSlot(stub)
        let (stream, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
        self.linkEvents = stream
        self.linkEventSink = continuation
    }

    /// How many paired phones have a link. For tests and diagnostics.
    var linkCount: Int {
        links.count
    }

    // MARK: - PhoneBridgeControlling

    func reconcile() async {
        await serialized { await self.reconcileAndAnnounce() }
    }

    func reconcile(afterSavingRelay url: URL, checkedAs info: PhoneRelayInfo) async {
        // Only an answer the bridge would itself take as usable stands in for
        // its check.
        let seed = (try? RelayCompatibility.check(info)) == nil ? nil : RelaySeed(url: url, info: info)
        await serialized { await self.reconcileAndAnnounce(seed: seed) }
    }

    func checkRelay(_ url: URL) async throws -> PhoneRelayInfo {
        let info = try await infoClient.info(relay: url)
        try RelayCompatibility.check(info)
        return info
    }

    func status() async -> PhoneStatusResult {
        let config = try? await db.config.get()
        let pairing = await running?.pairing.status
        // Everything below reads the bridge's state in one turn.
        let relayURL = config?.phoneRelayURL
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
            enabled: config?.phoneControlEnabled ?? Config.phoneControlEnabledDefault,
            relayURL: relayURL, loaderURLOverride: config?.phoneLoaderURL,
            running: running != nil, problem: problem, relay: relay,
            connectedDeviceIDs: connected, pairing: pairing)
    }

    /// Starts a pairing offer. Throws `.disabled` with phone control off,
    /// `.relayNotSetUp` with no relay, `.notRunning` when the bridge cannot
    /// run, and the relay check's error when the relay was last found not
    /// usable and no check has found it usable since.
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
    /// established, so it serves the channels established from now on.
    func setAppHandler(_ handler: any PhoneAppHandling) async {
        self.handler = handler
        await appSlot.set(handler)
    }

    /// Stops every link and the pairing service, sending nothing, and waits
    /// for every task. Final: the bridge never runs again.
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
        let previous = tail
        let task = Task<T, Never> {
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return await task.value
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
        guard !isStopped else { return }
        startPump()
        let config: Config
        do {
            config = try await db.config.get()
        } catch {
            PhoneBridgeLog.record(.failed("Could not read the phone control settings: \(error.localizedDescription)"))
            return
        }
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
            await halt(reason: "the paired phones could not be read",
                       problem: "TBD could not read the paired phones: \(error.localizedDescription)")
            return
        }
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
            // repeat its answer.
            setCheck(.ok(seed.info), for: relayURL, announce: false)
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
            await startLink(for: device, in: current)
        }
    }

    private func pairStartNow() async -> Result<PhonePairingStatus, any Error> {
        do {
            let config = try await db.config.get()
            guard config.phoneControlEnabled else { throw PhoneBridgeError.disabled }
            guard let relayText = config.phoneRelayURL else { throw PhoneBridgeError.relayNotSetUp }
            if running?.relayURL.absoluteString != relayText {
                // Not started yet, or started on another relay.
                await reconcileAndAnnounce()
            }
            guard let current = running else {
                throw PhoneBridgeError.notRunning(problem ?? (isStopped ? "TBD is stopping." : "it has not started."))
            }
            if let refusal {
                throw refusal
            }
            let loaderURL = try PhoneURLValidation.loader(config.resolvedPhoneLoaderURL)
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
            if let link = links[deviceID] {
                await link.connection.revokeAndStop()
            }
            links[deviceID] = nil
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
    /// next start checks the relay afresh.
    private func stopEverything(reason: String) async {
        let checking = checkTask
        checkTask = nil
        checking?.cancel()
        check = nil
        refusal = nil
        let stopping = running
        running = nil
        let closing = links.values.map(\.connection)
        links = [:]
        await checking?.value
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
            now: now, backoff: backoff, clock: clock)
    }

    /// A phone was stored after Allow. This can run after `stop()`, on the
    /// Allow caller's task: the notification still goes out, because the row
    /// exists, and the reconcile then changes nothing.
    private func paired(_ device: PhoneDevice) async {
        await postPairingNotice(for: device)
        await reconcile()
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
    /// flight; the answer broadcasts when it lands.
    private func startRelayCheck(_ relayURL: URL) {
        setCheck(.inFlight, for: relayURL, announce: false)
        let previous = checkTask
        previous?.cancel()
        checkTask = Task {
            await previous?.value
            _ = await self.checkRelay(at: relayURL)
        }
    }

    /// Reads the relay's info and judges it, keeping the answer as `check`.
    private func checkRelay(at relayURL: URL) async -> RelayPreflight {
        let info: PhoneRelayInfo
        do {
            info = try await infoClient.info(relay: relayURL)
        } catch is CancellationError {
            return .retryLater("the relay check was cancelled")
        } catch {
            let detail = error.localizedDescription
            setCheck(.failed(detail), for: relayURL)
            return .retryLater(detail)
        }
        do {
            try RelayCompatibility.check(info)
        } catch {
            let detail = error.localizedDescription
            setCheck(.incompatible(detail), for: relayURL, refusal: error as? PhoneBridgeError)
            PhoneBridgeLog.record(.relayRefused(reason: detail))
            return .refuse(detail)
        }
        setCheck(.ok(info), for: relayURL)
        return .proceed
    }

    /// Keeps `answer` as the relay check, unless the bridge has stopped or
    /// moved to another relay since the check began. An `.incompatible`
    /// answer keeps `newRefusal` as the refusal; only an `.ok` answer clears
    /// it. A check in flight, or one that failed, leaves the refusal as it
    /// was: it says nothing about whether the relay is usable now.
    ///
    /// A changed answer broadcasts the status, unless `announce` is false
    /// because a reconcile in progress will.
    private func setCheck(_ answer: RelayCheck, for relayURL: URL, refusal newRefusal: PhoneBridgeError? = nil,
                          announce: Bool = true) {
        guard running?.relayURL == relayURL else { return }
        switch answer {
        case .ok:
            refusal = nil
        case .incompatible:
            refusal = newRefusal
        case .inFlight, .failed:
            break
        }
        guard check != answer else { return }
        check = answer
        if announce {
            broadcast(.phoneStatusChanged)
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
            // The relay was refused, and the link has stopped for good. A
            // later reconcile starts it again.
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
