import Foundation
import os
import TBDShared

// `transcript.open`, `transcript.page` and `transcript.close` (spec section 7):
// one open transcript per phone, held in `PhoneDeviceState.transcript`, with
// the session's `prompt.changed` feed beside it.

/// A `transcript.open` with `resume` waiting for its connection to go live
/// (`PhoneDeviceState.pendingTranscriptResume`).
struct PendingTranscriptResume: Sendable {
    let params: TranscriptOpenParams
    let requestID: String
    let stamp: UInt64
}

/// A device's open transcript: its feed, the relay that hands the feed its
/// terminal's state deltas, and whether the live part has started. A remote
/// session's feed has no relay: its follower syncs the cache instead.
struct PhoneTranscriptSlot: Sendable {
    /// Tells this slot's events from those of a slot it replaced.
    let token: UInt64
    /// The stamp of the `transcript.open` that installed or last resumed
    /// this slot (`PhoneDeviceState.transcriptStamp`).
    var stamp: UInt64
    let session: PhoneSessionRef
    let showDetails: Bool
    let feed: TranscriptFeed
    /// Nil until the live part starts, and for a session with no terminal.
    var relay: TranscriptDeltaRelay?
    /// Whether the live part has started: it starts once the connection is
    /// live, so its events follow the `transcript.open` reply.
    var started: Bool

    /// Stops the relay and closes the feed, its watcher with it.
    func stop() async {
        await relay?.stop()
        await feed.close()
    }
}

/// Hands one terminal's state deltas to a transcript feed, in order.
///
/// The subscriber checks each encoded delta for the terminal's ID before it
/// decodes anything, so the deltas of every other terminal cost one byte
/// search. One task forwards the rest to `TranscriptFeed.noteDelta(_:)`.
/// `stop()` removes the subscriber and ends the task for good; a later
/// `start()` does nothing.
actor TranscriptDeltaRelay {
    /// The most deltas held for the feed. The feed only sets flags on each,
    /// so it falls this far behind only if it is stuck.
    static let bufferLimit = 256

    private let terminalID: UUID
    private let marker: Data
    private let subscriptions: StateSubscriptionManager
    private let feed: TranscriptFeed
    private var subscriberID: StateSubscriptionManager.SubscriberID?
    private var deltas: AsyncStream<StateDelta>.Continuation?
    private var consumer: Task<Void, Never>?
    private var stopped = false

    init(terminalID: UUID, subscriptions: StateSubscriptionManager, feed: TranscriptFeed) {
        self.terminalID = terminalID
        // `StateSubscriptionManager` encodes a UUID as its uppercase string.
        self.marker = Data(terminalID.uuidString.utf8)
        self.subscriptions = subscriptions
        self.feed = feed
    }

    /// Whether the relay is subscribed: between `start` and `stop`. For
    /// tests.
    var isSubscribed: Bool {
        subscriberID != nil
    }

    func start() {
        guard !stopped, consumer == nil else { return }
        let (stream, continuation) = AsyncStream<StateDelta>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.bufferLimit))
        deltas = continuation
        let marker = self.marker
        subscriberID = subscriptions.addSubscriber { data in
            if data.range(of: marker) != nil,
               let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                continuation.yield(delta)
            }
            return true
        }
        let feed = self.feed
        consumer = Task {
            for await delta in stream {
                guard !Task.isCancelled else { return }
                await feed.noteDelta(delta)
            }
        }
    }

    func stop() {
        stopped = true
        if let subscriberID {
            subscriptions.removeSubscriber(subscriberID)
            self.subscriberID = nil
        }
        deltas?.finish()
        deltas = nil
        consumer?.cancel()
        consumer = nil
    }
}

