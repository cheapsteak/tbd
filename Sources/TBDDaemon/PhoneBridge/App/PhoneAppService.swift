import Foundation
import os
import TBDShared

/// The request a handler serves.
struct DeviceContext: Sendable {
    /// The paired phone the request came through, as the bridge verified it.
    /// It is the only source of a device's identity: a handler passes
    /// `peer.deviceID` to every `PhoneSessionActions` method that acts, and
    /// never reads a device ID or name from the request body.
    let peer: PhonePeer
    let requestID: String
}

/// Serves one method. It takes the whole request body and returns the whole
/// reply body, as `PhoneAppCoding.reply(requestID:result:)` encodes it. For
/// an error reply it throws: a `PhoneAppError` is sent as it is, a
/// `DecodingError` becomes `bad_request`, and anything else `internal`. So a
/// handler that decodes something other than its params, such as an
/// `RPCResponse`'s result, catches that error itself.
typealias PhoneMethodHandler = @Sendable (Data, DeviceContext) async throws -> Data

/// What a connection's `sessions.subscribe` decided about the phone's event
/// stream, which a `transcript.open` with `resume` reads.
enum PhoneResumeDecision: Equatable, Sendable {
    /// No `sessions.subscribe` on this connection yet.
    case undecided
    /// The phone's stream carries on. These are the events it missed, oldest
    /// first, as the stream held them when the decision was made.
    case replay([Data])
    /// The phone's stream was unknown or reached too far back: it starts over
    /// from a fresh snapshot.
    case snapshot
}

/// Everything the service keeps for one phone, from its first connection
/// until the grace after a disconnect runs out or the phone is revoked.
///
/// The sessions publisher and the open transcript's feed belong here as
/// fields, and `shutDown()` stops them, so dropping the state stops
/// everything it runs.
struct PhoneDeviceState: Sendable {
    /// The current connection's way out; nil while the phone is disconnected.
    var outbox: PhoneOutboxQueue?
    /// Numbers the phone's events and keeps the recent ones for a reconnect.
    /// It lives as long as this state, so a reconnect inside the grace keeps
    /// its stream ID and a reconnect after it gets a new one.
    var stream = PhoneEventStream()
    /// What this connection's `sessions.subscribe` decided. Every connect and
    /// disconnect clears it.
    var resume: PhoneResumeDecision = .undecided
    /// Drops this state `parseStateGrace` after a disconnect; nil while the
    /// phone is connected.
    var grace: Task<Void, Never>?
    /// Tells the current grace from an earlier one that woke before its
    /// cancellation reached it.
    var graceToken: UInt64 = 0

    /// Stops everything this state runs. Called once, after the state has
    /// left the service's table.
    func shutDown() async {
        grace?.cancel()
        outbox?.close()
    }
}

/// One connection's way out, in order.
///
/// Replies and events are queued synchronously on the service actor, and one
/// task sends them through the connection's outbox one at a time, so they
/// leave in the order the service queued them: a phone never sees an event's
/// `seq` out of order. A queue belongs to one connection. `close()` drops
/// what is still queued, which is safe: a phone that reconnects resends its
/// requests, which the request memory answers, and asks for the events it
/// missed.
final class PhoneOutboxQueue: Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let sender: Task<Void, Never>

    init(_ outbox: any PhoneAppOutbox) {
        let (bodies, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        self.sender = Task {
            for await body in bodies {
                // False means the phone is gone, and the service hears of
                // that from the bridge.
                _ = await outbox.send(appBody: body)
            }
        }
    }

    deinit {
        continuation.finish()
    }

    /// Queues one app body. It leaves after every body queued before it.
    func enqueue(_ body: Data) {
        continuation.yield(body)
    }

    /// Stops the queue and drops whatever it still holds.
    func close() {
        continuation.finish()
        sender.cancel()
    }
}

