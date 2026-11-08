import Foundation
import os
import TBDShared

// `transcript.open`, `transcript.page` and `transcript.close` (spec section 7):
// one open transcript per phone, held in `PhoneDeviceState.transcript`, with
// the session's `prompt.changed` feed beside it.

/// A device's open transcript: its feed, the relay that hands the feed its
/// terminal's state deltas, and whether the live part has started.
struct PhoneTranscriptSlot: Sendable {
    /// Tells this slot's events from those of a slot it replaced.
    let token: UInt64
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
/// from the phone. The reply goes out through `.onQueue`, so the stream's
/// `seq` it names is where the session's events start, and the feed and the
/// prompt feed start only once the connection is live
/// (`startTranscript(for:)`): at once when the phone's `sessions.subscribe`
/// reply is already queued, and otherwise right after that reply. Events the
/// feed would have sent in between are read by its first step, so none is
/// lost. Opening replaces any transcript the device had open, and stops its
/// feed.
///
/// **Resume.** A `transcript.open` with `resume`, on a connection whose
/// `sessions.subscribe` replayed the stream (`PhoneResumeDecision.replay`),
/// for the session and `showDetails` of the open feed, keeps that feed: the
/// reply is `{resumed: true, seq}` with no page. The feed and the prompt feed
/// ran on while the phone was away, so the replay carries what the phone
/// missed, the current prompt set included. Any other open starts over from
/// the tail.
///
/// **`transcript.page`** needs an open feed for the same session, or it is
/// `not_open`. **`transcript.close`** stops the feed and the prompt feed.
/// The grace after a disconnect, and a revoke, stop them too
/// (`PhoneDeviceState.shutDown()`).
extension PhoneAppService {
    private static let transcriptLogger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    static let notAClaudeTranscriptReason = "Only a Claude session has a transcript."
    static let remoteTranscriptReason = "This TBD build cannot open a remote transcript from a phone yet."
    static let transcriptNotOpenReason = "That transcript is not open. Open it again."
    static let transcriptChangedReason = "The transcript changed while it was opened. Try again."

    // MARK: - transcript.open

    nonisolated func transcriptOpen(_ params: TranscriptOpenParams, _ context: DeviceContext) async throws -> PhoneHandlerReply {
        let deviceID = context.peer.deviceID
        let requestID = context.requestID
        let terminalID: UUID
        switch params.session {
        case .remote:
            throw PhoneAppError(code: .unavailable, message: Self.remoteTranscriptReason)
        case .local(let id):
            terminalID = id
        }
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

        if params.resume, await canResumeTranscript(params, deviceID: deviceID) {
            return .onQueue { service in
                service.queueResumedTranscript(params, requestID: requestID, deviceID: deviceID)
            }
        }
        let token = await mintToken()
        let feed = TranscriptFeed(
            session: params.session, showDetails: params.showDetails,
            source: .local(terminalID: terminalID, resolvePath: { [weak self] in
                await self?.transcriptPath(of: terminalID)
            }),
            emit: { [weak self] event in
                await self?.emitTranscript(event, to: deviceID, token: token)
            },
            clock: clock)
        let page = try await feed.open()
        try Task.checkCancellation()
        return .onQueue { service in
            service.queueOpenedTranscript(
                params, feed: feed, token: token, page: page, requestID: requestID, deviceID: deviceID)
        }
    }

    /// Whether `params` may keep the device's open feed: the connection's
    /// `sessions.subscribe` replayed the stream, and the feed is for the same
    /// session and `showDetails`.
    func canResumeTranscript(_ params: TranscriptOpenParams, deviceID: UUID) -> Bool {
        guard let state = devices[deviceID], case .replay = state.resume,
              let slot = state.transcript else { return false }
        return slot.session == params.session && slot.showDetails == params.showDetails
    }

    /// Replies `{resumed: true, seq}` and keeps the feed, starting its live
    /// part if it never started. When the feed changed since the handler
    /// looked, the reply is an error and the phone opens again.
    func queueResumedTranscript(_ params: TranscriptOpenParams, requestID: String, deviceID: UUID) {
        guard canResumeTranscript(params, deviceID: deviceID), let state = devices[deviceID] else {
            send(Self.failure(requestID, .internalError, Self.transcriptChangedReason), to: deviceID)
            return
        }
        let result = TranscriptOpenResult(resumed: true, seq: state.stream.lastSeq, page: nil)
        guard let reply = try? PhoneAppCoding.reply(requestID: requestID, result: result) else {
            send(Self.failure(requestID, .internalError, "Something went wrong on the laptop."), to: deviceID)
            return
        }
        send(reply, to: deviceID)
        startTranscript(for: deviceID)
    }

    /// Installs a freshly opened feed in place of the device's earlier one,
    /// replies with its first page, and starts its live part when the
    /// connection is live. Until then the earlier session's prompt feed is
    /// stopped, and this session's starts with the live part.
    func queueOpenedTranscript(
        _ params: TranscriptOpenParams, feed: TranscriptFeed, token: UInt64, page: TranscriptPage,
        requestID: String, deviceID: UUID
    ) {
        guard let state = devices[deviceID] else { return }
        let result = TranscriptOpenResult(resumed: false, seq: state.stream.lastSeq, page: page)
        guard let reply = try? PhoneAppCoding.reply(requestID: requestID, result: result) else {
            Self.transcriptLogger.error("Phone transcript: the open reply does not encode")
            send(Self.failure(requestID, .internalError, "Something went wrong on the laptop."), to: deviceID)
            return
        }
        let earlier = state.transcript
        devices[deviceID]?.transcript = PhoneTranscriptSlot(
            token: token, session: params.session, showDetails: params.showDetails,
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

    /// Starts the device's open feed's live part, with its relay and the
    /// session's prompt feed, once the connection is live. Does nothing with
    /// no feed, a feed already started, or a connection that is not live yet:
    /// `queueSubscribeReply` calls this again when the connection goes live.
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
            Self.transcriptLogger.error(
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
    ///   `tooLarge` is set.
    /// - **`subagent`** reads the transcript of the agent the feed recorded
    ///   for the row (`TranscriptDetailReader.subagent`) and serves its items
    ///   in runs of whole items.
    /// - **Later chunks come from the feed's cache** of the last item and part
    ///   read in the current generation, so they read no file.
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
        guard let place = await feed.detailContext(itemID: itemID),
              let text = TranscriptDetailReader.text(
                itemID: itemID, part: part, filePath: place.filePath, lineOffset: place.lineOffset) else {
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
        guard let place = await feed.detailContext(itemID: itemID), let agentID = place.agentID,
              let detail = TranscriptDetailReader.subagent(
                agentID: agentID, transcriptPath: place.filePath, showDetails: feed.showDetails) else {
            throw PhoneAppError(code: .notFound, message: Self.detailNotFoundReason)
        }
        try Task.checkCancellation()
        await feed.cacheDetail(detail, itemID: itemID, part: .subagent, generation: place.generation)
        return detail
    }

    // MARK: - transcript.close

    nonisolated func transcriptClose(_ params: PhoneEmpty, _ context: DeviceContext) async throws -> PhoneEmpty {
        await closeTranscript(for: context.peer.deviceID)
        return PhoneEmpty()
    }

    /// Stops the device's open feed and its prompt feed.
    func closeTranscript(for deviceID: UUID) {
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