/// The open transcript.
///
/// **`transcript.open`** resolves a local session through
/// `phoneVisibleTerminal`, so the phone opens nothing the laptop no longer
/// shows it, and opens only a Claude session in a local worktree. The
/// transcript path comes from the terminal row (`locateTranscript`), never
/// from the phone. A remote session needs its provider registered and
/// declaring `transcript.read` (`unsupported` otherwise), and must be one the
/// sessions list shows (`not_found` otherwise, `checkPhoneCapableRemoteSession`);
/// its transcript is the daemon's cache, whose path comes from a sync
/// (`RemoteTranscriptFollower`), and a sync that fails is the reply's error,
/// in its own words only when it carries a code (`remoteRefusal(_:method:)`).
/// The reply goes out through `.onQueue`, so the stream's
/// `seq` it names is where the session's events start, and the feed and the
/// prompt feed start only once the connection is live
/// (`startTranscript(for:)`): at once when the phone's `sessions.subscribe`
/// reply is already queued, and otherwise right after that reply. Events the
/// feed would have sent in between are read by its first step, so none is
/// lost. Opening replaces any transcript the device had open, and stops its
/// feed.
///
/// **Resume.** A `transcript.open` with `resume`, on a connection whose
/// `sessions.subscribe` replays the stream (`canResumeTranscript`), for the
/// session and `showDetails` of the open feed, keeps that feed: the reply is
/// `{resumed: true, seq}` with no page. The reply waits until the connection
/// is live, so it follows the subscribe reply and every event that replays,
/// all with a `seq` at most its own. The feed and the prompt feed ran on
/// while the phone was away, so the replay carries what the phone missed,
/// the current prompt set included. Any other open starts over from the
/// tail. A resume first passes the checks a fresh open makes, with the same
/// refusals (`checkTranscript`), so a phone that comes back inside the grace
/// keeps a feed only for a session the laptop still shows it. The resume
/// check runs right after them, before anything is built: a resumed remote
/// open builds no follower and makes no sync, since the kept feed's own
/// follower runs on.
///
/// **Order.** Opens and closes take effect in the order the phone sent them,
/// though their handlers can finish in any order. `handleAppMessage` stamps
/// each as it arrives (`PhoneDeviceState.transcriptStamp`). An open installs
/// or resumes a feed only while its stamp is still the newest; otherwise a
/// later open or close came after it, so it replies `transcriptChangedReason`
/// and closes the feed it built. A close stops only a feed whose open came
/// before it.
///
/// **`transcript.page`** needs an open feed for the same session, or it is
/// `not_open`. **`transcript.close`** stops the feed and the prompt feed.
/// The grace after a disconnect, and a revoke, stop them too
/// (`PhoneDeviceState.shutDown()`).
extension PhoneAppService {
    static let notAClaudeTranscriptReason = "Only a Claude session has a transcript."
    static let noTranscriptReadReason = "This provider does not support reading transcripts."
    static let transcriptNotOpenReason = "That transcript is not open. Open it again."
    static let transcriptChangedReason = "The transcript changed while it was opened. Try again."

    // MARK: - transcript.open

    nonisolated func transcriptOpen(_ params: TranscriptOpenParams, _ context: DeviceContext) async throws -> PhoneHandlerReply {
        let deviceID = context.peer.deviceID
        let requestID = context.requestID
        guard let stamp = context.transcriptStamp else {
            // `handleAppMessage` stamps every `transcript.open`.
            Self.logger.fault("Phone transcript: an open arrived with no stamp")
            throw PhoneAppError(code: .internalError, message: Self.internalErrorReason)
        }
        let worktreeRoot = try await checkTranscript(params.session)
        if params.resume, await canResumeTranscript(params, deviceID: deviceID) {
            return .onQueue { service in
                service.queueResumedTranscript(params, stamp: stamp, requestID: requestID, deviceID: deviceID)
            }
        }
        let source: TranscriptFeedSource
        switch params.session {
        case .remote(let provider, let sessionID):
            try Task.checkCancellation()
            source = .remote(RemoteTranscriptFollower(
                provider: provider, sessionID: sessionID, actions: actions, clock: clock))
        case .local(let terminalID):
            source = .local(terminalID: terminalID, resolvePath: { [weak self] in
                await self?.transcriptPath(of: terminalID)
            })
        }
        let token = await mintToken()
        let feed = TranscriptFeed(
            session: params.session, showDetails: params.showDetails, source: source,
            emit: { [weak self] event in
                await self?.emitTranscript(event, to: deviceID, token: token)
            },
            worktreeRoot: worktreeRoot,
            clock: clock)
        let page: TranscriptPage
        do {
            page = try await feed.open()
            try Task.checkCancellation()
        } catch {
            await feed.close()
            throw error
        }
        return Self.openedTranscriptReply(
            params, feed: feed, token: token, stamp: stamp, page: page, requestID: requestID, deviceID: deviceID)
    }

