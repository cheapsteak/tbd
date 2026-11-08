import Foundation
import os
import TBDShared

/// A device's sessions publisher, with the token that tells its emits from
/// those of a publisher it replaced.
struct PhoneSessionsFeed: Sendable {
    let publisher: PhoneSessionsPublisher
    let token: UInt64
}

/// `sessions.subscribe` and `sessions.changed` (spec section 4.4, "Sessions
/// list").
///
/// **The reply.** A connection whose resume decision is a replay, on a state
/// whose publisher is running, gets `replayed: true` with the stream's
/// current `seq`, then every event it missed, in order. Any other connection
/// gets a fresh snapshot: the layout and as many rows as fit one frame, with
/// `more` set when rows remain, then the remaining rows as `sessions.changed`
/// events with no layout. That covers a decision of `snapshot`, a replay with
/// no publisher to carry the stream on, and a decision still `undecided`
/// because phone control was off when the request arrived. A resent
/// `sessions.subscribe` runs again, as it is not in the request memory.
///
/// Both replies are queued through `PhoneHandlerReply.onQueue`, so the reply
/// names the stream's `seq` at the moment it leaves and the events after it
/// start there; the connection goes live with it. A transcript opened before
/// the connection went live starts then, and a resumed open that waited for
/// it is answered (`transcriptConnectionWentLive(for:)`).
///
/// **The publisher.** A snapshot reply starts a new publisher with that
/// snapshot as its baseline and stops any earlier one. A token tells the new
/// publisher's emits from the old one's, which are dropped, so a publisher
/// still finishing a gather cannot send a change against the wrong
/// baseline. The publisher lives in `PhoneDeviceState`, so dropping the
/// state stops it, and it keeps emitting while the phone is away: its events
/// are numbered and kept for the resume.
extension PhoneAppService {
    // MARK: - sessions.subscribe

    /// Gathers the sessions list unless the reply will replay, and hands back
    /// the work that queues the reply.
    nonisolated func sessionsSubscribe(_ params: SessionsSubscribeParams, _ context: DeviceContext) async throws -> PhoneHandlerReply {
        let snapshot: PhoneSnapshot?
        if await canReplaySessions(for: context.peer.deviceID) {
            snapshot = nil
        } else {
            snapshot = try await gatherSnapshot()
        }
        return .onQueue { (service: isolated PhoneAppService) in
            service.queueSubscribeReply(params, snapshot: snapshot, context: context)
        }
    }

    /// Whether this connection decided to replay and a publisher is running
    /// to carry the stream on.
    private func canReplaySessions(for deviceID: UUID) -> Bool {
        guard let state = devices[deviceID], state.sessions != nil, case .replay = state.resume else {
            return false
        }
        return true
    }

