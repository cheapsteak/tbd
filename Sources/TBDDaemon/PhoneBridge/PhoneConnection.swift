import CryptoKit
import Foundation
import TBDShared

/// One paired phone's relay room: the laptop's socket there, the `Noise_IK`
/// responder that accepts only that phone's key, the ordered writer, and the
/// loader protocol for each channel.
///
/// **States.** A channel is one completed handshake with one phone page.
/// - *Awaiting* (no channel): a binary frame is tried as IK message 1.
/// - *Handshaken*: message 2 is sent and nothing has decrypted yet. The phone
///   does not count as connected, because a replayed message 1 gets this far.
/// - *Established*: the phone's first transport message decrypted, which only
///   the holder of the paired key can produce. The phone is connected.
/// - *Closing*: `stop()` has begun; nothing new starts.
///
/// **Accepting a handshake.** A fresh responder reads message 1, and the
/// `phone_device` row for this room is read then, so a revoke made between
/// connections is honoured. The handshake is refused, with nothing sent and
/// the socket left open, when message 1 cannot be read (a stale frame meant
/// for a replaced peer, or junk), when the room has no row, or when the
/// phone's static key is not the row's. The message-1 payload is ignored.
///
/// **Channel rules.**
/// - `peer-joined`, `peer-left` and a link `.closed` end the channel. A
///   reloaded page needs nothing more: its socket makes the relay send
///   `peer-joined`, and its message 1 starts a fresh channel on the same
///   laptop socket.
/// - While a channel is handshaken, a frame identical to the message 1 that
///   started it is a second copy, which the relay can deliver. It is
///   dropped, and the channel kept: answering it would replace the channel
///   with one the phone, which read the first message 2, cannot complete.
/// - While a channel is handshaken, any other frame that fails to decrypt is
///   tried as a new message 1 with a fresh responder: a valid replayed
///   message 1 can arrive before the phone's real one, and nothing tells the
///   two apart until a transport message decrypts. A frame that is accepted
///   replaces the handshaken channel, with a new message 2 and a new
///   handshake timer; a frame that is refused is dropped, and the channel
///   kept.
/// - A handshaken channel with nothing decrypted after
///   `PhoneBridgeConstants.handshakeTimeout` is dropped silently, and the
///   room waits for a new message 1.
/// - A frame that fails to decrypt on an established channel ends the
///   channel and reopens the room socket, so the phone sees `peer-left`,
///   then `peer-joined`, and handshakes again. So does a loader `.end`, after
///   any message it sends first has left, bounded by the flush limit.
///
/// **Ordering.** One inbound task handles the link's events one at a time, so
/// `handleAppMessage` runs once per message, in arrival order, each awaited
/// before the next, and the app layer hears `phoneDisconnected` for one
/// channel before `phoneConnected` for the next. Every outgoing frame is
/// encrypted and queued in one actor turn and leaves through one writer task,
/// so concurrent outbox sends reach the phone in encryption order.
///
/// No task, socket or continuation outlives `stop()`.
actor PhoneConnection {
    enum Event: Sendable, Equatable {
        case linkOpened, linkClosed, linkConnectFailed(String), linkRefused(String)
        case connected(deviceID: UUID), disconnected(deviceID: UUID)
        /// A binary frame did not lead to a channel. The reason is a fixed
        /// phrase from ``Refusal``; it never quotes the frame.
        case handshakeRefused(String)
    }

    /// The reasons `.handshakeRefused` carries.
    enum Refusal {
        /// The frame is not an IK message 1 for this room and this laptop:
        /// a stale frame meant for a replaced peer, a message for another
        /// pattern, or junk.
        static let unreadable = "unreadable handshake message"
        /// The room has no `phone_device` row: the phone was revoked.
        static let noDevice = "no paired device for this room"
        /// The phone's static key is not the paired one.
        static let unknownKey = "unknown key"
        static let storeFailed = "could not read the paired phones"
        static let invalidRoom = "the room ID is not valid"
        static let unanswerable = "could not answer the handshake"
        /// The handshaken channel's own message 1 again: the relay delivered
        /// it twice.
        static let repeated = "repeated handshake message"
        /// Message 2 went out, but nothing decrypted within
        /// `PhoneBridgeConstants.handshakeTimeout`.
        static let timedOut = "handshake timed out"
    }

    /// One completed handshake with one phone page.
    private struct Channel {
        let id: UUID
        /// The message 1 the channel answered. While the channel is
        /// handshaken, a frame identical to it is a second copy.
        let message1: Data
        var transport: NoiseTransport
        /// The paired row's name, read when the handshake was accepted.
        let deviceName: String
        /// Set by the first frame that decrypts, before anything awaits, so
        /// the handshake timer can no longer drop the channel.
        var confirmed = false
        /// Nil while the channel is handshaken.
        var established: Established?
    }

    private struct Established {
        let peer: PhonePeer
        /// Read once, when the channel became established, and kept for its
        /// whole life.
        let handler: any PhoneAppHandling
        var loader: LoaderHandler
    }

    /// One frame for the writer.
    private struct Outgoing: Sendable {
        let frame: Data
        /// The channel the frame belongs to. The writer drops a frame whose
        /// channel has ended.
        let channelID: UUID
        /// Called once the frame has left or been dropped.
        let onLeft: (@Sendable () -> Void)?
    }

    nonisolated let deviceID: UUID

    private let roomID: String
    /// The Noise prologue for this room; nil when the stored room ID is not
    /// 32 bytes of base64url, so no handshake can be accepted.
    private let prologue: Data?
    private let link: RelayLink
    private let laptopKey: Curve25519.KeyAgreement.PrivateKey
    /// Handshake message 2's payload: `{"laptopName":…}`.
    private let message2Payload: Data
    private let devices: PhoneDeviceStore
    private let bundle: PhoneAppBundle
    private let appSlot: PhoneAppHandlerSlot
    private let onEvent: @Sendable (Event) -> Void
    private let now: @Sendable () -> Date
    private let clock: any Clock<Duration>
    private let outbox: AsyncStream<Outgoing>
    private let outboxContinuation: AsyncStream<Outgoing>.Continuation

    /// The current channel; nil while awaiting a handshake.
    private var channel: Channel?
    /// Set once `stop()` begins.
    private var isClosing = false
    /// Set once `revokeAndStop()` begins, before `revoked` is queued: frames
    /// from the phone are dropped and the outbox refuses from then on.
    private var isRevoked = false
    private var inboundTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var handshakeTimer: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?

    init(device: PhoneDevice, relayURL: URL, transport: any RelayTransport,
         laptopKey: Curve25519.KeyAgreement.PrivateKey, laptopName: String,
         devices: PhoneDeviceStore, bundle: PhoneAppBundle, appSlot: PhoneAppHandlerSlot,
         preflight: @escaping @Sendable () async -> RelayPreflight,
         onEvent: @escaping @Sendable (Event) -> Void,
         now: @escaping @Sendable () -> Date = Date.init,
         backoff: PhoneBackoff = PhoneBackoff(), clock: any Clock<Duration> = ContinuousClock()) {
        self.deviceID = device.id
        self.roomID = device.roomID
        self.prologue = PhoneRoom.roomBytes(device.roomID).flatMap { try? PhoneChannelPrologue.make(roomID: $0) }
        self.link = RelayLink(url: PhoneRoom.socketURL(relay: relayURL, roomID: device.roomID), transport: transport,
                              backoff: backoff, preflight: preflight, clock: clock)
        self.laptopKey = laptopKey
        self.message2Payload = LoaderHandler.message2Payload(laptopName: LaptopName.limited(laptopName))
        self.devices = devices
        self.bundle = bundle
        self.appSlot = appSlot
        self.onEvent = onEvent
        self.now = now
        self.clock = clock
        let (stream, continuation) = AsyncStream.makeStream(of: Outgoing.self)
        self.outbox = stream
        self.outboxContinuation = continuation
    }

    /// Whether a channel is established: the phone's first transport message
    /// has decrypted and the channel has not ended.
    var isConnected: Bool {
        channel?.established != nil
    }

    /// Opens the room socket and starts handling it. Does nothing once
    /// started or stopped.
    func start() {
        guard inboundTask == nil, !isClosing else { return }
        writerTask = Task { await self.drainOutbox() }
        inboundTask = Task { await self.receiveEvents() }
    }

    /// Ends the channel, which calls `phoneDisconnected` once if it was
    /// established, after the last `handleAppMessage` has returned; closes the
    /// socket; and waits for every task. Sends nothing.
    func stop() async {
        if stopTask == nil {
            stopTask = Task { await self.close() }
        }
        await stopTask?.value
    }

    /// Sends `revoked` on an established channel, waits up to the flush limit
    /// for it to leave, then `stop()`s. From the moment it is called, every
    /// frame from the phone is dropped and the outbox answers false, so the
    /// phone can neither act nor hear more while `revoked` leaves.
    func revokeAndStop() async {
        isRevoked = true
        if !isClosing, let current = channel, current.established != nil {
            let (left, signal) = AsyncStream.makeStream(of: Void.self)
            enqueueEncrypted(LoaderHandler.revoked, channelID: current.id, onLeft: { signal.finish() })
            await waitUntilLeft(left, clock: clock)
        }
        await stop()
    }

    /// Sends one `app` message on channel `channelID`, for
    /// ``PhoneChannelOutbox``. False once that channel has ended or
    /// `revokeAndStop()` has been called, and when `body` is not one JSON
    /// object that fits a transport message, which is a caller bug.
    func sendApp(body: Data, channelID: UUID) -> Bool {
        guard !isClosing, !isRevoked, let current = channel, current.id == channelID,
              current.established != nil else {
            return false
        }
        let message: Data
        do {
            message = try LoaderHandler.appMessage(body: body)
        } catch {
            PhoneBridgeLog.record(.failed(
                "Refused an app message for phone \(deviceID), a caller bug: \(error.localizedDescription)"))
            return false
        }
        return enqueueEncrypted(message, channelID: channelID)
    }

    // MARK: - Inbound

    private func receiveEvents() async {
        await link.start()
        for await event in link.events {
            await handle(event)
        }
    }

    /// Once `stop()` has begun, this task ends no channel. `stop()` cancels
    /// it, yet a stream keeps handing over the events it buffered, the link's
    /// last `.closed` among them; ending the channel here would call
    /// `phoneDisconnected` from a cancelled task. `close()` ends the channel
    /// instead, from a task nothing cancels.
    private func handle(_ event: RelayLinkEvent) async {
        switch event {
        case .opened:
            emit(.linkOpened)
        case .closed:
            if !isClosing {
                await endChannel()
            }
            emit(.linkClosed)
        case .connectFailed(let reason):
            emit(.linkConnectFailed(reason))
        case .refused(let reason):
            emit(.linkRefused(reason))
        case .peerJoined, .peerLeft:
            if !isClosing {
                await endChannel()
            }
        case .peerAbsent:
            break
        case .frame(let bytes):
            await receiveFrame(bytes)
        }
    }

    private func receiveFrame(_ frame: Data) async {
        // A revoked phone is not heard while `revoked` leaves.
        guard !isClosing, !isRevoked else { return }
        guard let current = channel else {
            await answerHandshake(frame)
            return
        }
        guard let plaintext = try? channel?.transport.decrypt(frame) else {
            if current.established == nil {
                // A second copy of the message 1 this channel answered.
                // Answering it again would replace the channel with one the
                // phone, which read the first message 2, cannot complete.
                if frame == current.message1 {
                    refuse(Refusal.repeated)
                    return
                }
                // Nothing has decrypted on this channel, so it may be a
                // replayed message 1's and this frame the phone's real one.
                await answerHandshake(frame)
                return
            }
            PhoneBridgeLog.record(.channelEnded(
                deviceID: deviceID, reason: "a frame failed to decrypt; reopening the room socket"))
            await endChannel()
            await link.restart()
            return
        }
        if current.established == nil {
            guard await establish(current.id) else { return }
        }
        await runLoader(plaintext, channelID: current.id)
    }

    /// Tries `message1` as IK message 1 from this room's paired phone, and
    /// answers with message 2 only when the phone's key is the paired one.
    /// The answer starts a handshaken channel, replacing a handshaken one if
    /// there is one. A refused frame leaves any handshaken channel as it was.
    private func answerHandshake(_ message1: Data) async {
        guard let prologue else {
            refuse(Refusal.invalidRoom)
            return
        }
        var responder: NoiseResponder
        let remoteStatic: Curve25519.KeyAgreement.PublicKey
        do {
            responder = try NoiseResponder(pattern: .ik, staticKey: laptopKey, psk: nil, prologue: prologue)
            // The payload is ignored: message 1 can be replayed.
            remoteStatic = try responder.readMessage1(message1).remoteStatic
        } catch {
            refuse(Refusal.unreadable)
            return
        }
        let row: PhoneDevice?
        do {
            row = try await devices.device(roomID: roomID)
        } catch {
            // `stop()` cancels this task, which can fail the read.
            guard !isClosing else { return }
            PhoneBridgeLog.record(.failed(
                "Could not read the paired phone for device \(deviceID): \(error.localizedDescription)"))
            refuse(Refusal.storeFailed)
            return
        }
        // `stop()` or `revokeAndStop()` may have begun while the row was
        // read. Only this task establishes a channel, so none was
        // established meanwhile; the handshake timer may have dropped a
        // handshaken one.
        guard !isClosing, !isRevoked, channel?.established == nil else { return }
        guard let row, row.id == deviceID else {
            refuse(Refusal.noDevice)
            return
        }
        guard remoteStatic.rawRepresentation == row.publicKey else {
            refuse(Refusal.unknownKey)
            return
        }
        let reply: (message: Data, transport: NoiseTransport, handshakeHash: Data)
        do {
            reply = try responder.writeMessage2(payload: message2Payload)
        } catch {
            refuse(Refusal.unanswerable)
            return
        }
        // The handshaken channel this one replaces, if any, loses its timer
        // first, so a timer never outlives its channel.
        await cancelHandshakeTimer()
        guard !isClosing, !isRevoked, channel?.established == nil else { return }
        let replacing = channel != nil
        let channelID = UUID()
        channel = Channel(id: channelID, message1: message1, transport: reply.transport, deviceName: row.name)
        // Through the writer, behind any frame of an earlier channel still in
        // flight, so message 2 never overtakes one. A replaced channel's
        // message 2 still queued is dropped there.
        outboxContinuation.yield(Outgoing(frame: reply.message, channelID: channelID, onLeft: nil))
        armHandshakeTimer(for: channelID)
        PhoneBridgeLog.record(.handshakeAnswered(deviceID: deviceID, replacing: replacing))
    }

    /// The first frame of channel `channelID` decrypted: the channel becomes
    /// established and the app layer hears of it. False when `stop()` or
    /// `revokeAndStop()` began meanwhile, in which case nothing is called: a
    /// revoked phone never becomes connected, even for the moment before its
    /// connection closes.
    private func establish(_ channelID: UUID) async -> Bool {
        channel?.confirmed = true
        await cancelHandshakeTimer()
        let handler = await appSlot.current()
        guard !isClosing, !isRevoked, let current = channel, current.id == channelID else { return false }
        let peer = PhonePeer(deviceID: deviceID, deviceName: current.deviceName)
        channel?.established = Established(peer: peer, handler: handler, loader: LoaderHandler(bundle: bundle))
        await touchLastSeen()
        emit(.connected(deviceID: deviceID))
        PhoneBridgeLog.record(.connected(name: peer.deviceName, deviceID: deviceID))
        await handler.phoneConnected(peer, outbox: PhoneChannelOutbox(connection: self, channelID: channelID))
        return true
    }

    /// Hands one decrypted message to the channel's loader and carries out
    /// what it returns.
    private func runLoader(_ plaintext: Data, channelID: UUID) async {
        guard channel?.id == channelID,
              let established = channel?.established,
              let actions = channel?.established?.loader.handle(plaintext) else { return }
        let ends = actions.contains { action in
            if case .end = action { return true }
            return false
        }
        // When the list ends the channel, its last message must leave before
        // the socket closes: `incompatible` is sent, then the channel ends.
        var lastLeft: AsyncStream<Void>?
        for action in actions {
            switch action {
            case .send(let message):
                if ends {
                    let (left, signal) = AsyncStream.makeStream(of: Void.self)
                    enqueueEncrypted(message, channelID: channelID, onLeft: { signal.finish() })
                    lastLeft = left
                } else {
                    enqueueEncrypted(message, channelID: channelID)
                }
            case .deliverApp(let body):
                await established.handler.handleAppMessage(body, from: established.peer)
            case .end(let reason):
                // A fixed phrase from the loader, never message content.
                PhoneBridgeLog.record(.channelEnded(deviceID: deviceID, reason: reason))
                if let lastLeft {
                    await waitUntilLeft(lastLeft, clock: clock)
                }
                // `stop()` may have begun while the message left; `close()`
                // ends the channel then.
                guard !isClosing else { return }
                await endChannel()
                await link.restart()
                return
            }
        }
    }

    /// Ends the current channel, if any, and goes back to awaiting a
    /// handshake. An established channel's ID is retired first, so its outbox
    /// answers false from then on; then the app layer hears
    /// `phoneDisconnected`. A handshaken channel ends silently.
    private func endChannel() async {
        await cancelHandshakeTimer()
        guard let ended = channel else { return }
        channel = nil
        guard let established = ended.established else { return }
        await established.handler.phoneDisconnected(established.peer)
        emit(.disconnected(deviceID: deviceID))
        PhoneBridgeLog.record(.disconnected(name: established.peer.deviceName, deviceID: deviceID))
        await touchLastSeen()
    }

    // MARK: - The handshake timer

    private func armHandshakeTimer(for channelID: UUID) {
        // `answerHandshake` has already ended the previous timer; this only
        // guards against a leak.
        handshakeTimer?.cancel()
        let clock = self.clock
        handshakeTimer = Task {
            do {
                try await clock.sleep(for: PhoneBridgeConstants.handshakeTimeout)
            } catch {
                return
            }
            await self.handshakeTimedOut(channelID)
        }
    }

    private func handshakeTimedOut(_ channelID: UUID) async {
        guard let current = channel, current.id == channelID, !current.confirmed else { return }
        channel = nil
        refuse(Refusal.timedOut)
    }

    private func cancelHandshakeTimer() async {
        guard let timer = handshakeTimer else { return }
        handshakeTimer = nil
        timer.cancel()
        await timer.value
    }

    // MARK: - Outbound

    /// Encrypts `plaintext` for established channel `channelID` and queues it
    /// for the writer, in this one actor turn, so frames leave in the order
    /// they were encrypted. `onLeft` is always called, at once when nothing
    /// was queued.
    @discardableResult
    private func enqueueEncrypted(_ plaintext: Data, channelID: UUID,
                                  onLeft: (@Sendable () -> Void)? = nil) -> Bool {
        guard !isClosing, channel?.id == channelID, channel?.established != nil else {
            onLeft?()
            return false
        }
        let frame: Data
        do {
            guard let sealed = try channel?.transport.encrypt(plaintext) else {
                onLeft?()
                return false
            }
            frame = sealed
        } catch {
            PhoneBridgeLog.record(.failed(
                "Could not encrypt a message for phone \(deviceID): \(error.localizedDescription)"))
            onLeft?()
            return false
        }
        guard case .enqueued = outboxContinuation.yield(Outgoing(frame: frame, channelID: channelID, onLeft: onLeft)) else {
            onLeft?()
            return false
        }
        return true
    }

    /// The one writer: sends each queued frame in order, dropping a frame
    /// whose channel has ended or that was queued for a connection now
    /// closing.
    private func drainOutbox() async {
        for await item in outbox {
            if !isClosing, channel?.id == item.channelID {
                do {
                    try await link.send(item.frame)
                } catch {
                    PhoneBridgeLog.record(.frameNotSent(deviceID: deviceID, detail: error.localizedDescription))
                }
            }
            item.onLeft?()
        }
    }

    // MARK: - Stopping

    /// Runs in `stopTask`, which nothing cancels, so the channel ends here
    /// with `phoneDisconnected` and the last-seen write uncancelled: once,
    /// after the inbound task, and with it the last `handleAppMessage`, has
    /// returned.
    private func close() async {
        isClosing = true
        await link.stop()
        inboundTask?.cancel()
        await inboundTask?.value
        await endChannel()
        await cancelHandshakeTimer()
        outboxContinuation.finish()
        await writerTask?.value
    }

    // MARK: - Helpers

    private func refuse(_ reason: String) {
        PhoneBridgeLog.record(.handshakeRefused(reason: reason, deviceID: deviceID))
        emit(.handshakeRefused(reason))
    }

    private func touchLastSeen() async {
        let devices = self.devices
        let id = deviceID
        let date = now()
        // The database write fails in a cancelled task, and `stop()` cancels
        // the inbound task, which can be inside this call when stopping
        // begins. A plain `Task` does not inherit that cancellation, so the
        // write still lands; it is awaited, so it never outlives the
        // connection.
        let write = Task { try await devices.touchLastSeen(id: id, at: date) }
        do {
            try await write.value
        } catch {
            PhoneBridgeLog.record(.failed(
                "Could not record when phone \(deviceID) was last seen: \(error.localizedDescription)"))
        }
    }

    private func emit(_ event: Event) {
        onEvent(event)
    }
}

/// The outbox handed to `phoneConnected`. Bound to one channel; false once
/// that channel has ended.
struct PhoneChannelOutbox: PhoneAppOutbox {
    let connection: PhoneConnection
    let channelID: UUID

    func send(appBody: Data) async -> Bool {
        await connection.sendApp(body: appBody, channelID: channelID)
    }
}

/// Waits until `left` finishes or `PhoneBridgeConstants.flushLimit` passes on
/// `clock`, whichever comes first. `PhoneConnection` and `PairingService` use
/// it to give a last message time to leave before a socket closes.
func waitUntilLeft(_ left: AsyncStream<Void>, clock: any Clock<Duration>) async {
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