    /// The reply of a fresh open whose `feed` has its first `page`: work on
    /// the queue that installs the feed (`queueOpenedTranscript`), or, when
    /// that work never runs because the phone went away or a revoke
    /// cancelled the request, closes the feed and with it the follower.
    static func openedTranscriptReply(
        _ params: TranscriptOpenParams, feed: TranscriptFeed, token: UInt64, stamp: UInt64, page: TranscriptPage,
        requestID: String, deviceID: UUID
    ) -> PhoneHandlerReply {
        .onQueue({ service in
            service.queueOpenedTranscript(
                params, feed: feed, token: token, stamp: stamp, page: page, requestID: requestID, deviceID: deviceID)
        }, dropped: {
            Task {
                await feed.close()
            }
        })
    }

    /// Checks that the phone may open `session`'s transcript, for a fresh
    /// open and a resume alike: a local tab (`checkLocalTranscript`) or a
    /// remote session (`checkRemoteTranscript`) the laptop still shows it.
    /// Returns a local tab's worktree path, so the feed sends file-edit paths
    /// inside it relative to it, and nil for a remote session.
    private nonisolated func checkTranscript(_ session: PhoneSessionRef) async throws -> String? {
        switch session {
        case .local(let terminalID):
            return try await checkLocalTranscript(terminalID)
        case .remote(let provider, let sessionID):
            try await checkRemoteTranscript(provider: provider, sessionID: sessionID)
            return nil
        }
    }

    /// Checks that the phone may open `terminalID`'s transcript: a terminal
    /// it can see (`phoneVisibleTerminal`), in a local worktree, running
    /// Claude. Returns the worktree's path.
    private nonisolated func checkLocalTranscript(_ terminalID: UUID) async throws -> String {
        let (terminal, worktree) = try await phoneVisibleTerminal(terminalID)
        guard worktree.location.isLocal else {
            throw PhoneAppError(code: .unsupported, message: PhoneSessionStatus.remoteLaneTabReason)
        }
        switch PhoneSnapshotBuilder.agent(of: terminal) {
        case .claude:
            break
        case .codex:
            throw PhoneAppError(code: .unavailable, message: PhoneSessionStatus.codexTranscriptReason)
        case .remote, nil:
            throw PhoneAppError(code: .unsupported, message: Self.notAClaudeTranscriptReason)
        }
        return worktree.localPath
    }

    /// Checks that the phone may open a remote session's transcript. Its
    /// provider must be registered (`not_found` otherwise) and declare
    /// `transcript.read`, as the sessions list reads it (`unsupported`
    /// otherwise), and the session must be one the sessions list shows: in
    /// the laptop's remote session list, not dismissed, and not matched to a
    /// hidden repo (`not_found` otherwise). A list the daemon refuses to give
    /// is `refused`. See `checkPhoneCapableRemoteSession`.
    private nonisolated func checkRemoteTranscript(provider: String, sessionID: String) async throws {
        try await checkPhoneCapableRemoteSession(
            provider: provider, sessionID: sessionID, needing: { $0.transcript }, orElse: Self.noTranscriptReadReason)
    }

    /// Whether `params` may keep the device's open feed: the connection's
    /// `sessions.subscribe` decided to replay, a sessions publisher runs to
    /// carry the stream on, so that subscribe's reply replays it (see
    /// `sessionsSubscribe`), and the feed is for the same session and
    /// `showDetails`. Once the connection is live, a decision still `replay`
    /// means the reply did replay, since a snapshot reply sets it to
    /// `snapshot`.
    func canResumeTranscript(_ params: TranscriptOpenParams, deviceID: UUID) -> Bool {
        guard let state = devices[deviceID], case .replay = state.resume, state.sessions != nil,
              let slot = state.transcript else { return false }
        return slot.session == params.session && slot.showDetails == params.showDetails
    }

