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
    /// For `transcript.open` and `transcript.close`: the stamp
    /// `handleAppMessage` gave the request as it arrived, which
    /// `PhoneDeviceState.transcriptStamp` also holds until a later one
    /// arrives. Nil for every other method.
    let transcriptStamp: UInt64?
}

/// Serves one method. It takes the whole request body and returns its reply:
/// usually the whole reply body, as `PhoneAppCoding.reply(requestID:result:)`
/// encodes it. For an error reply it throws: a `PhoneAppError` is sent as it
/// is, a `DecodingError` becomes `bad_request`, and anything else `internal`.
/// So a handler that decodes something other than its params, such as an
/// `RPCResponse`'s result, catches that error itself.
typealias PhoneMethodHandler = @Sendable (Data, DeviceContext) async throws -> PhoneHandlerReply

/// What a handler hands back.
enum PhoneHandlerReply: Sendable {
    /// The whole reply body, sent through the connection the phone has when
    /// the request finishes.
    case body(Data)
    /// Work that runs on the service, in the place where the reply would be
    /// sent, when the request finishes and the phone is connected: it queues
    /// the reply itself, then any events that must follow it. Nothing can
    /// come between, so a reply can name the stream's `seq` at that moment
    /// and the events after it start exactly there. Live events for a
    /// request start only after its reply this way. Only methods whose
    /// replies are not remembered may use it (see
    /// `PhoneAppService.remembersReplies(of:)`); for the others it is an
    /// `internal` error.
    case onQueue(@Sendable (isolated PhoneAppService) -> Void)
}

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
    /// Whether events go out on this connection. Only once its
    /// `sessions.subscribe` reply is queued: until then the phone's place in
    /// the stream is not settled, and the reply's replay or snapshot covers
    /// what came before. Events emitted meanwhile are numbered and kept, not
    /// sent. Every connect and disconnect clears it.
    var live = false
    /// The publisher keeping the phone's sessions list current, from its
    /// first `sessions.subscribe` until this state is dropped. It runs on
    /// while the phone is away, so a resume replays what changed.
    var sessions: PhoneSessionsFeed?
    /// The open session's `prompt.changed` feed: what the phone was last sent
    /// and the source that watches the session's prompts. Set by
    /// `openPrompts(_:for:)` when the open transcript's live part starts, and
    /// cleared by `closePrompts(for:)` on `transcript.close`.
    var prompts: PhonePromptFeed?
    /// The open transcript: its feed, which runs on while the phone is away
    /// so a resume replays what changed. Set by `transcript.open` and cleared
    /// by `transcript.close`.
    var transcript: PhoneTranscriptSlot?
    /// The stamp of the newest `transcript.open` or `transcript.close` the
    /// phone sent, in arrival order; nil before the first. Their handlers
    /// finish in any order, so an open takes effect only while its stamp is
    /// still this one, and a close leaves alone a feed opened after it.
    var transcriptStamp: UInt64?
    /// A `transcript.open` with `resume` whose reply waits for this
    /// connection to go live, so it follows the `sessions.subscribe` reply
    /// and the events that reply replays. Every connect and disconnect drops
    /// it, unanswered, as a reply to a connection that is gone.
    var pendingTranscriptResume: PendingTranscriptResume?
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
        await sessions?.publisher.stop()
        await prompts?.source?.stop()
        await transcript?.stop()
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
/// **A resend of a request still running starts nothing.** A phone resends
/// the requests it has no reply for when it reconnects. A request whose ID
/// and method match a request still running for that device starts no task,
/// does not count against `PhoneAppConstants.requestsInFlightPerDevice`, and
/// gets no reply of its own: the running request's reply goes to whichever
/// connection the phone has when it finishes. A request that reuses a running
/// request's ID for another method is no resend: it starts nothing and is
/// answered `bad_request` at once, so the phone does not wait out its timeout.
///
/// **The work, in order:**
/// 1. **The flag.** `phone_control_enabled` is read for every request. Off:
///    the reply is `phone_control_off` and nothing else happens, with the
///    request memory untouched, so a resend after the flag is turned on is not
///    answered "off" from memory. A failed read fails closed with `internal`.
///    The flag is read once, when the request starts. Turning it off stops the
///    bridge, which ends the phone's connection: requests already running
///    finish, as they do after a disconnect. Only a revoke cancels them.
/// 2. **The request memory**, for the methods that act on a session or create
///    something (see `remembersReplies(of:)`). The steps below run once per
///    request ID; a repeat gets the first run's reply.
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
/// **Events.** `emit(_:data:to:)` numbers every event on the device's stream.
/// It sends one only once the connection's `sessions.subscribe` reply is
/// queued (`PhoneDeviceState.live`), so a phone never sees events before the
/// reply that tells it where the stream stands.
///
/// **Extending it.** A later task serves a method by returning its handler
/// from `registeredHandler(for:)`, usually built with `typed(_:_:)`, and keeps
/// per-device state in `PhoneDeviceState`, stopping it in
/// `PhoneDeviceState.shutDown()`. A handler whose reply must be followed by
/// events, or must say where the stream stands, returns
/// `PhoneHandlerReply.onQueue`. Code in other files reads and changes
/// `devices` entries in place; only the lifecycle methods add or remove one.
actor PhoneAppService: PhoneAppHandling {
    /// The log of the service and every extension of it.
    static let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    /// The reply to a known method no task serves yet.
    private static let notServed = PhoneAppError(code: .unavailable, message: "This TBD build cannot do that from a phone yet.")

    let db: TBDDatabase
    let actions: any PhoneSessionActions
    let subscriptions: StateSubscriptionManager
    let pendingPrompts: PendingPromptStore
    let recorder: any PhoneActionRecording
    /// Reads `phone_control_enabled`, for every request and every resume
    /// decision: `db.config`, unless the init was handed a reader, as a test
    /// does to hold a read still.
    let readPhoneControl: @Sendable () async throws -> Bool
    /// The transcript file of a terminal in the worktree at the path given,
    /// as the terminal row names it (`ClaudeTranscriptLocator.filePath` under
    /// the daemon's `projects/` roots), or nil.
    let locateTranscript: @Sendable (TBDShared.Terminal, _ worktreePath: String) -> String?
    let now: @Sendable () -> Date
    let clock: any Clock<Duration>
    /// Request IDs and their replies, per device.
    let memory: PhoneRequestMemory
    /// Which phone is answering, or answered, which prompt, across every
    /// device, for `prompt.changed`'s `answeredBy`.
    var phoneAnswerLedger = PhonePromptAnswerLedger()

    /// Each phone the service keeps state for, by device ID.
    var devices: [UUID: PhoneDeviceState] = [:]
    /// Handlers a test put in place of a method's own.
    private var replacedHandlers: [PhoneAppMethod: PhoneMethodHandler] = [:]
    /// One request still running: its ID and method, which a resend repeats,
    /// and its task.
    private struct RunningRequest {
        let requestID: String
        let method: PhoneAppMethod
        let task: Task<Void, Never>
    }
    /// Each device's requests still running, by a token per request. No two
    /// of a device's running requests share an ID.
    private var requests: [UUID: [UInt64: RunningRequest]] = [:]
    private var nextToken: UInt64 = 0

    init(db: TBDDatabase, actions: any PhoneSessionActions, subscriptions: StateSubscriptionManager,
         pendingPrompts: PendingPromptStore,
         locateTranscript: @escaping @Sendable (TBDShared.Terminal, _ worktreePath: String) -> String?,
         recorder: any PhoneActionRecording = LoggerPhoneActionRecorder(),
         readPhoneControl: (@Sendable () async throws -> Bool)? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         clock: any Clock<Duration> = ContinuousClock()) {
        self.db = db
        self.actions = actions
        self.subscriptions = subscriptions
        self.pendingPrompts = pendingPrompts
        self.locateTranscript = locateTranscript
        self.recorder = recorder
        if let readPhoneControl {
            self.readPhoneControl = readPhoneControl
        } else {
            self.readPhoneControl = { [db] in try await db.config.get().phoneControlEnabled }
        }
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
        state.live = false
        state.pendingTranscriptResume = nil
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
        state.live = false
        state.pendingTranscriptResume = nil
        state.grace?.cancel()
        let token = mintToken()
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
            request.task.cancel()
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
    /// connection, for a request whose ID is longer than
    /// `PhoneAppConstants.requestIDMaxBytes`, or for a resend of a request
    /// still running, which gets no reply of its own; a request that reuses a
    /// running request's ID for another method, and a device with
    /// `PhoneAppConstants.requestsInFlightPerDevice` requests running, are
    /// refused. None of these reach the request memory or the flag. Nor does
    /// anything run for a `sessions.subscribe` whose connection ended while
    /// `decideResume` read the flag (see there).
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
        // The connection the request arrived through, which a `phoneConnected`
        // replaces with a new queue.
        guard let connection = devices[deviceID]?.outbox else {
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
        if let running = requests[deviceID]?.values.first(where: { $0.requestID == requestID }) {
            // A resend after a reconnect, while the first run is still going.
            // The first run's reply goes to whichever connection is current
            // when it finishes, so this one starts nothing and sends nothing.
            guard running.method.rawValue == head.method else {
                Self.logger.error(
                    "Phone app: refused a request from phone \(deviceID, privacy: .public) whose ID is in use by another method")
                send(Self.failure(requestID, .badRequest, Self.requestIDInUse), to: deviceID)
                return
            }
            Self.logger.debug("Phone app: a resent request from phone \(deviceID, privacy: .public) is still running")
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
            guard await decideResume(body, deviceID: deviceID, connection: connection) else {
                Self.logger.debug(
                    "Phone app: abandoned a sessions.subscribe from phone \(deviceID, privacy: .public), whose connection ended while it was read")
                return
            }
        }
        var transcriptStamp: UInt64?
        if method == .transcriptOpen || method == .transcriptClose {
            transcriptStamp = stampTranscriptRequest(deviceID: deviceID)
        }
        start(method, body: body, context: DeviceContext(
            peer: peer, requestID: requestID, transcriptStamp: transcriptStamp))
    }

    /// A new stamp for a `transcript.open` or `transcript.close` that just
    /// arrived, kept as the device's newest. Stamps grow with arrival, since
    /// they come from `mintToken()`. Stamping only orders the requests, so it
    /// happens whatever the flag says: a request made while phone control is
    /// off still calls nothing.
    private func stampTranscriptRequest(deviceID: UUID) -> UInt64 {
        let stamp = mintToken()
        devices[deviceID]?.transcriptStamp = stamp
        return stamp
    }

    /// Makes this connection's resume decision for a `sessions.subscribe`,
    /// before `handleAppMessage` returns, so the phone's next message sees it.
    ///
    /// The flag is read first, so a request made while phone control is off
    /// changes nothing. From the replay to the store there is no suspension,
    /// so the decision holds exactly the events the stream held at that
    /// moment. Params that do not decode leave the decision alone; the
    /// request's work answers them `bad_request`.
    ///
    /// **Returns false when the request's connection is gone.** The service
    /// can run a disconnect and a connect while the flag read is suspended.
    /// When `connection`, the queue the request arrived through, is no
    /// longer the device's once the read returns, the request is abandoned:
    /// it decides nothing and `handleAppMessage` starts nothing, so the new
    /// connection's decision stays its own, and its own `sessions.subscribe`
    /// (a phone resends what it has no reply for) is not taken for a resend
    /// of one still running.
    private func decideResume(_ body: Data, deviceID: UUID, connection: PhoneOutboxQueue) async -> Bool {
        guard let params = try? PhoneAppCoding.params(SessionsSubscribeParams.self, from: body) else {
            return true
        }
        let enabled = (try? await readPhoneControl()) == true
        guard let state = devices[deviceID], state.outbox === connection else {
            return false
        }
        guard enabled else { return true }
        if let missed = state.stream.replay(stream: params.stream, sinceSeq: params.sinceSeq) {
            devices[deviceID]?.resume = .replay(missed)
        } else {
            devices[deviceID]?.resume = .snapshot
        }
        return true
    }

    /// Starts the request's work in a task of the service's own. Only
    /// `phoneRevoked` cancels it.
    private func start(_ method: PhoneAppMethod, body: Data, context: DeviceContext) {
        let deviceID = context.peer.deviceID
        let token = mintToken()
        // The task runs on this actor between its suspensions, so it cannot
        // finish before it is stored.
        let task = Task {
            let reply = await self.serve(method, body: body, context: context)
            self.requestFinished(token, deviceID: deviceID, reply: reply)
        }
        requests[deviceID, default: [:]][token] = RunningRequest(
            requestID: context.requestID, method: method, task: task)
    }

    /// Sends a finished request's reply through the connection the phone has
    /// now, or runs the handler's work in its place while the phone is
    /// connected. A request cancelled by a revoke sends nothing.
    private func requestFinished(_ token: UInt64, deviceID: UUID, reply: PhoneHandlerReply) {
        requests[deviceID]?[token] = nil
        if requests[deviceID]?.isEmpty == true {
            requests[deviceID] = nil
        }
        guard !Task.isCancelled else { return }
        switch reply {
        case .body(let body):
            send(body, to: deviceID)
        case .onQueue(let work):
            guard devices[deviceID]?.outbox != nil else { return }
            work(self)
        }
    }

    /// The request's work: the flag, then the request memory around
    /// `perform`. Runs off the actor, so one phone's slow request holds up
    /// nothing else.
    private nonisolated func serve(_ method: PhoneAppMethod, body: Data, context: DeviceContext) async -> PhoneHandlerReply {
        let requestID = context.requestID
        let enabled: Bool
        do {
            enabled = try await readPhoneControl()
        } catch {
            Self.logger.error(
                "Phone app: could not read the phone control setting: \(Self.errorType(error), privacy: .public): \(error.localizedDescription, privacy: .private)")
            return .body(Self.failure(requestID, .internalError, "TBD could not read its phone control setting. Try again."))
        }
        guard enabled else {
            return .body(Self.failure(requestID, .phoneControlOff, "Phone control is off on this laptop."))
        }
        guard !Task.isCancelled else { return .body(Self.stopped(requestID)) }
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
                switch await self.perform(method, body: body, context: context) {
                case .body(let reply):
                    return reply
                case .onQueue:
                    // Work on the service cannot be kept for a resend.
                    Self.logger.fault("Phone app: \(method.rawValue, privacy: .public) is remembered and cannot run on the queue")
                    return Self.failure(requestID, .internalError, Self.internalErrorReason)
                }
            })
        return .body(reply)
    }

    /// The part of a request that acts, run once per request ID when its
    /// replies are remembered: the pairing check, the record, the handler.
    /// A request cancelled by a revoke before its record stops there, so it
    /// neither records nor acts.
    private nonisolated func perform(_ method: PhoneAppMethod, body: Data, context: DeviceContext) async -> PhoneHandlerReply {
        let requestID = context.requestID
        do {
            guard try await db.phoneDevices.device(id: context.peer.deviceID) != nil else {
                return .body(Self.failure(requestID, .refused, "This phone is no longer paired."))
            }
        } catch {
            Self.logger.error(
                "Phone app: could not read a phone's pairing: \(Self.errorType(error), privacy: .public): \(error.localizedDescription, privacy: .private)")
            return .body(Self.failure(requestID, .internalError, "TBD could not check this phone's pairing. Try again."))
        }
        guard let handler = await registeredHandler(for: method) else {
            return .body(PhoneAppCoding.errorReply(requestID: requestID, Self.notServed))
        }
        guard !Task.isCancelled else { return .body(Self.stopped(requestID)) }
        do {
            if let target = try Self.recordTarget(for: method, body: body) {
                recorder.record(PhoneActionRecord(deviceName: context.peer.deviceName, action: method.rawValue, target: target))
            }
            let reply = try await handler(body, context)
            guard !Task.isCancelled else { return .body(Self.stopped(requestID)) }
            return reply
        } catch let error as PhoneAppError {
            return .body(PhoneAppCoding.errorReply(requestID: requestID, error))
        } catch is DecodingError {
            return .body(Self.failure(requestID, .badRequest, "The request's params are not valid."))
        } catch is CancellationError {
            return .body(Self.stopped(requestID))
        } catch {
            // Only the error's type is public: its description can quote what
            // the handler was working on, such as a path or a message.
            Self.logger.error(
                "Phone app: \(method.rawValue, privacy: .public) failed: \(Self.errorType(error), privacy: .public): \(error.localizedDescription, privacy: .private)")
            return .body(Self.failure(requestID, .internalError, Self.internalErrorReason))
        }
    }

    /// The error's type name, the part of an error the log keeps public.
    static func errorType(_ error: any Error) -> String {
        String(describing: type(of: error))
    }

    // MARK: - Handlers

    /// The one place a method gets its handler; nil while no task serves it.
    /// A later task serves a method by returning its handler here, as in
    /// `case .messageSend: return Self.typed(MessageSendParams.self) { [self] p, context in try await self.messageSend(p, context) }`.
    /// A handler a test put in place with `setHandler(_:for:)` comes first.
    func registeredHandler(for method: PhoneAppMethod) -> PhoneMethodHandler? {
        if let replaced = replacedHandlers[method] {
            return replaced
        }
        switch method {
        case .sessionsSubscribe:
            return { [self] body, context in
                let params = try PhoneAppCoding.params(SessionsSubscribeParams.self, from: body)
                return try await self.sessionsSubscribe(params, context)
            }
        case .messageSend:
            return Self.typed(MessageSendParams.self) { [self] params, context in
                try await self.messageSend(params, context)
            }
        case .sessionSetModel:
            return Self.typed(SessionSetModelParams.self) { [self] params, context in
                try await self.sessionSetModel(params, context)
            }
        case .promptAnswer:
            return Self.typed(PhonePromptAnswerParams.self) { [self] params, context in
                try await self.promptAnswer(params, context)
            }
        case .profilesList:
            return Self.typed(PhoneEmpty.self) { [self] params, context in
                try await self.profilesList(params, context)
            }
        case .sessionSwitchProfile:
            return Self.typed(SessionSwitchProfileParams.self) { [self] params, context in
                try await self.sessionSwitchProfile(params, context)
            }
        case .sessionFork:
            return Self.typed(SessionForkParams.self) { [self] params, context in
                try await self.sessionFork(params, context)
            }
        case .worktreeCreate:
            return Self.typed(PhoneWorktreeCreateParams.self) { [self] params, context in
                try await self.worktreeCreate(params, context)
            }
        case .remoteProviders:
            return Self.typed(PhoneRemoteProvidersParams.self) { [self] params, context in
                try await self.remoteProviders(params, context)
            }
        case .remoteCreate:
            return Self.typed(PhoneRemoteCreateParams.self) { [self] params, context in
                try await self.remoteCreate(params, context)
            }
        case .transcriptOpen:
            return { [self] body, context in
                let params = try PhoneAppCoding.params(TranscriptOpenParams.self, from: body)
                return try await self.transcriptOpen(params, context)
            }
        case .transcriptPage:
            return Self.typed(TranscriptPageParams.self) { [self] params, context in
                try await self.transcriptPage(params, context)
            }
        case .transcriptClose:
            return Self.typed(PhoneEmpty.self) { [self] params, context in
                try await self.transcriptClose(params, context)
            }
        case .transcriptDetail:
            return Self.typed(TranscriptDetailParams.self) { [self] params, context in
                try await self.transcriptDetail(params, context)
            }
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
            return .body(try PhoneAppCoding.reply(requestID: context.requestID, result: result))
        }
    }

    /// Whether `method`'s replies go through the request memory.
    ///
    /// Only the methods that act on a session or create something do, so a
    /// resend of one of them acts once. That narrows spec section 4.4, which
    /// says every request; the rest run again on a resend, which is safe:
    /// - **The pure reads** (`transcript.page`, `transcript.detail`,
    ///   `profiles.list`, `remote.providers`) only read again. Their replies
    ///   can be about 60 KB, and keeping them could crowd an action's entry
    ///   out of the device's limit.
    /// - **The state requests** (`sessions.subscribe`, `transcript.open`,
    ///   `transcript.close`) set up or tear down what the phone is sent. A
    ///   remembered `sessions.subscribe` reply would hand back a stale
    ///   snapshot, and after the grace a stream ID that no longer exists.
    static func remembersReplies(of method: PhoneAppMethod) -> Bool {
        switch method {
        case .messageSend, .promptAnswer, .sessionSwitchProfile, .sessionFork, .sessionSetModel,
             .worktreeCreate, .remoteCreate:
            return true
        case .sessionsSubscribe, .transcriptOpen, .transcriptPage, .transcriptDetail, .transcriptClose,
             .profilesList, .remoteProviders:
            return false
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
    /// sends it while the connection is live (see `PhoneDeviceState.live`).
    /// Otherwise, and while the phone is disconnected, the event is kept and
    /// not sent. Does nothing for a device with no state. The caller keeps
    /// the event within one frame.
    func emit<D: Codable & Sendable>(_ name: PhoneAppEventName, data: D, to deviceID: UUID) {
        let bytes: Data?
        do {
            bytes = try devices[deviceID]?.stream.append(name, data: data)
        } catch {
            Self.logger.error(
                "Phone app: could not encode a \(name.rawValue, privacy: .public) event: \(Self.errorType(error), privacy: .public): \(error.localizedDescription, privacy: .private)")
            return
        }
        guard let bytes, devices[deviceID]?.live == true else { return }
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
    /// The reply to a request that reuses a running request's ID for another
    /// method.
    static let requestIDInUse = "That request ID is already in use."
    /// The `internal` error's words for a failure on the laptop.
    static let internalErrorReason = "Something went wrong on the laptop."

    /// A new token, unique for this service's life, to tell one run of
    /// something from a later one.
    func mintToken() -> UInt64 {
        let token = nextToken
        nextToken &+= 1
        return token
    }

    static func failure(_ requestID: String, _ code: PhoneAppErrorCode, _ message: String) -> Data {
        PhoneAppCoding.errorReply(requestID: requestID, PhoneAppError(code: code, message: message))
    }

    /// The reply of a run that was cancelled: an error, never a success.
    private static func stopped(_ requestID: String) -> Data {
        failure(requestID, .internalError, "The request was stopped before it finished.")
    }
}