    /// Queues the `sessions.subscribe` reply and the events that follow it,
    /// and makes the connection live.
    private func queueSubscribeReply(_ params: SessionsSubscribeParams, snapshot: PhoneSnapshot?, context: DeviceContext) {
        let deviceID = context.peer.deviceID
        let requestID = context.requestID
        guard let state = devices[deviceID] else { return }
        // Every event after the phone's `seq`, as the stream holds them now,
        // so the reply's `seq` and the events agree. The decision only says
        // the stream carries on.
        if snapshot == nil, case .replay = state.resume, state.sessions != nil,
           let missed = state.stream.replay(stream: params.stream, sinceSeq: params.sinceSeq) {
            let result = SessionsSubscribeResult(
                stream: state.stream.streamID, seq: state.stream.lastSeq, replayed: true,
                layout: nil, rows: nil, omittedRows: 0, more: false)
            guard let reply = try? PhoneAppCoding.reply(requestID: requestID, result: result) else {
                send(Self.failure(requestID, .internalError, Self.internalErrorReason), to: deviceID)
                refusePendingTranscriptResume(for: deviceID)
                return
            }
            send(reply, to: deviceID)
            for event in missed {
                send(event, to: deviceID)
            }
            devices[deviceID]?.live = true
            transcriptConnectionWentLive(for: deviceID)
            return
        }
        guard let snapshot else {
            // Between the handler's check and now, the state lost its
            // publisher or the stream dropped events the phone has not seen.
            // A resend decides again and gets a snapshot.
            send(Self.failure(requestID, .internalError, "The sessions list changed while it was read. Try again."), to: deviceID)
            refusePendingTranscriptResume(for: deviceID)
            return
        }
        let parts = Self.snapshotReply(
            snapshot, requestID: requestID, stream: state.stream.streamID, seq: state.stream.lastSeq)
        guard let reply = parts.reply else {
            Self.logger.error("Phone sessions: the snapshot reply does not fit a frame")
            send(Self.failure(requestID, .internalError, Self.internalErrorReason), to: deviceID)
            refusePendingTranscriptResume(for: deviceID)
            return
        }

        let earlier = state.sessions?.publisher
        let token = mintToken()
        let publisher = makeSessionsPublisher(deviceID: deviceID, token: token)
        devices[deviceID]?.sessions = PhoneSessionsFeed(publisher: publisher, token: token)
        devices[deviceID]?.resume = .snapshot
        send(reply, to: deviceID)
        devices[deviceID]?.live = true
        if !parts.rest.isEmpty {
            let rest = SessionsChangedData(layout: nil, rows: parts.rest, removedRowIDs: [])
            for frame in PhoneSessionsPublisher.frames(rest, budget: PhoneFrameBudget.eventDataBytes) {
                emit(.sessionsChanged, data: frame, to: deviceID)
            }
        }
        // A transcript opened before this reply starts now, after it, and a
        // resumed open that waited for it is answered, and refused, since
        // this reply did not replay.
        transcriptConnectionWentLive(for: deviceID)
        // The earlier publisher's subscriber goes before the new one's comes.
        // A stop that reaches the new publisher first leaves it stopped.
        Task {
            await earlier?.stop()
            await publisher.start(baseline: snapshot)
        }
    }

    /// The snapshot reply with the layout and as many rows, in order, as fit
    /// `PhoneFrameBudget.eventDataBytes`, and the rows left for events. The
    /// reply is nil when it cannot fit a frame at all, which the snapshot
    /// builder's limits rule out.
    static func snapshotReply(_ snapshot: PhoneSnapshot, requestID: String, stream: String, seq: Int) -> (reply: Data?, rest: [PhoneRow]) {
        func encoded(_ rows: [PhoneRow], more: Bool) -> Data? {
            try? PhoneAppCoding.reply(requestID: requestID, result: SessionsSubscribeResult(
                stream: stream, seq: seq, replayed: false, layout: snapshot.layout, rows: rows,
                omittedRows: snapshot.omittedRows, more: more))
        }
        // `more: false` is the longer spelling, so this is an upper bound.
        guard let empty = encoded([], more: false) else { return (nil, snapshot.rows) }
        let encoder = PhoneAppCoding.makeEncoder()
        var used = empty.count
        var count = 0
        for row in snapshot.rows {
            // A row's bytes, and a comma unless it is the first.
            let cost = ((try? encoder.encode(row).count) ?? Int.max / 2) + (count == 0 ? 0 : 1)
            guard used + cost <= PhoneFrameBudget.eventDataBytes else { break }
            used += cost
            count += 1
        }
        let rest = Array(snapshot.rows.dropFirst(count))
        guard let reply = encoded(Array(snapshot.rows.prefix(count)), more: !rest.isEmpty),
              PhoneAppCoding.framedSize(reply) <= PhoneFrameBudget.maxPlaintext else {
            return (nil, snapshot.rows)
        }
        return (reply, rest)
    }