    /// Answers a resumed open once the connection is live, so the reply
    /// follows the `sessions.subscribe` reply and its replay. Before that it
    /// waits in `pendingTranscriptResume`, in place of any earlier one, which
    /// is refused, and `transcriptConnectionWentLive(for:)` answers it. When
    /// a later open or close came after this open, the reply is
    /// `transcriptChangedReason` at once.
    func queueResumedTranscript(_ params: TranscriptOpenParams, stamp: UInt64, requestID: String, deviceID: UUID) {
        guard let state = devices[deviceID], state.transcriptStamp == stamp else {
            refuseChangedTranscript(requestID, deviceID: deviceID)
            return
        }
        guard state.live else {
            if let earlier = state.pendingTranscriptResume {
                refuseChangedTranscript(earlier.requestID, deviceID: deviceID)
            }
            devices[deviceID]?.pendingTranscriptResume = PendingTranscriptResume(
                params: params, requestID: requestID, stamp: stamp)
            return
        }
        resumeTranscript(params, stamp: stamp, requestID: requestID, deviceID: deviceID)
    }

    /// Replies `{resumed: true, seq}` and keeps the feed, starting its live
    /// part if it never started. When a later open or close came after this
    /// open, the connection is not live, or the feed changed since the
    /// handler looked, the reply is `transcriptChangedReason` and the phone
    /// opens again.
    private func resumeTranscript(_ params: TranscriptOpenParams, stamp: UInt64, requestID: String, deviceID: UUID) {
        guard let state = devices[deviceID], state.transcriptStamp == stamp, state.live,
              canResumeTranscript(params, deviceID: deviceID) else {
            refuseChangedTranscript(requestID, deviceID: deviceID)
            return
        }
        let result = TranscriptOpenResult(resumed: true, seq: state.stream.lastSeq, page: nil)
        guard let reply = try? PhoneAppCoding.reply(requestID: requestID, result: result) else {
            send(Self.failure(requestID, .internalError, Self.internalErrorReason), to: deviceID)
            return
        }
        devices[deviceID]?.transcript?.stamp = stamp
        send(reply, to: deviceID)
        startTranscript(for: deviceID)
    }

    /// Installs a freshly opened feed in place of the device's earlier one,
    /// replies with its first page, and starts its live part when the
    /// connection is live. Until then the earlier session's prompt feed is
    /// stopped, and this session's starts with the live part. When a later
    /// open or close came after this open, it installs nothing, replies
    /// `transcriptChangedReason` and closes `feed`; a reply that does not
    /// encode closes `feed` too.
    func queueOpenedTranscript(
        _ params: TranscriptOpenParams, feed: TranscriptFeed, token: UInt64, stamp: UInt64, page: TranscriptPage,
        requestID: String, deviceID: UUID
    ) {
        guard let state = devices[deviceID], state.transcriptStamp == stamp else {
            refuseChangedTranscript(requestID, deviceID: deviceID)
            Task {
                await feed.close()
            }
            return
        }
        let result = TranscriptOpenResult(resumed: false, seq: state.stream.lastSeq, page: page)
        guard let reply = try? PhoneAppCoding.reply(requestID: requestID, result: result) else {
            Self.logger.error("Phone transcript: the open reply does not encode")
            send(Self.failure(requestID, .internalError, Self.internalErrorReason), to: deviceID)
            Task {
                await feed.close()
            }
            return
        }
        let earlier = state.transcript
        devices[deviceID]?.transcript = PhoneTranscriptSlot(
            token: token, stamp: stamp, session: params.session, showDetails: params.showDetails,
            feed: feed, relay: nil, started: false)
        send(reply, to: deviceID)
        if devices[deviceID]?.live == true {
            startTranscript(for: deviceID)
        } else {
            closePrompts(for: deviceID)
        }
        if let earlier {
            Task {
                await earlier.stop()
            }
        }
    }