/// The phone app protocol (spec section 4.4): each paired phone's
/// connection, its requests, and the events sent to it.
///
/// **A request runs in a task of the service's own.** `handleAppMessage`
/// reads the request's head, makes any decision the phone's next message must
/// see, starts the work and returns, as the bridge's contract asks. The work
/// outlives the bridge's call, so a disconnect in the middle of a send still
/// finishes the send and stores the reply in the request memory, and a resend
/// after a reconnect gets that reply and acts no more. The reply goes through
/// the connection the phone has when the reply is ready; while it is
/// disconnected, the reply is dropped.
///
/// **The work, in order:**
/// 1. **The flag.** `phone_control_enabled` is read for every request. Off:
///    the reply is `phone_control_off` and nothing else happens, with the
///    request memory untouched, so a resend after the flag is turned on is not
///    answered "off" from memory. A failed read fails closed with `internal`.
/// 2. **The request memory**, for every method but the pure reads (see
///    `remembersReplies(of:)`). The steps below run once per request ID; a
///    repeat gets the first run's reply.
/// 3. **The pairing.** The phone's `phone_device` row must still exist, or the
///    reply is `refused`. A failed read fails closed with `internal`. This
///    closes the window where a request starts just before a revoke and
///    reaches the memory after it.
/// 4. **The handler.** A method with no handler yet replies `unavailable`.
/// 5. **The record**, for the methods `recordTarget(for:body:)` names, from
///    the decoded params. Params that do not decode reply `bad_request` and
///    record nothing.
/// 6. **The handler runs**, under the identity in `DeviceContext`.
///
/// **Extending it.** A later task serves a method by returning its handler
/// from `registeredHandler(for:)`, usually built with `typed(_:_:)`, and keeps
/// per-device state in `PhoneDeviceState`, stopping it in
/// `PhoneDeviceState.shutDown()`. Code in other files reads and changes
/// `devices` entries in place; only the lifecycle methods add or remove one.
actor PhoneAppService: PhoneAppHandling {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    /// The reply to a known method no task serves yet.
    private static let notServed = PhoneAppError(code: .unavailable, message: "This TBD build cannot do that from a phone yet.")

    let db: TBDDatabase
    let actions: any PhoneSessionActions
    let subscriptions: StateSubscriptionManager
    let pendingPrompts: PendingPromptStore
    let recorder: any PhoneActionRecording
    let now: @Sendable () -> Date
    let clock: any Clock<Duration>
    /// Request IDs and their replies, per device.
    let memory: PhoneRequestMemory

    /// Each phone the service keeps state for, by device ID.
    var devices: [UUID: PhoneDeviceState] = [:]
    /// Handlers a test put in place of a method's own.
    private var replacedHandlers: [PhoneAppMethod: PhoneMethodHandler] = [:]
    /// Each device's requests still running, by a token per request.
    private var requests: [UUID: [UInt64: Task<Void, Never>]] = [:]
    private var nextToken: UInt64 = 0

    init(db: TBDDatabase, actions: any PhoneSessionActions, subscriptions: StateSubscriptionManager,
         pendingPrompts: PendingPromptStore, recorder: any PhoneActionRecording = LoggerPhoneActionRecorder(),
         now: @escaping @Sendable () -> Date = { Date() },
         clock: any Clock<Duration> = ContinuousClock()) {
        self.db = db
        self.actions = actions
        self.subscriptions = subscriptions
        self.pendingPrompts = pendingPrompts
        self.recorder = recorder
        self.now = now
        self.clock = clock
        self.memory = PhoneRequestMemory(clock: clock)
    }

    // MARK: - Lifecycle

    /// Cancels any grace, gives the device a new way out and clears the
    /// connection's resume decision. The event stream carries on when the
    /// state outlived a disconnect.
    ///
    /// The bridge never overlaps one phone's connections. If a connect comes
    /// for a phone that is connected anyway, its outbox replaces the old one,
    /// and the next disconnect ends the phone's connection whichever channel
    /// it came from: `PhonePeer` cannot tell two channels apart.
    func phoneConnected(_ peer: PhonePeer, outbox: any PhoneAppOutbox) {
        var state = devices[peer.deviceID] ?? PhoneDeviceState()
        state.grace?.cancel()
        state.grace = nil
        state.outbox?.close()
        state.outbox = PhoneOutboxQueue(outbox)
        state.resume = .undecided
        devices[peer.deviceID] = state
    }

    /// Drops the device's way out and starts the grace: the state, with its
    /// stream, publisher and feed, is dropped `parseStateGrace` later unless
    /// the phone reconnects first. Requests still running carry on, and their
    /// replies are dropped while the phone is away.
    func phoneDisconnected(_ peer: PhonePeer) {
        let deviceID = peer.deviceID
        guard var state = devices[deviceID] else { return }
        state.outbox?.close()
        state.outbox = nil
        state.resume = .undecided
        state.grace?.cancel()
        let token = nextToken
        nextToken &+= 1
        state.graceToken = token
        let clock = self.clock
        state.grace = Task {
            do {
                try await clock.sleep(for: PhoneAppConstants.parseStateGrace)
            } catch {
                return
            }
            await self.graceEnded(deviceID: deviceID, token: token)
        }
        devices[deviceID] = state
    }

    /// Drops the device's state at once, grace and all, cancels the device's
    /// requests still running, and forgets its request IDs.
    ///
    /// **Running requests are cancelled**, so a revoked phone's work stops as
    /// soon as it notices: a request that has not reached its handler yet
    /// stops at the pairing check, and the request memory cancels the runs it
    /// holds. A cancelled request sends no reply, and a run that notices its
    /// cancellation replies with an error, never a success. Work a handler
    /// has already started in a core function can still finish.
    func phoneRevoked(deviceID: UUID) async {
        let state = devices.removeValue(forKey: deviceID)
        for request in (requests[deviceID] ?? [:]).values {
            request.cancel()
        }
        await state?.shutDown()
        await memory.forget(deviceID: deviceID)
    }

    /// Drops the device's state once its grace runs out, if the phone has not
    /// reconnected and no later grace has replaced this one.
    private func graceEnded(deviceID: UUID, token: UInt64) async {
        guard let state = devices[deviceID], state.outbox == nil, state.graceToken == token else { return }
        devices[deviceID] = nil
        await state.shutDown()
    }

    // MARK: - Requests

    /// Reads the request's head, answers a malformed one at once, makes the
    /// connection's resume decision for `sessions.subscribe`, and starts the
    /// request's work. It never waits for the reply.
    ///
    /// Nothing runs for a message that is not a request, for a phone with no
    /// connection, or for a request whose ID is longer than
    /// `PhoneAppConstants.requestIDMaxBytes`; a device with
    /// `PhoneAppConstants.requestsInFlightPerDevice` requests running is
    /// refused. None of these reach the request memory or the flag.
    func handleAppMessage(_ body: Data, from peer: PhonePeer) async {
        let head: PhoneRequestHead
        do {
            head = try JSONDecoder().decode(PhoneRequestHead.self, from: body)
        } catch {
            Self.logger.error("Phone app: dropped a message of \(body.count, privacy: .public) bytes that is not a request")
            return
        }
        guard head.kind == "request" else {
            Self.logger.debug("Phone app: ignored a message that is not a request")
            return
        }
        let deviceID = peer.deviceID
        guard devices[deviceID]?.outbox != nil else {
            Self.logger.error("Phone app: dropped a request from phone \(deviceID, privacy: .public), which is not connected")
            return
        }
        let requestID = head.requestID
        let idBytes = requestID.utf8.count
        guard idBytes <= PhoneAppConstants.requestIDMaxBytes else {
            Self.logger.error("Phone app: refused a request ID of \(idBytes, privacy: .public) bytes")
            let reply = Self.failure(requestID, .badRequest, "The request ID is too long.")
            if PhoneAppCoding.framedSize(reply) <= PhoneFrameBudget.maxPlaintext {
                send(reply, to: deviceID)
            }
            return
        }
        guard let method = PhoneAppMethod(rawValue: head.method) else {
            send(Self.failure(requestID, .unknownMethod, "This TBD build has no such request."), to: deviceID)
            return
        }
        guard (requests[deviceID]?.count ?? 0) < PhoneAppConstants.requestsInFlightPerDevice else {
            Self.logger.notice("Phone app: refused a request from phone \(deviceID, privacy: .public): too many in progress")
            send(Self.failure(requestID, .refused, Self.tooManyRequests), to: deviceID)
            return
        }
        if method == .sessionsSubscribe {
            await decideResume(body, deviceID: deviceID)
        }
        start(method, body: body, context: DeviceContext(peer: peer, requestID: requestID))
    }

    /// Makes this connection's resume decision for a `sessions.subscribe`,
    /// before `handleAppMessage` returns, so the phone's next message sees it.
    ///
    /// The flag is read first, so a request made while phone control is off
    /// changes nothing. From the replay to the store there is no suspension,
    /// so the decision holds exactly the events the stream held at that
    /// moment. Params that do not decode leave the decision alone; the
    /// request's work answers them `bad_request`.
    private func decideResume(_ body: Data, deviceID: UUID) async {
        guard let params = try? PhoneAppCoding.params(SessionsSubscribeParams.self, from: body),
              (try? await db.config.get().phoneControlEnabled) == true,
              let state = devices[deviceID], state.outbox != nil else {
            return
        }
        if let missed = state.stream.replay(stream: params.stream, sinceSeq: params.sinceSeq) {
            devices[deviceID]?.resume = .replay(missed)
        } else {
            devices[deviceID]?.resume = .snapshot
        }
    }

    /// Starts the request's work in a task of the service's own. Only
    /// `phoneRevoked` cancels it.
    private func start(_ method: PhoneAppMethod, body: Data, context: DeviceContext) {
        let deviceID = context.peer.deviceID
        let token = nextToken
        nextToken &+= 1
        // The task runs on this actor between its suspensions, so it cannot
        // finish before it is stored.
        requests[deviceID, default: [:]][token] = Task {
            let reply = await self.serve(method, body: body, context: context)
            self.requestFinished(token, deviceID: deviceID, reply: reply)
        }
    }

    /// Sends a finished request's reply through the connection the phone has
    /// now. A request cancelled by a revoke sends nothing.
    private func requestFinished(_ token: UInt64, deviceID: UUID, reply: Data) {
        requests[deviceID]?[token] = nil
        if requests[deviceID]?.isEmpty == true {
            requests[deviceID] = nil
        }
        guard !Task.isCancelled else { return }
        send(reply, to: deviceID)
    }

    /// The request's work: the flag, then the request memory around
    /// `perform`. Runs off the actor, so one phone's slow request holds up
    /// nothing else.
    private nonisolated func serve(_ method: PhoneAppMethod, body: Data, context: DeviceContext) async -> Data {
        let requestID = context.requestID
        let enabled: Bool
        do {
            enabled = try await db.config.get().phoneControlEnabled
        } catch {
            Self.logger.error("Phone app: could not read the phone control setting: \(error.localizedDescription, privacy: .public)")
            return Self.failure(requestID, .internalError, "TBD could not read its phone control setting. Try again.")
        }
        guard enabled else {
            return Self.failure(requestID, .phoneControlOff, "Phone control is off on this laptop.")
        }
        guard !Task.isCancelled else { return Self.stopped(requestID) }
        guard Self.remembersReplies(of: method) else {
            return await perform(method, body: body, context: context)
        }
        let deviceID = context.peer.deviceID
        let (reply, _) = await memory.reply(
            deviceID: deviceID, requestID: requestID,
            refusal: {
                Self.logger.notice("Phone app: refused a request from phone \(deviceID, privacy: .public): too many in progress")
                return Self.failure(requestID, .refused, Self.tooManyRequests)
            },
            work: { [self] in
                await self.perform(method, body: body, context: context)
            })
        return reply
    }

    /// The part of a request that acts, run once per request ID when its
    /// replies are remembered: the pairing check, the record, the handler.
    private nonisolated func perform(_ method: PhoneAppMethod, body: Data, context: DeviceContext) async -> Data {
        let requestID = context.requestID
        do {
            guard try await db.phoneDevices.device(id: context.peer.deviceID) != nil else {
                return Self.failure(requestID, .refused, "This phone is no longer paired.")
            }
        } catch {
            Self.logger.error("Phone app: could not read a phone's pairing: \(error.localizedDescription, privacy: .public)")
            return Self.failure(requestID, .internalError, "TBD could not check this phone's pairing. Try again.")
        }
        guard let handler = await registeredHandler(for: method) else {
            return PhoneAppCoding.errorReply(requestID: requestID, Self.notServed)
        }
        do {
            if let target = try Self.recordTarget(for: method, body: body) {
                recorder.record(PhoneActionRecord(deviceName: context.peer.deviceName, action: method.rawValue, target: target))
            }
            let reply = try await handler(body, context)
            guard !Task.isCancelled else { return Self.stopped(requestID) }
            return reply
        } catch let error as PhoneAppError {
            return PhoneAppCoding.errorReply(requestID: requestID, error)
        } catch is DecodingError {
            return Self.failure(requestID, .badRequest, "The request's params are not valid.")
        } catch is CancellationError {
            return Self.stopped(requestID)
        } catch {
            Self.logger.error("Phone app: \(method.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return Self.failure(requestID, .internalError, "Something went wrong on the laptop.")
        }
    }

    // MARK: - Handlers

    /// The handler for `method`: its own, or one that replies `unavailable`
    /// while no task serves it.
    func handler(for method: PhoneAppMethod) -> PhoneMethodHandler {
        if let handler = registeredHandler(for: method) {
            return handler
        }
        return { _, _ in throw Self.notServed }
    }

    /// The one place a method gets its handler; nil while no task serves it.
    /// A later task serves a method by returning its handler here, as in
    /// `case .messageSend: return Self.typed(MessageSendParams.self) { [self] p, context in try await self.messageSend(p, context) }`.
    /// A handler a test put in place with `setHandler(_:for:)` comes first.
    func registeredHandler(for method: PhoneAppMethod) -> PhoneMethodHandler? {
        if let replaced = replacedHandlers[method] {
            return replaced
        }
        switch method {
        case .sessionsSubscribe, .transcriptOpen, .transcriptPage, .transcriptDetail, .transcriptClose,
             .messageSend, .promptAnswer, .profilesList, .sessionSwitchProfile, .sessionFork,
             .sessionSetModel, .worktreeCreate, .remoteProviders, .remoteCreate:
            return nil
        }
    }

    /// Puts `handler` in place of `method`'s own, for a test that stands in
    /// for a handler.
    func setHandler(_ handler: @escaping PhoneMethodHandler, for method: PhoneAppMethod) {
        replacedHandlers[method] = handler
    }

    /// A handler that decodes the request's params as `P`, calls `serve` with
    /// them, and replies with what `serve` returns.
    static func typed<P: Codable & Sendable, R: Codable & Sendable>(
        _ params: P.Type,
        _ serve: @escaping @Sendable (P, DeviceContext) async throws -> R
    ) -> PhoneMethodHandler {
        return { body, context in
            let decoded = try PhoneAppCoding.params(P.self, from: body)
            let result = try await serve(decoded, context)
            return try PhoneAppCoding.reply(requestID: context.requestID, result: result)
        }
    }

    /// Whether `method`'s replies go through the request memory.
    ///
    /// Every method that can change something does, so a resend acts once.
    /// The pure reads do not: their replies can be about 60 KB, and keeping
    /// them could crowd an action's entry out of the device's limit, while a
    /// repeated read only reads again.
    static func remembersReplies(of method: PhoneAppMethod) -> Bool {
        switch method {
        case .transcriptPage, .transcriptDetail, .profilesList, .remoteProviders:
            return false
        case .sessionsSubscribe, .transcriptOpen, .transcriptClose, .messageSend, .promptAnswer,
             .sessionSwitchProfile, .sessionFork, .sessionSetModel, .worktreeCreate, .remoteCreate:
            return true
        }
    }

    /// The record's target for `method`, read from the request's params, or
    /// nil for a method that is not recorded. Throws when the params do not
    /// decode, so a malformed request records nothing.
    ///
    /// The target is a session reference, `repo:<uuid>`, `provider:<name>`,
    /// or a fixed word for a method with no target: `sessions` for
    /// `sessions.subscribe` and `transcript` for `transcript.close`. It never
    /// holds a message, an answer, a model name or a form value.
    static func recordTarget(for method: PhoneAppMethod, body: Data) throws -> String? {
        let target: String
        switch method {
        case .sessionsSubscribe:
            _ = try PhoneAppCoding.params(SessionsSubscribeParams.self, from: body)
            target = "sessions"
        case .transcriptOpen:
            target = try PhoneAppCoding.params(TranscriptOpenParams.self, from: body).session.targetDescription
        case .transcriptClose:
            _ = try PhoneAppCoding.params(PhoneEmpty.self, from: body)
            target = "transcript"
        case .messageSend:
            target = try PhoneAppCoding.params(MessageSendParams.self, from: body).session.targetDescription
        case .promptAnswer:
            target = try PhoneAppCoding.params(PhonePromptAnswerParams.self, from: body).session.targetDescription
        case .sessionSwitchProfile:
            target = try PhoneAppCoding.params(SessionSwitchProfileParams.self, from: body).session.targetDescription
        case .sessionFork:
            target = try PhoneAppCoding.params(SessionForkParams.self, from: body).session.targetDescription
        case .sessionSetModel:
            target = try PhoneAppCoding.params(SessionSetModelParams.self, from: body).session.targetDescription
        case .worktreeCreate:
            let params = try PhoneAppCoding.params(PhoneWorktreeCreateParams.self, from: body)
            target = "repo:\(params.repoID.uuidString)"
        case .remoteCreate:
            let params = try PhoneAppCoding.params(PhoneRemoteCreateParams.self, from: body)
            target = "provider:\(params.provider)"
        case .transcriptPage, .transcriptDetail, .profilesList, .remoteProviders:
            return nil
        }
        return PhoneActionRecord.loggableTarget(target)
    }

    // MARK: - Sending

    /// Numbers an event on the device's stream, keeps it for a reconnect, and
    /// sends it while the phone is connected. While it is disconnected, the
    /// event is kept and not sent. Does nothing for a device with no state.
    /// The caller keeps the event within one frame.
    func emit<D: Codable & Sendable>(_ name: PhoneAppEventName, data: D, to deviceID: UUID) async {
        let bytes: Data?
        do {
            bytes = try devices[deviceID]?.stream.append(name, data: data)
        } catch {
            Self.logger.error("Phone app: could not encode a \(name.rawValue, privacy: .public) event: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let bytes else { return }
        send(bytes, to: deviceID)
    }

    /// Queues `body` on the device's connection, after everything queued
    /// before it. Does nothing while the phone is disconnected.
    func send(_ body: Data, to deviceID: UUID) {
        devices[deviceID]?.outbox?.enqueue(body)
    }

    // MARK: - Reading state

    /// The device's event stream ID, or nil when the service keeps no state
    /// for it.
    func streamID(for deviceID: UUID) -> String? {
        devices[deviceID]?.stream.streamID
    }

    /// The device's connection's resume decision, or nil when the service
    /// keeps no state for it.
    func resumeDecision(for deviceID: UUID) -> PhoneResumeDecision? {
        devices[deviceID]?.resume
    }

    /// How many of the device's requests are still running, cancelled ones
    /// included until they end.
    func requestsRunning(for deviceID: UUID) -> Int {
        requests[deviceID]?.count ?? 0
    }

    // MARK: - Replies

    private static let tooManyRequests = "Too many requests are in progress. Try again in a moment."

    private static func failure(_ requestID: String, _ code: PhoneAppErrorCode, _ message: String) -> Data {
        PhoneAppCoding.errorReply(requestID: requestID, PhoneAppError(code: code, message: message))
    }

    /// The reply of a run that was cancelled: an error, never a success.
    private static func stopped(_ requestID: String) -> Data {
        failure(requestID, .internalError, "The request was stopped before it finished.")
    }
}