    private func makeSessionsPublisher(deviceID: UUID, token: UInt64) -> PhoneSessionsPublisher {
        PhoneSessionsPublisher(
            gather: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.gatherSnapshot()
            },
            emit: { [weak self] data in
                await self?.emitSessionsChanged(data, to: deviceID, token: token)
            },
            subscriptions: subscriptions,
            clock: clock)
    }

    /// Emits a publisher's change, unless a later publisher replaced it.
    func emitSessionsChanged(_ data: SessionsChangedData, to deviceID: UUID, token: UInt64) {
        guard devices[deviceID]?.sessions?.token == token else { return }
        emit(.sessionsChanged, data: data, to: deviceID)
    }

    /// The device's sessions publisher, or nil before its first snapshot
    /// reply. For tests.
    func sessionsPublisher(for deviceID: UUID) -> PhoneSessionsPublisher? {
        devices[deviceID]?.sessions?.publisher
    }

    /// The `seq` of the device's newest event, or nil when the service keeps
    /// no state for it. For tests.
    func lastSeq(for deviceID: UUID) -> Int? {
        devices[deviceID]?.stream.lastSeq
    }

    // MARK: - Gathering

    /// Reads everything the sessions list is built from, and builds it.
    ///
    /// The database and the pending prompt store are read directly. Session
    /// states, remote sessions and remote providers come through
    /// `PhoneSessionActions`; a call that fails, as the remote ones do while
    /// remote backends are off, counts as an empty list, and with no session
    /// states every session reads `unknown`. A failed database read throws.
    nonisolated func gatherSnapshot() async throws -> PhoneSnapshot {
        let repos = try await db.repos.list()
        let worktrees = try await db.worktrees.list(excludeArchived: true)
        let scratch = try await db.worktrees.listScratch().filter { $0.status != .archived }
        var terminals: [UUID: [TBDShared.Terminal]] = [:]
        for terminal in try await db.terminals.list() {
            terminals[terminal.worktreeID, default: []].append(terminal)
        }
        // Tab order and labels only matter where an agent tab shows. Each is
        // one read across those worktrees, since every phone's publisher
        // gathers again after every change.
        var agentWorktreeIDs: Set<UUID> = []
        for (worktreeID, list) in terminals where list.contains(where: { PhoneSnapshotBuilder.agent(of: $0) != nil }) {
            agentWorktreeIDs.insert(worktreeID)
        }
        let tabOrder = try await db.worktrees.getTabOrders(worktreeIDs: agentWorktreeIDs)
        var tabLabels: [UUID: String] = [:]
        for tab in try await db.tabs.listForWorktrees(worktreeIDs: agentWorktreeIDs) {
            if let label = tab.label {
                tabLabels[tab.id] = label
            }
        }
        let profiles = try await db.modelProfiles.list()
        var openPrompts: [UUID: PendingPromptPayload] = [:]
        for terminalID in await pendingPrompts.terminalsWithOpenPrompts() {
            if let oldest = await pendingPrompts.prompts(forTerminal: terminalID).first {
                openPrompts[terminalID] = oldest
            }
        }
        let states = await gatheredSessionStates()
        let remoteSessions = await gatheredRemoteSessions()
        let providers = await gatheredRemoteProviders()
        return PhoneSnapshotBuilder.build(PhoneSnapshotInput(
            repos: repos, worktrees: worktrees, scratch: scratch, terminals: terminals,
            tabOrder: tabOrder, tabLabels: tabLabels, profiles: profiles, states: states,
            openPrompts: openPrompts, remoteSessions: remoteSessions, providers: providers))
    }

    private nonisolated func gatheredSessionStates() async -> [UUID: SessionState] {
        do {
            let response = try await actions.phoneSessionStates()
            guard response.success else {
                Self.logger.debug("Phone sessions: no session states: \(response.error ?? "", privacy: .private)")
                return [:]
            }
            var states: [UUID: SessionState] = [:]
            for report in try response.decodeResult(SessionStatesResult.self).reports {
                states[report.terminalID] = report.state
            }
            return states
        } catch {
            Self.logger.debug(
                "Phone sessions: no session states: \(Self.errorType(error), privacy: .public): \(error.localizedDescription, privacy: .private)")
            return [:]
        }
    }

    private nonisolated func gatheredRemoteSessions() async -> [RemoteSessionInfo] {
        do {
            let response = try await actions.phoneRemoteSessions()
            guard response.success else { return [] }
            return try response.decodeResult(RemoteSessionsResult.self).sessions
        } catch {
            Self.logger.debug(
                "Phone sessions: no remote sessions: \(Self.errorType(error), privacy: .public): \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    private nonisolated func gatheredRemoteProviders() async -> [RemoteProviderStatus] {
        do {
            let response = try await actions.phoneRemoteProviders()
            guard response.success else { return [] }
            return try response.decodeResult(RemoteProvidersResult.self).providers
        } catch {
            Self.logger.debug(
                "Phone sessions: no remote providers: \(Self.errorType(error), privacy: .public): \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    // MARK: - The sessions the phone can see

    /// The terminal row behind a local session, and its worktree, when the
    /// phone can see them: the terminal row exists, its worktree exists and
    /// is not archived, and the worktree's repo, when it has one, exists and
    /// is not hidden. A scratch worktree has no repo. These are the rows
    /// `gatherSnapshot` reads and `PhoneSnapshotBuilder` lists; a shell tab
    /// and a tab in a remote lane pass here, and each action refuses them
    /// with its own reason.
    ///
    /// Anything else is `not_found`, with `noSuchSessionReason`. A phone can
    /// keep a terminal ID from a list it was sent before the repo was hidden
    /// or the worktree archived, and it acts on nothing the laptop no longer
    /// shows it. So every action on a local session resolves its terminal
    /// here, and nowhere else: `message.send` and `session.setModel`
    /// (`sendText`), `prompt.answer`, `session.switchProfile`,
    /// `session.fork` and `transcript.open`.
    nonisolated func phoneVisibleTerminal(
        _ terminalID: UUID
    ) async throws -> (terminal: TBDShared.Terminal, worktree: Worktree) {
        let notFound = PhoneAppError(code: .notFound, message: Self.noSuchSessionReason)
        guard let terminal = try await db.terminals.get(id: terminalID),
              let worktree = try await db.worktrees.get(id: terminal.worktreeID),
              worktree.status != .archived else {
            throw notFound
        }
        if let repoID = worktree.repoID {
            guard let repo = try await db.repos.get(id: repoID), !repo.hidden else { throw notFound }
        }
        return (terminal, worktree)
    }

    /// The terminal row behind a local session, with its capabilities as the
    /// sessions list shows them (`PhoneSessionStatus.localCapabilities`),
    /// when the phone can see it (`phoneVisibleTerminal`, else `not_found`),
    /// the capability `needed` picks is available, and it is a Claude
    /// session by the list's reading (`PhoneSnapshotBuilder.agent(of:)`).
    ///
    /// An unavailable capability is `unsupported` with its reason, as the
    /// list shows it: a Codex session, a tab in a remote lane. Any other
    /// session the list does not show as Claude (a shell, or a row with no
    /// kind and no Claude session) is `unsupported` with `notClaude`.
    /// `prompt.answer`, `session.switchProfile` and `session.fork` read a
    /// local session through this, so each refuses what the list marks
    /// unavailable, in the list's words.
    nonisolated func phoneCapableClaudeTerminal(
        _ terminalID: UUID, needing needed: @Sendable (PhoneCapabilities) -> PhoneCapability, notClaude: String
    ) async throws -> (terminal: TBDShared.Terminal, capabilities: PhoneCapabilities) {
        let (terminal, worktree) = try await phoneVisibleTerminal(terminalID)
        let capabilities = PhoneSessionStatus.localCapabilities(
            terminal: terminal, isRemoteWorktree: !worktree.location.isLocal)
        try Self.requireCapability(needed(capabilities), orElse: notClaude)
        guard PhoneSnapshotBuilder.agent(of: terminal) == .claude else {
            throw PhoneAppError(code: .unsupported, message: notClaude)
        }
        return (terminal, capabilities)
    }
}
