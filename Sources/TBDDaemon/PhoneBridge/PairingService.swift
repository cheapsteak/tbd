import CryptoKit
import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

/// Pairing offers: the QR code's room, the `Noise_IKpsk2` responder, the
/// confirmation code, and Allow and Deny (spec section 2).
///
/// **An offer.** `start` mints a pairing room and a one-time secret with
/// `PhoneRoom.newToken()`, opens a ``RelayLink`` in that room, and arms an
/// expiry of `PhoneBridgeConstants.pairingOfferLifetime` on the injected
/// clock. There is at most one offer; a new `start` replaces a live one, and
/// the old offer's room is never listened to again.
///
/// **Before the phone is confirmed** (`waitingForPhone`). A binary frame is
/// tried as IKpsk2 message 1 with a fresh responder. One that cannot be read
/// (a stale frame, junk, or an IK message 1, whose protocol name differs) or
/// that names an unacceptable device is dropped: nothing is sent and the
/// offer keeps waiting. Otherwise the laptop answers with message 2 and keeps
/// the handshake as a private *attempt*, under a handshake timer of
/// `PhoneBridgeConstants.handshakeTimeout`. The PSK enters IKpsk2 only at
/// message 2, so a wrong secret shows up only here: the phone cannot read
/// message 2 and sends nothing, or its first message fails to decrypt.
/// - The attempt's first frame decrypts to a `hello`: the offer is
///   *consumed* and moves to `awaitingApproval`.
/// - It decrypts to anything else: the attempt is dropped.
/// - It fails to decrypt: the attempt is dropped and the same frame is tried
///   as a new message 1, so a phone retrying on the same socket is not lost.
/// - `peer-joined`, `peer-left`, a link `.closed`, or the handshake timer
///   drops the attempt.
///
/// A dropped attempt leaves the offer waiting until it expires.
///
/// **After the phone is confirmed** (`awaitingApproval`). `peer-joined`,
/// `peer-left`, a link `.closed`, or a frame that fails to decrypt
/// interrupts the offer. A frame that decrypts is ignored; decrypting keeps
/// the receive counter in step.
///
/// **Ending.**
/// - `allow` stores the phone with a fresh device room, which is never the
///   pairing room, tells the phone that room in `paired`, closes the pairing
///   room for good, and then calls `onPaired`.
/// - `deny`, expiry, an interruption, `cancel` and a replacing `start` close
///   the pairing room. Deny and expiry first send `pairDenied`, but only to a
///   confirmed phone, the only one with a channel to receive it.
///
/// Every frame the laptop sends leaves through one writer task, in order, and
/// a last message waits up to `PhoneBridgeConstants.flushLimit`.
///
/// **What the laptop keeps before Allow.** The phone's name, key and code
/// live only in memory. No `phone_device` row exists and no log record
/// carries the name, the secret, the link, the code or key bytes. The name
/// and the code are shown, through `status`, only from `awaitingApproval`
/// on, and only until the offer ends without a pairing.
///
/// No task or link of an offer outlives `cancel()`, `deny`, a replacing
/// `start`, or the expiry's own close.
actor PairingService {
    /// Why a frame did not start a pairing handshake. Fixed phrases; none
    /// quotes the frame.
    enum Refusal {
        /// Not an IKpsk2 message 1 for this offer's room, key and pattern: a
        /// stale frame, junk, or a message for another pattern.
        static let unreadable = "unreadable handshake message"
        /// Message 1's payload has no acceptable `deviceName`.
        static let badDeviceName = "unacceptable device name"
        static let unanswerable = "could not answer the handshake"
    }

    /// A handshake whose message 2 has gone out, waiting for the phone's
    /// first transport message.
    private struct Attempt {
        let id: UUID
        var transport: NoiseTransport
        let code: String
        let deviceName: String
        /// The phone's 32-byte X25519 public key.
        let phoneKey: Data
    }

    /// A phone whose `hello` decrypted, waiting for Allow or Deny.
    private struct Confirmed {
        var transport: NoiseTransport
        let code: String
        let deviceName: String
        let phoneKey: Data
    }

    private enum Phase {
        /// `waitingForPhone`, with the handshake waiting for its first
        /// transport message, if any.
        case waiting(Attempt?)
        /// `awaitingApproval`.
        case awaitingApproval(Confirmed)
        /// Allow has taken the offer and is storing the phone and telling it
        /// its room. Shown as `awaitingApproval`.
        case allowing(Confirmed)
        case paired(deviceName: String, deviceID: UUID, code: String)
        /// `denied`, `expired` or `interrupted`.
        case ended(PhonePairingState)
    }

    private struct Offer {
        let id: UUID
        let roomID: String
        let prologue: Data
        let psk: SymmetricKey
        /// The pairing link the QR code encodes.
        let link: String
        let expiresAt: Date
        var phase: Phase

        var status: PhonePairingStatus {
            switch phase {
            case .waiting:
                return PhonePairingStatus(offerID: id, link: link, expiresAt: expiresAt, state: .waitingForPhone)
            case .awaitingApproval(let confirmed), .allowing(let confirmed):
                return PhonePairingStatus(offerID: id, link: link, expiresAt: expiresAt, state: .awaitingApproval,
                                          confirmationCode: confirmed.code, deviceName: confirmed.deviceName)
            case .paired(let deviceName, let deviceID, let code):
                return PhonePairingStatus(offerID: id, link: nil, expiresAt: expiresAt, state: .paired,
                                          confirmationCode: code, deviceName: deviceName, deviceID: deviceID)
            case .ended(let state):
                return PhonePairingStatus(offerID: id, link: nil, expiresAt: expiresAt, state: state)
            }
        }
    }

    /// One frame for the writer.
    private struct Outgoing: Sendable {
        let frame: Data
        /// Called once the frame has left or failed to.
        let onLeft: (@Sendable () -> Void)?
    }

    /// The live offer's room socket and the tasks that serve it.
    private struct Session {
        let link: RelayLink
        let outbox: AsyncStream<Outgoing>.Continuation
        let inbound: Task<Void, Never>
        let writer: Task<Void, Never>
        let expiry: Task<Void, Never>
    }

    /// What Allow took when it claimed the offer.
    private struct Claim {
        let confirmed: Confirmed
        let deviceRoom: String
        /// `paired`, encrypted for the phone.
        let pairedFrame: Data
    }

    private let relayURL: URL
    private let transport: any RelayTransport
    private let laptopKey: Curve25519.KeyAgreement.PrivateKey
    /// The laptop's name in the link and in message 2, cut to fit.
    private let laptopName: String
    /// Handshake message 2's payload: `{"laptopName":…}`.
    private let message2Payload: Data
    private let devices: PhoneDeviceStore
    private let preflight: @Sendable () async -> RelayPreflight
    private let onChange: @Sendable () -> Void
    private let onPaired: @Sendable (PhoneDevice) async -> Void
    private let now: @Sendable () -> Date
    private let backoff: PhoneBackoff
    private let clock: any Clock<Duration>

    /// The offer `status` shows: live, or ended until the next `start` or
    /// `cancel`.
    private var offer: Offer?
    /// The live offer's socket and tasks; nil once it is closing or ended.
    private var session: Session?
    /// The timer of the offer's attempt. A fired timer stays here until the
    /// next attempt or the close, which wait for it.
    private var handshakeTimer: Task<Void, Never>?
    /// Tasks closing the sessions of ended offers, by ID. Each removes itself
    /// when done; `cancel` and `start` wait for all of them.
    private var closings: [UUID: Task<Void, Never>] = [:]
    /// The Allow that has claimed the offer. `cancel` and `start` wait for
    /// it, so it always finishes what it began.
    private var commit: (id: UUID, task: Task<PhoneDevice, any Error>)?

    init(relayURL: URL, transport: any RelayTransport, laptopKey: Curve25519.KeyAgreement.PrivateKey,
         laptopName: String, devices: PhoneDeviceStore,
         preflight: @escaping @Sendable () async -> RelayPreflight,
         onChange: @escaping @Sendable () -> Void,
         onPaired: @escaping @Sendable (PhoneDevice) async -> Void,
         now: @escaping @Sendable () -> Date = Date.init,
         backoff: PhoneBackoff = PhoneBackoff(), clock: any Clock<Duration> = ContinuousClock()) {
        self.relayURL = relayURL
        self.transport = transport
        self.laptopKey = laptopKey
        let name = LaptopName.limited(laptopName)
        self.laptopName = name
        self.message2Payload = Data(#"{"laptopName":\#(LoaderHandler.jsonString(name))}"#.utf8)
        self.devices = devices
        self.preflight = preflight
        self.onChange = onChange
        self.onPaired = onPaired
        self.now = now
        self.backoff = backoff
        self.clock = clock
    }

    /// The offer, live or ended; nil before the first `start` and after
    /// `cancel`.
    var status: PhonePairingStatus? {
        offer?.status
    }

    /// Whether a handshake has been answered with message 2 and waits for
    /// the phone's first transport message. `status` never shows it; this is
    /// for tests and diagnostics.
    var hasPendingHandshake: Bool {
        if case .waiting(.some) = offer?.phase { return true }
        return false
    }

    // MARK: - Offers

    /// Ends any offer, live or not, closing its room without a word to the
    /// phone, and starts a new one in a new room. Returns its status, the
    /// link included.
    func start(loaderURL: URL) async throws -> PhonePairingStatus {
        await discardOffer()
        // Nothing below suspends, so no other offer can begin meanwhile.
        let roomID = try PhoneRoom.newToken()
        let secret = try PhoneRoom.newToken()
        guard let roomBytes = PhoneRoom.roomBytes(roomID) else { throw NoiseError.invalidRoomID }
        guard let secretBytes = PhoneRoom.roomBytes(secret) else { throw NoiseError.invalidPSK }
        let prologue = try PhoneChannelPrologue.make(roomID: roomBytes)
        let expiresAt = now().addingTimeInterval(Self.seconds(PhoneBridgeConstants.pairingOfferLifetime))
        let link = PairingLink(
            v: PairingLink.currentVersion, relay: relayURL.absoluteString, room: roomID, secret: secret,
            key: Base64URL.encode(laptopKey.publicKey.rawRepresentation), name: laptopName,
            exp: Int(expiresAt.timeIntervalSince1970))
        let created = Offer(
            id: UUID(), roomID: roomID, prologue: prologue, psk: SymmetricKey(data: secretBytes),
            link: link.url(loaderURL: loaderURL).absoluteString, expiresAt: expiresAt, phase: .waiting(nil))
        offer = created
        session = openSession(offerID: created.id, roomID: roomID)
        logger.notice("Created a phone pairing offer")
        onChange()
        return created.status
    }

    /// The user allowed the confirmed phone: stores it with a fresh device
    /// room, sends it `paired` with that room, waits up to the flush limit,
    /// closes the pairing room for good, and calls `onPaired`, whose
    /// reconcile opens the device room.
    ///
    /// Throws `.notAwaitingApproval` while the offer still waits for a
    /// phone, `.offerExpired` once it has expired, and `.noSuchOffer` for any
    /// other offer that is not awaiting approval, including one that is not
    /// the current offer.
    func allow(offerID: UUID) async throws -> PhoneDevice {
        let claim = try claimApproval(offerID)
        let id = UUID()
        let task = Task { try await self.commitAllow(offerID: offerID, claim: claim) }
        commit = (id, task)
        let device: PhoneDevice
        do {
            device = try await task.value
        } catch {
            if commit?.id == id { commit = nil }
            throw error
        }
        if commit?.id == id { commit = nil }
        await onPaired(device)
        return device
    }

    /// The user denied the offer. A confirmed phone hears `pairDenied` with
    /// `denied` first, up to the flush limit. Returns once the room is
    /// closed.
    ///
    /// Throws `.offerExpired` once the offer has expired, and `.noSuchOffer`
    /// for any other offer that is not live.
    func deny(offerID: UUID) async throws {
        guard let current = offer, current.id == offerID else {
            throw PhoneBridgeError.noSuchOffer
        }
        let last: Data?
        switch current.phase {
        case .waiting:
            last = nil
        case .awaitingApproval(var confirmed):
            last = encrypt(LoaderHandler.pairDenied(.denied), with: &confirmed.transport)
        case .ended(.expired):
            throw PhoneBridgeError.offerExpired
        case .allowing, .paired, .ended:
            throw PhoneBridgeError.noSuchOffer
        }
        // A live offer always has its session; this only guards the invariant.
        guard let closing = end(as: .denied, sending: last) else {
            throw PhoneBridgeError.noSuchOffer
        }
        logger.notice("Phone pairing denied")
        await closing.value
    }

    /// Ends the offer, live or not, closing its room without a word to the
    /// phone, and waits until every task of every offer has finished. An
    /// Allow in progress finishes first. `status` is nil afterwards.
    func cancel() async {
        let hadOffer = offer != nil
        await discardOffer()
        if hadOffer {
            onChange()
        }
    }

    // MARK: - The room

    private func openSession(offerID: UUID, roomID: String) -> Session {
        let link = RelayLink(url: PhoneRoom.socketURL(relay: relayURL, roomID: roomID), transport: transport,
                             backoff: backoff, preflight: preflight, clock: clock)
        let (outbox, continuation) = AsyncStream.makeStream(of: Outgoing.self)
        let clock = self.clock
        let writer = Task { await Self.drain(outbox, to: link) }
        let inbound = Task { await self.serve(link, offerID: offerID) }
        let expiry = Task {
            do {
                try await clock.sleep(for: PhoneBridgeConstants.pairingOfferLifetime)
            } catch {
                return
            }
            await self.expire(offerID)
        }
        return Session(link: link, outbox: continuation, inbound: inbound, writer: writer, expiry: expiry)
    }

    /// Handles the link's events one at a time, in order.
    private func serve(_ link: RelayLink, offerID: UUID) async {
        await link.start()
        for await event in link.events {
            await handle(event, offerID: offerID)
        }
    }

    private func handle(_ event: RelayLinkEvent, offerID: UUID) async {
        guard let current = offer, current.id == offerID, session != nil else { return }
        switch event {
        case .opened, .connectFailed, .peerAbsent:
            return
        case .refused:
            // The link has stopped for good, so no phone can reach the offer.
            switch current.phase {
            case .waiting, .awaitingApproval:
                interrupt(because: "the relay was refused")
            case .allowing, .paired, .ended:
                return
            }
        case .peerJoined, .peerLeft, .closed:
            switch current.phase {
            case .waiting(.some):
                await dropAttempt(because: "the phone's socket changed")
            case .awaitingApproval:
                interrupt(because: "the phone's socket changed")
            case .waiting(.none), .allowing, .paired, .ended:
                return
            }
        case .frame(let bytes):
            await receiveFrame(bytes, offerID: offerID)
        }
    }

    private func receiveFrame(_ frame: Data, offerID: UUID) async {
        guard let current = offer, current.id == offerID, session != nil else { return }
        switch current.phase {
        case .waiting(.some(let pending)):
            var attempt = pending
            if let plaintext = try? attempt.transport.decrypt(frame) {
                if Self.isHello(plaintext) {
                    await confirm(attempt)
                } else {
                    await dropAttempt(because: "the first message was not hello")
                }
                return
            }
            await dropAttempt(because: "the first message failed to decrypt")
            // Dropping waited for the attempt's timer, so read the offer again.
            guard let after = offer, after.id == offerID, session != nil, case .waiting(.none) = after.phase else {
                return
            }
            answerMessage1(frame, offer: after)
        case .waiting(.none):
            answerMessage1(frame, offer: current)
        case .awaitingApproval(var confirmed):
            if (try? confirmed.transport.decrypt(frame)) != nil {
                offer?.phase = .awaitingApproval(confirmed)
            } else {
                interrupt(because: "a frame failed to decrypt")
            }
        case .allowing, .paired, .ended:
            return
        }
    }

    /// Tries `frame` as IKpsk2 message 1 for `current` and, when it reads and
    /// names an acceptable device, answers with message 2 and keeps the
    /// handshake as the offer's attempt.
    private func answerMessage1(_ frame: Data, offer current: Offer) {
        guard let outbox = session?.outbox else { return }
        var responder: NoiseResponder
        let read: (remoteStatic: Curve25519.KeyAgreement.PublicKey, payload: Data)
        do {
            responder = try NoiseResponder(pattern: .ikpsk2, staticKey: laptopKey, psk: current.psk,
                                           prologue: current.prologue)
            read = try responder.readMessage1(frame)
        } catch {
            refuse(Refusal.unreadable)
            return
        }
        // Message 1 can be replayed: the name is kept in memory only, and
        // shown only once the phone's first transport message decrypts.
        guard let deviceName = Self.deviceName(in: read.payload) else {
            refuse(Refusal.badDeviceName)
            return
        }
        let reply: (message: Data, transport: NoiseTransport, handshakeHash: Data)
        do {
            reply = try responder.writeMessage2(payload: message2Payload)
        } catch {
            refuse(Refusal.unanswerable)
            return
        }
        let attempt = Attempt(
            id: UUID(), transport: reply.transport,
            code: PhoneConfirmationCode.make(handshakeHash: reply.handshakeHash),
            deviceName: deviceName, phoneKey: read.remoteStatic.rawRepresentation)
        offer?.phase = .waiting(attempt)
        outbox.yield(Outgoing(frame: reply.message, onLeft: nil))
        armHandshakeTimer(offerID: current.id, attemptID: attempt.id)
        logger.notice("Answered a phone pairing handshake; waiting for its first message")
    }

    /// The attempt's first transport message was a `hello`: the offer is
    /// consumed and waits for Allow or Deny.
    private func confirm(_ attempt: Attempt) async {
        // Cancelling takes the timer's sleep off the clock at once.
        handshakeTimer?.cancel()
        offer?.phase = .awaitingApproval(Confirmed(
            transport: attempt.transport, code: attempt.code, deviceName: attempt.deviceName,
            phoneKey: attempt.phoneKey))
        logger.notice("a phone completed the pairing handshake; waiting for Allow")
        onChange()
        await cancelHandshakeTimer()
    }

    /// Drops the offer's attempt, if any. The offer keeps waiting.
    private func dropAttempt(because reason: String) async {
        guard case .waiting(.some) = offer?.phase else { return }
        offer?.phase = .waiting(nil)
        logger.notice("Dropped a phone pairing handshake: \(reason, privacy: .public)")
        await cancelHandshakeTimer()
    }

    // MARK: - The handshake timer

    private func armHandshakeTimer(offerID: UUID, attemptID: UUID) {
        // Every path back to `waiting(nil)` has already ended the previous
        // timer; this only guards against a leak.
        handshakeTimer?.cancel()
        let clock = self.clock
        handshakeTimer = Task {
            do {
                try await clock.sleep(for: PhoneBridgeConstants.handshakeTimeout)
            } catch {
                return
            }
            await self.handshakeTimedOut(offerID: offerID, attemptID: attemptID)
        }
    }

    private func handshakeTimedOut(offerID: UUID, attemptID: UUID) async {
        guard let current = offer, current.id == offerID,
              case .waiting(.some(let attempt)) = current.phase, attempt.id == attemptID else { return }
        offer?.phase = .waiting(nil)
        logger.notice("Dropped a phone pairing handshake: no first message within the handshake timeout")
    }

    private func cancelHandshakeTimer() async {
        guard let timer = handshakeTimer else { return }
        handshakeTimer = nil
        timer.cancel()
        await timer.value
    }

    // MARK: - Ending

    /// Checks that `offerID` is awaiting approval, mints its device room and
    /// seals `paired`, then marks the offer as being allowed, so nothing else
    /// can end it.
    private func claimApproval(_ offerID: UUID) throws -> Claim {
        guard var current = offer, current.id == offerID else {
            throw PhoneBridgeError.noSuchOffer
        }
        switch current.phase {
        case .awaitingApproval(var confirmed):
            // A live offer always has its session; this only guards the
            // invariant.
            guard session != nil else { throw PhoneBridgeError.noSuchOffer }
            // Never the pairing room: everyone who saw the QR code knows it.
            var deviceRoom = try PhoneRoom.newToken()
            while deviceRoom == current.roomID {
                deviceRoom = try PhoneRoom.newToken()
            }
            let frame = try confirmed.transport.encrypt(LoaderHandler.paired(room: deviceRoom))
            current.phase = .allowing(confirmed)
            offer = current
            return Claim(confirmed: confirmed, deviceRoom: deviceRoom, pairedFrame: frame)
        case .waiting:
            throw PhoneBridgeError.notAwaitingApproval
        case .ended(.expired):
            throw PhoneBridgeError.offerExpired
        case .allowing, .paired, .ended:
            throw PhoneBridgeError.noSuchOffer
        }
    }

    /// The rest of Allow, in its own task so that `cancel` and `start` can
    /// wait for it. While the offer is `allowing`, events, expiry and Deny
    /// leave it alone.
    private func commitAllow(offerID: UUID, claim: Claim) async throws -> PhoneDevice {
        let device = PhoneDevice(id: UUID(), name: claim.confirmed.deviceName, publicKey: claim.confirmed.phoneKey,
                                 roomID: claim.deviceRoom, pairedAt: now())
        do {
            try await devices.insert(device)
        } catch {
            logger.error(
                "Could not store an allowed phone; the pairing is interrupted: \(error.localizedDescription, privacy: .public)"
            )
            await end(as: .interrupted)?.value
            throw error
        }
        logger.notice(
            "Allowed phone \(device.name, privacy: .public) (\(device.id, privacy: .public)); it moves to its own room"
        )
        if let ending = session, offer?.id == offerID {
            session = nil
            await close(ending, timer: takeHandshakeTimer(), sending: claim.pairedFrame)
        }
        if offer?.id == offerID {
            offer?.phase = .paired(deviceName: device.name, deviceID: device.id, code: claim.confirmed.code)
            onChange()
        }
        return device
    }

    private func expire(_ offerID: UUID) async {
        guard let current = offer, current.id == offerID, session != nil else { return }
        let last: Data?
        switch current.phase {
        case .waiting:
            last = nil
        case .awaitingApproval(var confirmed):
            last = encrypt(LoaderHandler.pairDenied(.expired), with: &confirmed.transport)
        case .allowing, .paired, .ended:
            return
        }
        logger.notice("Phone pairing offer expired")
        end(as: .expired, sending: last)
    }

    private func interrupt(because reason: String) {
        logger.notice("Phone pairing interrupted: \(reason, privacy: .public)")
        end(as: .interrupted)
    }

    /// Moves the live offer to `outcome` and closes its room in a task of
    /// its own, which the caller may await. Returns nil when no offer is
    /// live.
    ///
    /// The close never runs inline, because the inbound task and the expiry
    /// task end offers too, and the close waits for both.
    @discardableResult
    private func end(as outcome: PhonePairingState, sending last: Data? = nil) -> Task<Void, Never>? {
        guard let ending = session, offer != nil else { return nil }
        session = nil
        offer?.phase = .ended(outcome)
        let task = retire(ending, sending: last)
        onChange()
        return task
    }

    /// Ends any offer and waits until no session, closing or Allow remains.
    private func discardOffer() async {
        while true {
            if let pending = commit {
                _ = try? await pending.task.value
                if commit?.id == pending.id { commit = nil }
                continue
            }
            offer = nil
            if let ending = session {
                session = nil
                retire(ending, sending: nil)
            }
            let running = Array(closings.values)
            if running.isEmpty { return }
            for task in running {
                await task.value
            }
        }
    }

    /// Closes `ending` in a task recorded in `closings`.
    @discardableResult
    private func retire(_ ending: Session, sending last: Data?) -> Task<Void, Never> {
        let timer = takeHandshakeTimer()
        let id = UUID()
        let task = Task { await self.runClosing(id: id, ending, timer: timer, sending: last) }
        closings[id] = task
        return task
    }

    private func runClosing(id: UUID, _ ending: Session, timer: Task<Void, Never>?, sending last: Data?) async {
        await close(ending, timer: timer, sending: last)
        closings[id] = nil
    }

    /// Sends `last`, if any, and waits up to the flush limit for it to leave;
    /// then closes the room for good and waits for every task of the session.
    private func close(_ ending: Session, timer: Task<Void, Never>?, sending last: Data?) async {
        ending.expiry.cancel()
        timer?.cancel()
        if let last {
            let (left, signal) = AsyncStream.makeStream(of: Void.self)
            if case .enqueued = ending.outbox.yield(Outgoing(frame: last, onLeft: { signal.finish() })) {
                await waitUntilLeft(left)
            }
        }
        await ending.link.stop()
        ending.inbound.cancel()
        await ending.inbound.value
        ending.outbox.finish()
        await ending.writer.value
        await ending.expiry.value
        await timer?.value
    }

    private func takeHandshakeTimer() -> Task<Void, Never>? {
        let timer = handshakeTimer
        handshakeTimer = nil
        timer?.cancel()
        return timer
    }

    // MARK: - Outbound

    /// The one writer: sends each queued frame in order.
    private static func drain(_ outbox: AsyncStream<Outgoing>, to link: RelayLink) async {
        for await item in outbox {
            do {
                try await link.send(item.frame)
            } catch {
                logger.notice("A phone pairing frame did not leave: \(error.localizedDescription, privacy: .public)")
            }
            item.onLeft?()
        }
    }

    /// Waits until `left` finishes or the flush limit passes, whichever comes
    /// first.
    private func waitUntilLeft(_ left: AsyncStream<Void>) async {
        let clock = self.clock
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in left {}
            }
            group.addTask {
                try? await clock.sleep(for: PhoneBridgeConstants.flushLimit)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// `plaintext` sealed on `transport`, or nil when it cannot be, in which
    /// case the phone simply sees the room close.
    private func encrypt(_ plaintext: Data, with transport: inout NoiseTransport) -> Data? {
        do {
            return try transport.encrypt(plaintext)
        } catch {
            logger.error("Could not encrypt a pairing message: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Helpers

    private func refuse(_ reason: String) {
        logger.notice("Refused a phone pairing handshake: \(reason, privacy: .public)")
    }

    /// Whether `plaintext` is one JSON object whose `type` is `hello`.
    private static func isHello(_ plaintext: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any] else {
            return false
        }
        return object["type"] as? String == "hello"
    }

    /// The trimmed `deviceName` in message 1's payload, or nil unless it is
    /// 1 to `deviceNameMaxCharacters` characters with no control or format
    /// character.
    private static func deviceName(in payload: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let raw = object["deviceName"] as? String else {
            return nil
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = name.unicodeScalars.contains { scalar in
            let category = scalar.properties.generalCategory
            return category == .control || category == .format
        }
        guard !name.isEmpty, name.count <= PhoneBridgeConstants.deviceNameMaxCharacters, !forbidden else {
            return nil
        }
        return name
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
