import CryptoKit
import Foundation
import os
import TBDShared

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
/// - The first frame that decrypts on the attempt is a `hello`: the offer is
///   *consumed* and moves to `awaitingApproval`.
/// - It is anything else: the attempt is dropped.
/// - A frame identical to the message 1 the attempt answered is a second
///   copy, which the relay can deliver. It is dropped, and the attempt kept:
///   answering it would replace the attempt with one the phone, which read
///   the first message 2, cannot complete.
/// - Any other frame that fails to decrypt is tried as a new message 1,
///   because a valid replayed message 1 can arrive before the phone's real
///   one, and nothing tells the two apart until a transport message
///   decrypts. A frame that reads and names an acceptable device replaces the
///   attempt, with a new message 2 and a new handshake timer; any other is
///   dropped, and the attempt kept. A phone retrying on the same socket is
///   not lost either.
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
///   room for good, and then calls `onPaired`. The row is stored first,
///   because the phone may connect to its room as soon as it reads `paired`.
/// - When `paired` cannot have reached the phone, Allow undoes the pairing:
///   the row is deleted again, the offer is interrupted, `onPairingUndone` is
///   called, `allow` throws `.pairingNotFinished`, and `onPaired` is not
///   called. That is when the send fails or is still in flight at the flush
///   limit, and when `peer-joined`, `peer-left`, a link `.closed` or a
///   refusal arrives before `paired` has reached the relay; such an event
///   ends Allow's wait at once. One that arrives after is the phone leaving
///   with its room. A reconcile that ran while the row existed may have
///   opened a link for it; `onPairingUndone` is how the owner stops it.
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
        /// The attempt's own message 1 again: the relay delivered it twice.
        static let repeated = "repeated handshake message"
    }

    /// A handshake whose message 2 has gone out, waiting for the phone's
    /// first transport message. Its transport is the service's `channel`.
    private struct Attempt {
        let id: UUID
        /// The message 1 the attempt answered. A frame identical to it is a
        /// second copy.
        let message1: Data
        let code: String
        let deviceName: String
        /// The phone's 32-byte X25519 public key.
        let phoneKey: Data
    }

    /// A phone whose `hello` decrypted, waiting for Allow or Deny. Its
    /// transport is the service's `channel` until Allow seals `paired`.
    private struct Confirmed {
        let code: String
        let deviceName: String
        let phoneKey: Data
    }

    /// Allow's progress with the confirmed phone, from the claim until
    /// `paired` has reached the relay.
    private struct Allowing {
        let confirmed: Confirmed
        /// Set by the writer, off the actor, the moment `paired` reaches the
        /// relay, so an event the phone's reading of it caused is never taken
        /// for one that came first. Nil until Allow queues `paired`.
        var sent: OSAllocatedUnfairLock<Bool>?
        /// Ends Allow's wait for `paired` early.
        var stopWaiting: AsyncStream<Void>.Continuation?
        /// Why the phone cannot hear `paired`: an event that ended its
        /// channel before `paired` reached the relay.
        var lost: String?

        var hasSent: Bool {
            sent?.withLock { $0 } ?? false
        }
    }

    private enum Phase {
        /// `waitingForPhone`, with the handshake waiting for its first
        /// transport message, if any.
        case waiting(Attempt?)
        /// `awaitingApproval`.
        case awaitingApproval(Confirmed)
        /// Allow has taken the offer and is storing the phone and telling it
        /// its room. Shown as `awaitingApproval`.
        case allowing(Allowing)
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
            case .awaitingApproval(let confirmed):
                return approvalStatus(confirmed)
            case .allowing(let allowing):
                return approvalStatus(allowing.confirmed)
            case .paired(let deviceName, let deviceID, let code):
                return PhonePairingStatus(offerID: id, link: nil, expiresAt: expiresAt, state: .paired,
                                          confirmationCode: code, deviceName: deviceName, deviceID: deviceID)
            case .ended(let state):
                return PhonePairingStatus(offerID: id, link: nil, expiresAt: expiresAt, state: state)
            }
        }

        private func approvalStatus(_ confirmed: Confirmed) -> PhonePairingStatus {
            PhonePairingStatus(offerID: id, link: link, expiresAt: expiresAt, state: .awaitingApproval,
                               confirmationCode: confirmed.code, deviceName: confirmed.deviceName)
        }
    }

    /// One frame for the writer.
    private struct Outgoing: Sendable {
        let frame: Data
        /// Called once the frame has reached the relay (`true`) or failed
        /// to (`false`).
        let onLeft: (@Sendable (Bool) -> Void)?
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
    private let onPairingUndone: @Sendable () async -> Void
    private let now: @Sendable () -> Date
    private let backoff: PhoneBackoff
    private let clock: any Clock<Duration>

    /// The offer `status` shows: live, or ended until the next `start` or
    /// `cancel`.
    private var offer: Offer?
    /// The live offer's socket and tasks; nil once it is closing or ended.
    private var session: Session?
    /// The transport of the live offer's handshake: the attempt's while it
    /// waits for its first message, then the confirmed phone's until Allow
    /// seals `paired` or the offer ends; nil otherwise. `NoiseTransport` is a
    /// value, and this is its one place: every encrypt and decrypt mutates it
    /// here, so no copy ever reuses a nonce.
    private var channel: NoiseTransport?
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
         onPairingUndone: @escaping @Sendable () async -> Void,
         now: @escaping @Sendable () -> Date = Date.init,
         backoff: PhoneBackoff = PhoneBackoff(), clock: any Clock<Duration> = ContinuousClock()) {
        self.relayURL = relayURL
        self.transport = transport
        self.laptopKey = laptopKey
        let name = LaptopName.limited(laptopName)
        self.laptopName = name
        self.message2Payload = LoaderHandler.message2Payload(laptopName: name)
        self.devices = devices
        self.preflight = preflight
        self.onChange = onChange
        self.onPaired = onPaired
        self.onPairingUndone = onPairingUndone
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
    ///
    /// Throws `.invalidPairingLink` when the link is one a phone would
    /// refuse, which leaves no offer and opens no room.
    func start(loaderURL: URL) async throws -> PhonePairingStatus {
        let discarded = await discardOffer()
        // Nothing below suspends, so no other offer can begin meanwhile.
        let created: Offer
        do {
            created = try makeOffer(loaderURL: loaderURL)
        } catch {
            if discarded {
                onChange()
            }
            throw error
        }
        offer = created
        session = openSession(offerID: created.id, roomID: created.roomID)
        PhoneBridgeLog.record(.offerCreated)
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
    /// the current offer. Throws `.pairingNotFinished` when `paired` cannot
    /// have reached the phone; the row is gone again, the offer is
    /// interrupted, `onPairingUndone` has returned, and `onPaired` is not
    /// called.
    ///
    /// Both callbacks run on the caller's task once the commit has cleared,
    /// never inside it: `cancel` and `start` wait for the commit, and an
    /// owner's callback may wait for them. So either can run after `cancel()`
    /// has returned.
    func allow(offerID: UUID) async throws -> PhoneDevice {
        let claim = try claimApproval(offerID)
        let id = UUID()
        let task = Task { try await self.commitAllow(offerID: offerID, claim: claim) }
        commit = (id, task)
        let outcome = await task.result
        if commit?.id == id { commit = nil }
        switch outcome {
        case .success(let device):
            await onPaired(device)
            return device
        case .failure(let error):
            // Only an undone Allow stored a row and deleted it again.
            if (error as? PhoneBridgeError) == .pairingNotFinished {
                await onPairingUndone()
            }
            throw error
        }
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
        case .awaitingApproval:
            last = seal(LoaderHandler.pairDenied(.denied))
        case .ended(.expired):
            throw PhoneBridgeError.offerExpired
        case .allowing, .paired, .ended:
            throw PhoneBridgeError.noSuchOffer
        }
        // A live offer always has its session; this only guards the invariant.
        guard let closing = end(as: .denied, sending: last) else {
            throw PhoneBridgeError.noSuchOffer
        }
        PhoneBridgeLog.record(.denied)
        await closing.value
    }

    /// Ends the offer, live or not, closing its room without a word to the
    /// phone, and waits until every task of every offer has finished. An
    /// Allow in progress finishes first. `status` is nil afterwards.
    func cancel() async {
        // Asked of the discard rather than read on entry: a `start` that
        // lands while this waits makes an offer that is discarded too.
        if await discardOffer() {
            onChange()
        }
    }

    // MARK: - The room

    /// A new offer in a new room, waiting for a phone, with its link built
    /// and then read back the way the phone reads it. A link the phone would
    /// refuse is never shown as a QR code: it throws `.invalidPairingLink`.
    private func makeOffer(loaderURL: URL) throws -> Offer {
        let roomID = try PhoneRoom.newToken()
        let secret = try PhoneRoom.newToken()
        guard let roomBytes = PhoneRoom.roomBytes(roomID) else { throw NoiseError.invalidRoomID }
        guard let secretBytes = PhoneRoom.roomBytes(secret) else { throw NoiseError.invalidPSK }
        let prologue = try PhoneChannelPrologue.make(roomID: roomBytes)
        let createdAt = now()
        let expiresAt = createdAt.addingTimeInterval(Self.seconds(PhoneBridgeConstants.pairingOfferLifetime))
        let link = PairingLink(
            v: PairingLink.currentVersion, relay: relayURL.absoluteString, room: roomID, secret: secret,
            key: Base64URL.encode(laptopKey.publicKey.rawRepresentation), name: laptopName,
            exp: Int(expiresAt.timeIntervalSince1970))
        let url = link.url(loaderURL: loaderURL)
        // `url(loaderURL:)` checks nothing, and the relay address comes from
        // config, so read the link back with the phone's own rules.
        let parsed: PairingLink
        do {
            parsed = try PairingLink.parse(url, now: createdAt)
        } catch {
            // The error names the check that failed, never the secret or a
            // field's text.
            PhoneBridgeLog.record(.failed(
                "Refused to show a pairing link a phone could not read: \(error.localizedDescription)"))
            throw PhoneBridgeError.invalidPairingLink
        }
        guard parsed == link else {
            PhoneBridgeLog.record(.failed("Refused to show a pairing link that does not read back as it was built"))
            throw PhoneBridgeError.invalidPairingLink
        }
        return Offer(
            id: UUID(), roomID: roomID, prologue: prologue, psk: SymmetricKey(data: secretBytes),
            link: url.absoluteString, expiresAt: expiresAt, phase: .waiting(nil))
    }

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

    /// Offer `offerID`, while it is the current offer and its room is open.
    private func liveOffer(_ offerID: UUID) -> Offer? {
        guard let current = offer, current.id == offerID, session != nil else { return nil }
        return current
    }

    private func handle(_ event: RelayLinkEvent, offerID: UUID) async {
        guard let current = liveOffer(offerID) else { return }
        switch event {
        case .opened, .connectFailed, .peerAbsent:
            return
        case .refused:
            // The link has stopped for good, so no phone can reach the offer.
            switch current.phase {
            case .waiting, .awaitingApproval:
                interrupt(because: "the relay was refused")
            case .allowing:
                loseAllow(because: "the relay was refused before the phone heard it was paired")
            case .paired, .ended:
                return
            }
        case .peerJoined, .peerLeft, .closed:
            switch current.phase {
            case .waiting(.some):
                await dropAttempt(because: "the phone's socket changed")
            case .awaitingApproval:
                interrupt(because: "the phone's socket changed")
            case .allowing:
                loseAllow(because: "the phone's socket changed before it heard it was paired")
            case .waiting(.none), .paired, .ended:
                return
            }
        case .frame(let bytes):
            await receiveFrame(bytes, offerID: offerID)
        }
    }

    private func receiveFrame(_ frame: Data, offerID: UUID) async {
        guard let current = liveOffer(offerID) else { return }
        switch current.phase {
        case .waiting(.some(let attempt)):
            guard let plaintext = try? channel?.decrypt(frame) else {
                // A second copy of the message 1 the attempt answered.
                // Answering it again would replace the attempt with one the
                // phone, which read the first message 2, cannot complete.
                if frame == attempt.message1 {
                    refuse(Refusal.repeated)
                    return
                }
                // Nothing has decrypted on the attempt, so it may be a
                // replayed message 1's and this frame the phone's real one.
                await answerMessage1(frame, offerID: offerID)
                return
            }
            if Self.isHello(plaintext) {
                await confirm(attempt)
            } else {
                await dropAttempt(because: "the first message was not hello")
            }
        case .waiting(.none):
            await answerMessage1(frame, offerID: offerID)
        case .awaitingApproval:
            // A frame that decrypts is ignored; decrypting it moved the
            // receive counter on, in place.
            if (try? channel?.decrypt(frame)) == nil {
                interrupt(because: "a frame failed to decrypt")
            }
        case .allowing, .paired, .ended:
            return
        }
    }

    /// Tries `frame` as IKpsk2 message 1 for offer `offerID` and, when it
    /// reads and names an acceptable device, answers with message 2 and keeps
    /// the handshake as the offer's attempt, replacing the attempt it had, if
    /// any. A refused frame leaves the attempt as it was.
    private func answerMessage1(_ frame: Data, offerID: UUID) async {
        guard let current = liveOffer(offerID) else { return }
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
        // The attempt this one replaces, if any, loses its timer first, so a
        // timer never outlives its attempt.
        await cancelHandshakeTimer()
        // Deny, expiry, `cancel` or a new `start` may have ended the offer
        // meanwhile.
        guard let after = offer, after.id == offerID, case .waiting(let replaced) = after.phase,
              let outbox = session?.outbox else {
            return
        }
        let attempt = Attempt(
            id: UUID(), message1: frame, code: PhoneConfirmationCode.make(handshakeHash: reply.handshakeHash),
            deviceName: deviceName, phoneKey: read.remoteStatic.rawRepresentation)
        offer?.phase = .waiting(attempt)
        // The replaced attempt's transport, if any, goes with it.
        channel = reply.transport
        outbox.yield(Outgoing(frame: reply.message, onLeft: nil))
        armHandshakeTimer(offerID: offerID, attemptID: attempt.id)
        PhoneBridgeLog.record(.handshakeAnswered(deviceID: nil, replacing: replaced != nil))
    }

    /// The attempt's first transport message was a `hello`: the offer is
    /// consumed and waits for Allow or Deny.
    private func confirm(_ attempt: Attempt) async {
        // Cancelling takes the timer's sleep off the clock at once.
        handshakeTimer?.cancel()
        // `channel` stays: the attempt's transport is the confirmed phone's.
        offer?.phase = .awaitingApproval(Confirmed(
            code: attempt.code, deviceName: attempt.deviceName, phoneKey: attempt.phoneKey))
        PhoneBridgeLog.record(.handshakeCompleted)
        onChange()
        await cancelHandshakeTimer()
    }

    /// Drops the offer's attempt, if any. The offer keeps waiting.
    private func dropAttempt(because reason: String) async {
        guard case .waiting(.some) = offer?.phase else { return }
        offer?.phase = .waiting(nil)
        channel = nil
        PhoneBridgeLog.record(.attemptDropped(reason: reason))
        await cancelHandshakeTimer()
    }

    // MARK: - The handshake timer

    private func armHandshakeTimer(offerID: UUID, attemptID: UUID) {
        // `answerMessage1` has already ended the previous timer; this only
        // guards against a leak.
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
        channel = nil
        PhoneBridgeLog.record(.attemptDropped(reason: "no first message within the handshake timeout"))
    }

    private func cancelHandshakeTimer() async {
        guard let timer = handshakeTimer else { return }
        handshakeTimer = nil
        timer.cancel()
        await timer.value
    }

    // MARK: - Ending

    /// Checks that `offerID` is awaiting approval, mints its device room and
    /// seals `paired` on `channel`, then marks the offer as being allowed, so
    /// nothing else can end it. `paired` is the last message the channel
    /// carries, so the channel goes once it is sealed.
    private func claimApproval(_ offerID: UUID) throws -> Claim {
        guard let current = offer, current.id == offerID else {
            throw PhoneBridgeError.noSuchOffer
        }
        switch current.phase {
        case .awaitingApproval(let confirmed):
            // A live offer always has its session and, while awaiting
            // approval, its channel; this only guards the invariant.
            guard session != nil, channel != nil else { throw PhoneBridgeError.noSuchOffer }
            // Never the pairing room: everyone who saw the QR code knows it.
            var deviceRoom = try PhoneRoom.newToken()
            while deviceRoom == current.roomID {
                deviceRoom = try PhoneRoom.newToken()
            }
            guard let frame = try channel?.encrypt(LoaderHandler.paired(room: deviceRoom)) else {
                throw PhoneBridgeError.noSuchOffer
            }
            channel = nil
            offer?.phase = .allowing(Allowing(confirmed: confirmed))
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
    /// wait for it. While the offer is `allowing`, expiry and Deny leave it
    /// alone, and an event that ends the phone's channel before `paired`
    /// reaches the relay makes the pairing undone.
    private func commitAllow(offerID: UUID, claim: Claim) async throws -> PhoneDevice {
        let device = PhoneDevice(id: UUID(), name: claim.confirmed.deviceName, publicKey: claim.confirmed.phoneKey,
                                 roomID: claim.deviceRoom, pairedAt: now())
        do {
            try await devices.insert(device)
        } catch {
            PhoneBridgeLog.record(.failed(
                "Could not store an allowed phone; the pairing is interrupted: \(error.localizedDescription)"))
            await end(as: .interrupted)?.value
            throw error
        }
        // The row is in place before `paired` goes: the phone may connect to
        // its new room as soon as it reads it.
        if let lost = await sendPaired(claim.pairedFrame, offerID: offerID) {
            await undoAllow(device, because: lost)
            throw PhoneBridgeError.pairingNotFinished
        }
        PhoneBridgeLog.record(.allowed(name: device.name, deviceID: device.id))
        if let ending = session, offer?.id == offerID {
            session = nil
            await close(ending, timer: takeHandshakeTimer(), sending: nil)
        }
        if offer?.id == offerID {
            offer?.phase = .paired(deviceName: device.name, deviceID: device.id, code: claim.confirmed.code)
            onChange()
        }
        return device
    }

    /// Queues `paired` and waits, up to the flush limit, until it reaches the
    /// relay. Nil once it has, with the phone's channel still standing;
    /// otherwise why the phone cannot have heard it. An event that ends the
    /// channel first ends the wait at once.
    private func sendPaired(_ frame: Data, offerID: UUID) async -> String? {
        let unsent = "the phone's new room did not reach the relay"
        guard let current = offer, current.id == offerID, case .allowing(var allowing) = current.phase,
              let outbox = session?.outbox else {
            return unsent
        }
        if let lost = allowing.lost {
            return lost
        }
        let sent = OSAllocatedUnfairLock(initialState: false)
        let (left, signal) = AsyncStream.makeStream(of: Void.self)
        allowing.sent = sent
        allowing.stopWaiting = signal
        offer?.phase = .allowing(allowing)
        let outgoing = Outgoing(frame: frame, onLeft: { reached in
            if reached {
                sent.withLock { $0 = true }
            }
            signal.finish()
        })
        guard case .enqueued = outbox.yield(outgoing) else { return unsent }
        await waitUntilLeft(left, clock: clock)
        if case .allowing(let after) = offer?.phase, let lost = after.lost {
            return lost
        }
        return sent.withLock { $0 } ? nil : unsent
    }

    /// An event ended the confirmed phone's channel while Allow was storing
    /// it or sending `paired`. Before `paired` has reached the relay, the
    /// phone can no longer hear it, so Allow stops waiting and undoes the
    /// pairing. After, the event is the phone leaving with its new room, and
    /// changes nothing.
    private func loseAllow(because reason: String) {
        guard case .allowing(var allowing) = offer?.phase, !allowing.hasSent, allowing.lost == nil else { return }
        allowing.lost = reason
        offer?.phase = .allowing(allowing)
        allowing.stopWaiting?.finish()
    }

    /// `paired` cannot have reached the phone: the row Allow stored goes
    /// again, and the offer ends as interrupted. `allow` then calls
    /// `onPairingUndone` and throws, so `onPaired` is not called: no pairing
    /// notification. `cancel` and `start` wait for the room's close.
    private func undoAllow(_ device: PhoneDevice, because reason: String) async {
        do {
            try await devices.delete(id: device.id)
        } catch {
            PhoneBridgeLog.record(.failed(
                "Could not remove phone \(device.id), whose pairing did not finish: \(error.localizedDescription)"))
        }
        PhoneBridgeLog.record(.interrupted(reason: reason))
        end(as: .interrupted)
    }

    private func expire(_ offerID: UUID) async {
        guard let current = liveOffer(offerID) else { return }
        let last: Data?
        switch current.phase {
        case .waiting:
            last = nil
        case .awaitingApproval:
            last = seal(LoaderHandler.pairDenied(.expired))
        case .allowing, .paired, .ended:
            return
        }
        PhoneBridgeLog.record(.expired)
        end(as: .expired, sending: last)
    }

    private func interrupt(because reason: String) {
        PhoneBridgeLog.record(.interrupted(reason: reason))
        end(as: .interrupted)
    }

    /// Moves the live offer to `outcome` and closes its room in a task of
    /// its own, which the caller may await. Returns nil when no offer is
    /// live. `last`, if any, was sealed on `channel` before this call, and
    /// the channel goes with the offer.
    ///
    /// The close never runs inline, because the inbound task and the expiry
    /// task end offers too, and the close waits for both.
    @discardableResult
    private func end(as outcome: PhonePairingState, sending last: Data? = nil) -> Task<Void, Never>? {
        guard let ending = session, offer != nil else { return nil }
        session = nil
        offer?.phase = .ended(outcome)
        channel = nil
        let task = retire(ending, sending: last)
        onChange()
        return task
    }

    /// Ends any offer and waits until no session, closing or Allow remains.
    /// Returns whether it discarded an offer, live or ended, counting one
    /// that a `start` made while it waited.
    @discardableResult
    private func discardOffer() async -> Bool {
        var discarded = false
        while true {
            if let pending = commit {
                _ = try? await pending.task.value
                if commit?.id == pending.id { commit = nil }
                continue
            }
            if offer != nil {
                discarded = true
                offer = nil
            }
            channel = nil
            if let ending = session {
                session = nil
                retire(ending, sending: nil)
            }
            let running = Array(closings.values)
            if running.isEmpty { return discarded }
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
            if case .enqueued = ending.outbox.yield(Outgoing(frame: last, onLeft: { _ in signal.finish() })) {
                await waitUntilLeft(left, clock: clock)
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
            let reached: Bool
            do {
                try await link.send(item.frame)
                reached = true
            } catch {
                PhoneBridgeLog.record(.frameNotSent(deviceID: nil, detail: error.localizedDescription))
                reached = false
            }
            item.onLeft?(reached)
        }
    }

    /// `plaintext` sealed on `channel`, in place, or nil when there is no
    /// channel or it cannot seal, in which case the phone simply sees the
    /// room close.
    private func seal(_ plaintext: Data) -> Data? {
        do {
            return try channel?.encrypt(plaintext)
        } catch {
            PhoneBridgeLog.record(.failed("Could not encrypt a pairing message: \(error.localizedDescription)"))
            return nil
        }
    }

    // MARK: - Helpers

    private func refuse(_ reason: String) {
        PhoneBridgeLog.record(.handshakeRefused(reason: reason, deviceID: nil))
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