    /// The connection just went live, its `sessions.subscribe` reply and any
    /// replay queued: answers a resumed open that waited for this, then
    /// starts the open feed's live part.
    func transcriptConnectionWentLive(for deviceID: UUID) {
        if let pending = devices[deviceID]?.pendingTranscriptResume {
            devices[deviceID]?.pendingTranscriptResume = nil
            resumeTranscript(pending.params, stamp: pending.stamp, requestID: pending.requestID, deviceID: deviceID)
        }
        startTranscript(for: deviceID)
    }

    /// Refuses a resumed open still waiting for the connection to go live,
    /// when the `sessions.subscribe` it waits on failed, so the phone does
    /// not wait for its reply.
    func refusePendingTranscriptResume(for deviceID: UUID) {
        guard let pending = devices[deviceID]?.pendingTranscriptResume else { return }
        devices[deviceID]?.pendingTranscriptResume = nil
        refuseChangedTranscript(pending.requestID, deviceID: deviceID)
    }

    /// Whether a resumed open waits for the connection to go live. For
    /// tests.
    func hasPendingTranscriptResume(for deviceID: UUID) -> Bool {
        devices[deviceID]?.pendingTranscriptResume != nil
    }

    /// Starts the device's open feed's live part, with its relay and the
    /// session's prompt feed, once the connection is live. A remote session
    /// has no relay; its feed's follower syncs the cache. Does nothing with
    /// no feed, a feed already started, or a connection that is not live yet:
    /// `transcriptConnectionWentLive(for:)` calls this again when the
    /// connection goes live.
    func startTranscript(for deviceID: UUID) {
        guard devices[deviceID]?.live == true, var slot = devices[deviceID]?.transcript, !slot.started else {
            return
        }
        slot.started = true
        let relay: TranscriptDeltaRelay?
        if case .local(let terminalID) = slot.session {
            relay = TranscriptDeltaRelay(terminalID: terminalID, subscriptions: subscriptions, feed: slot.feed)
        } else {
            relay = nil
        }
        slot.relay = relay
        devices[deviceID]?.transcript = slot
        openPrompts(slot.session, for: deviceID)
        let feed = slot.feed
        // The relay subscribes before the feed's first read, so no delta
        // falls between them. A stop that comes first leaves both stopped.
        Task {
            await relay?.start()
            await feed.start()
        }
    }

    /// Replies to an open that can no longer take effect, so the phone opens
    /// again.
    func refuseChangedTranscript(_ requestID: String, deviceID: UUID) {
        send(Self.failure(requestID, .internalError, Self.transcriptChangedReason), to: deviceID)
    }

    /// Emits a feed's event, unless a later open replaced the feed.
    func emitTranscript(_ event: TranscriptFeedEvent, to deviceID: UUID, token: UInt64) {
        guard devices[deviceID]?.transcript?.token == token else { return }
        switch event {
        case .append(let data):
            emit(.transcriptAppend, data: data, to: deviceID)
        case .update(let data):
            emit(.transcriptUpdate, data: data, to: deviceID)
        case .reset(let data):
            emit(.transcriptReset, data: data, to: deviceID)
        }
    }

    /// The transcript file of `terminalID` as its row names it now, or nil
    /// when the row or its worktree is gone or names none.
    func transcriptPath(of terminalID: UUID) async -> String? {
        do {
            guard let terminal = try await db.terminals.get(id: terminalID),
                  let worktree = try await db.worktrees.get(id: terminal.worktreeID) else { return nil }
            return locateTranscript(terminal, worktree.localPath)
        } catch {
            Self.logger.error(
                "Phone transcript: could not read a terminal row: \(Self.errorType(error), privacy: .public): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    // MARK: - transcript.page

    nonisolated func transcriptPage(_ params: TranscriptPageParams, _ context: DeviceContext) async throws -> TranscriptPage {
        guard let feed = await openTranscriptFeed(for: params.session, deviceID: context.peer.deviceID) else {
            throw PhoneAppError(code: .notOpen, message: Self.transcriptNotOpenReason)
        }
        return try await feed.olderPage(cursor: params.cursor)
    }

    /// The device's open feed when it is for `session`, or nil.
    func openTranscriptFeed(for session: PhoneSessionRef, deviceID: UUID) -> TranscriptFeed? {
        guard let slot = devices[deviceID]?.transcript, slot.session == session else { return nil }
        return slot.feed
    }

    // MARK: - transcript.detail

    static let detailItemIDReason = "That item ID is not valid."
    static let detailChunkReason = "That part of the detail does not exist."
    static let detailNotFoundReason = "That detail is not in the transcript."

    /// One part of one item of the open transcript, in chunks that each fit
    /// one frame (spec section 7, "Large details"): a tool call's input or
    /// result, the whole of a message whose preview was cut, or a subagent's
    /// items.
    ///
    /// - **Inputs are bounded.** An item ID that is empty or over
    ///   `detailItemIDMaxBytes` is `bad_request`, since the reply echoes it,
    ///   and so is a `chunk` below 0 or at or past `chunkCount`. The session
    ///   must be the open feed's, or the reply is `not_open`.
    /// - **Text parts** come from `TranscriptDetailReader.text`, starting at
    ///   the item's line, and are split by `TranscriptDetailChunker.chunk`.
    ///   Over `detailLimitBytes`, only the first chunk is served and
    ///   `tooLarge` is set. The lookup reads a bounded part of the file
    ///   (see there).
    /// - **`subagent`** reads the transcript of the agent the feed recorded
    ///   for the row (`TranscriptDetailReader.subagent`) and serves its items
    ///   in runs of whole items.
    /// - **Both reads run off the cooperative pool** (`readOffThePool(_:)`).
    /// - **Later chunks come from the feed's cache** of the last few items and
    ///   parts read in the current generation, so they read no file.
    /// - A detail the transcript does not hold is `not_found`.
    ///
    /// A pure read: its replies are not remembered and it records nothing.
    nonisolated func transcriptDetail(
        _ params: TranscriptDetailParams, _ context: DeviceContext
    ) async throws -> TranscriptDetailResult {
        let itemID = params.itemID
        guard !itemID.isEmpty, itemID.utf8.count <= PhoneAppConstants.detailItemIDMaxBytes else {
            throw PhoneAppError(code: .badRequest, message: Self.detailItemIDReason)
        }
        guard params.chunk >= 0 else {
            throw PhoneAppError(code: .badRequest, message: Self.detailChunkReason)
        }
        guard let feed = await openTranscriptFeed(for: params.session, deviceID: context.peer.deviceID) else {
            throw PhoneAppError(code: .notOpen, message: Self.transcriptNotOpenReason)
        }
        switch params.part {
        case .subagent:
            let detail = try await subagentDetail(itemID: itemID, feed: feed)
            guard params.chunk < detail.chunks.count else {
                throw PhoneAppError(code: .badRequest, message: Self.detailChunkReason)
            }
            return TranscriptDetailResult(
                itemID: itemID, part: params.part, chunk: params.chunk, chunkCount: detail.chunks.count,
                totalBytes: detail.totalBytes, tooLarge: detail.tooLarge, text: nil, items: detail.chunks[params.chunk])
        case .input, .result, .text:
            let detail = try await textDetail(itemID: itemID, part: params.part, feed: feed)
            guard params.chunk < detail.ranges.count else {
                throw PhoneAppError(code: .badRequest, message: Self.detailChunkReason)
            }
            return TranscriptDetailResult(
                itemID: itemID, part: params.part, chunk: params.chunk, chunkCount: detail.ranges.count,
                totalBytes: detail.totalBytes, tooLarge: detail.tooLarge, text: detail.chunkText(params.chunk),
                items: nil)
        }
    }

    /// `itemID`'s text `part`, chunked, from the feed's cache or else read
    /// and cached.
    private nonisolated func textDetail(
        itemID: String, part: TranscriptDetailPart, feed: TranscriptFeed
    ) async throws -> DetailChunks {
        if let cached = await feed.cachedDetail(itemID: itemID, part: part, as: DetailChunks.self) {
            return cached
        }
        guard let place = await feed.detailContext(itemID: itemID) else {
            throw PhoneAppError(code: .notFound, message: Self.detailNotFoundReason)
        }
        let text = await Self.readOffThePool {
            TranscriptDetailReader.text(
                itemID: itemID, part: part, filePath: place.filePath, lineOffset: place.lineOffset)
        }
        guard let text else {
            throw PhoneAppError(code: .notFound, message: Self.detailNotFoundReason)
        }
        try Task.checkCancellation()
        let chunks = TranscriptDetailChunker.chunk(text)
        await feed.cacheDetail(chunks, itemID: itemID, part: part, generation: place.generation)
        return chunks
    }

    /// The items of the subagent behind `itemID`'s row, chunked, from the
    /// feed's cache or else read and cached. The agent ID is the one the
    /// transcript recorded with the call's result, as the feed kept it.
    private nonisolated func subagentDetail(itemID: String, feed: TranscriptFeed) async throws -> SubagentDetailChunks {
        if let cached = await feed.cachedDetail(itemID: itemID, part: .subagent, as: SubagentDetailChunks.self) {
            return cached
        }
        guard let place = await feed.detailContext(itemID: itemID), let agentID = place.agentID else {
            throw PhoneAppError(code: .notFound, message: Self.detailNotFoundReason)
        }
        let showDetails = feed.showDetails
        let worktreeRoot = feed.worktreeRoot
        let detail = await Self.readOffThePool {
            TranscriptDetailReader.subagent(
                agentID: agentID, transcriptPath: place.filePath, showDetails: showDetails, worktreeRoot: worktreeRoot)
        }
        guard let detail else {
            throw PhoneAppError(code: .notFound, message: Self.detailNotFoundReason)
        }
        try Task.checkCancellation()
        await feed.cacheDetail(detail, itemID: itemID, part: .subagent, generation: place.generation)
        return detail
    }

    /// Runs `read`, a blocking read of transcript files, on a GCD thread
    /// rather than on the cooperative pool, and suspends until it answers:
    /// the discipline `AppLivenessArbiter.verdictOffThePool(for:)` follows
    /// for its blocking `ps` spawns. A detail read can scan megabytes, and
    /// run inline it would hold one of the pool's few threads for all of it.
    /// `.userInitiated`, not `.utility`: utility work is throttled onto the
    /// efficiency cores under load, and a phone is waiting on this read.
    static func readOffThePool<T: Sendable>(_ read: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: read())
            }
        }
    }

    // MARK: - transcript.close

    nonisolated func transcriptClose(_ params: PhoneEmpty, _ context: DeviceContext) async throws -> PhoneEmpty {
        await closeTranscript(for: context.peer.deviceID, stamp: context.transcriptStamp)
        return PhoneEmpty()
    }

    /// Stops the device's open feed and its prompt feed, unless the feed was
    /// opened or resumed by a `transcript.open` the phone sent after the
    /// close stamped `stamp`. A nil stamp stops whatever is open.
    func closeTranscript(for deviceID: UUID, stamp: UInt64?) {
        if let stamp, let current = devices[deviceID]?.transcript, current.stamp > stamp {
            return
        }
        let slot = devices[deviceID]?.transcript
        devices[deviceID]?.transcript = nil
        closePrompts(for: deviceID)
        if let slot {
            Task {
                await slot.stop()
            }
        }
    }

    /// The device's open transcript's session, or nil with none. For tests.
    func transcriptSession(for deviceID: UUID) -> PhoneSessionRef? {
        devices[deviceID]?.transcript?.session
    }

    /// The device's open feed, or nil with none. For tests.
    func transcriptFeed(for deviceID: UUID) -> TranscriptFeed? {
        devices[deviceID]?.transcript?.feed
    }
}
