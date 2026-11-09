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
            snapshot = try await gatherSnapshot(forceProviderRefresh: true)
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
        // A `let`, as the task below captures it.
        let baseline: PhoneSnapshot
        if parts.rest.isEmpty {
            baseline = snapshot
        } else {
            let rest = SessionsChangedData(layout: nil, rows: parts.rest, removedRowIDs: [])
            let framed = PhoneSessionsPublisher.framed(rest, budget: PhoneFrameBudget.eventDataBytes)
            for frame in framed.frames {
                emit(.sessionsChanged, data: frame, to: deviceID)
            }
            // A row the frames left out is one the phone does not have, so
            // the publisher's first change sends it again.
            baseline = PhoneSessionsPublisher.sent(
                snapshot, since: PhoneSnapshot(layout: snapshot.layout, rows: [], omittedRows: snapshot.omittedRows),
                leaving: framed)
        }
        // A transcript opened before this reply starts now, after it, and a
        // resumed open that waited for it is answered, and refused, since
        // this reply did not replay.
        transcriptConnectionWentLive(for: deviceID)
        // The earlier publisher's subscriber goes before the new one's comes.
        // A stop that reaches the new publisher first leaves it stopped.
        Task {
            await earlier?.stop()
            await publisher.start(baseline: baseline)
        }
    }

    /// The snapshot reply with the layout and as many rows, in order, as fit
    /// `PhoneFrameBudget.eventDataBytes`, and the rows left for events.
    /// Fitting stops at the first row that does not fit (`PhoneFrameFit`), so
    /// the rows left follow on from the reply's. The reply is nil when it
    /// cannot fit a frame at all, which the snapshot builder's limits rule
    /// out.
    static func snapshotReply(_ snapshot: PhoneSnapshot, requestID: String, stream: String, seq: Int) -> (reply: Data?, rest: [PhoneRow]) {
        func encoded(_ rows: [PhoneRow], more: Bool) -> Data? {
            try? PhoneAppCoding.reply(requestID: requestID, result: SessionsSubscribeResult(
                stream: stream, seq: seq, replayed: false, layout: snapshot.layout, rows: rows,
                omittedRows: snapshot.omittedRows, more: more))
        }
        // `more: false` is the longer spelling, so this is an upper bound.
        guard let empty = encoded([], more: false) else { return (nil, snapshot.rows) }
        let kept = PhoneFrameFit.fitted(
            snapshot.rows, used: empty.count, budget: PhoneFrameBudget.eventDataBytes, onMisfit: .stop)
        let rest = Array(snapshot.rows.dropFirst(kept.count))
        guard let reply = encoded(kept, more: !rest.isEmpty),
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
    /// states every session reads `unknown`. A failed database read throws,
    /// except the setting's (below).
    /// The providers re-read the registry at most once per
    /// `PhoneAppConstants.providerRefreshInterval`, or always with
    /// `forceProviderRefresh`, as a `sessions.subscribe` asks
    /// (`gatheredRemoteProviders(forceRefresh:)`).
    ///
    /// The setting for answering prompts is read on every gather
    /// (`gatheredPromptAnswerSetting()`), never kept. Turning it on or off
    /// reaches a phone through the publisher like any other change: the
    /// setter, `config.setTranscriptPromptAnswerEnabled`, broadcasts a state
    /// delta once it has written the column, the delta opens the publisher's
    /// window, and the gather after it reads the new value.
    nonisolated func gatherSnapshot(forceProviderRefresh: Bool = false) async throws -> PhoneSnapshot {
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
        let promptAnswerEnabled = try await gatheredPromptAnswerSetting()
        let openPrompts = await pendingPrompts.oldestOpenPrompts()
        let states = await gatheredSessionStates()
        let remoteSessions = await gatheredRemoteSessions()
        let providers = await gatheredRemoteProviders(forceRefresh: forceProviderRefresh)
        return PhoneSnapshotBuilder.build(PhoneSnapshotInput(
            repos: repos, worktrees: worktrees, scratch: scratch, terminals: terminals,
            tabOrder: tabOrder, tabLabels: tabLabels, profiles: profiles, states: states,
            openPrompts: openPrompts, remoteSessions: remoteSessions, providers: providers,
            promptAnswerEnabled: promptAnswerEnabled))
    }

    /// The laptop's setting for answering prompts,
    /// `config.transcriptPromptAnswerEnabled`, read from the database on
    /// every call. The sessions list (`gatherSnapshot`) reads it here, and so
    /// does an action's capability check whenever the capability it needs
    /// follows the setting (`listedCapability`), so the list never offers an
    /// answer that `prompt.answer` refuses, nor refuses one it offers, but
    /// for a change between the two reads; the core of the answer reads it
    /// again. A failed read throws.
    nonisolated func promptAnswerSetting() async throws -> Bool {
        try await db.config.get().transcriptPromptAnswerEnabled
    }

    /// The capability `needed` picks from a session's capabilities as the
    /// sessions list shows them, given those capabilities with the setting
    /// for answering prompts on, `settingOn`, and off, `settingOff`.
    ///
    /// The setting is read (`promptAnswerSetting()`) only when the two picks
    /// differ, which is when the capability follows it: `answer`, on a
    /// session that could otherwise answer. Any other pick is the same
    /// either way, so an action that needs it never reads the config row,
    /// and a read that would fail cannot stop it. A failed read throws.
    nonisolated func listedCapability(
        _ needed: @Sendable (PhoneCapabilities) -> PhoneCapability,
        settingOn: PhoneCapabilities, settingOff: PhoneCapabilities
    ) async throws -> PhoneCapability {
        let on = needed(settingOn)
        let off = needed(settingOff)
        guard on != off else { return on }
        return try await promptAnswerSetting() ? on : off
    }

    /// The setting for answering prompts as a gather reads it, or nil when
    /// the read fails. Only `answer` depends on it, so a config row that
    /// cannot be read does not take the whole list down: the list is built
    /// with no session offering an answer
    /// (`PhoneSessionStatus.answerSettingUnreadReason`), which is what
    /// `prompt.answer` would do anyway, since it reads the setting again
    /// (`listedCapability`). A cancelled read throws.
    private nonisolated func gatheredPromptAnswerSetting() async throws -> Bool? {
        do {
            return try await promptAnswerSetting()
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            Self.logger.error(
                "Phone sessions: could not read the setting for answering prompts, so no session offers an answer: \(Self.errorType(error), privacy: .public): \(error.localizedDescription, privacy: .private)")
            return nil
        }
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

    /// The registered providers, read the way `remote.providers` reads them,
    /// re-reading the registry file first when this gather claims the
    /// refresh (`claimProviderRefresh(force:)`), and as last read otherwise
    /// (`phoneCachedRemoteProviders`). The gathers are the only phone path
    /// that re-reads the registry; every action reads the providers as last
    /// read (`providerStatuses()`). Nothing else keeps the registry fresh
    /// while the app is closed: the app re-reads it on its own
    /// `remote.providers` calls.
    ///
    /// Every phone's publisher gathers after every debounced change, and
    /// goes on for the grace after the phone leaves, so re-reading the file
    /// each time would read it many times a second on a busy laptop. So a
    /// gather re-reads it only once `PhoneAppConstants.providerRefreshInterval`
    /// has passed since the last re-read, and a registry edit reaches the
    /// phone at the first gather after that. Gathers run only when the
    /// sessions state changes, so on a quiet laptop an edit waits for the
    /// next change. A `sessions.subscribe` always re-reads it.
    private nonisolated func gatheredRemoteProviders(forceRefresh: Bool) async -> [RemoteProviderStatus] {
        let refresh = await claimProviderRefresh(force: forceRefresh)
        do {
            let response: RPCResponse
            if refresh {
                response = try await actions.phoneRemoteProviders()
            } else {
                response = try await actions.phoneCachedRemoteProviders()
            }
            guard response.success else { return [] }
            return try response.decodeResult(RemoteProvidersResult.self).providers
        } catch {
            Self.logger.debug(
                "Phone sessions: no remote providers: \(Self.errorType(error), privacy: .public): \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    /// Whether a gather re-reads the provider registry now: always with
    /// `force`, and otherwise when no gather has re-read it within
    /// `PhoneAppConstants.providerRefreshInterval` on the date seam, or the
    /// date went back past the last one. A claim stamps the moment in the
    /// same turn, so gathers that start together re-read it once.
    func claimProviderRefresh(force: Bool) -> Bool {
        let date = self.now()
        if !force, let last = providersRefreshedAt {
            let elapsed = date.timeIntervalSince(last)
            if elapsed >= 0, elapsed < PhoneAppConstants.providerRefreshInterval {
                return false
            }
        }
        providersRefreshedAt = date
        return true
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

    /// Checks that the phone may act on the remote session
    /// `provider`/`sessionID`, needing the capability `needed` picks from its
    /// capabilities as the sessions list shows them
    /// (`PhoneSessionStatus.remoteCapabilities`, through `listedCapability`,
    /// which reads the setting for answering prompts only when that
    /// capability follows it):
    /// - a provider that is not registered is `not_found` with
    ///   `noSuchProviderReason`;
    /// - an unavailable capability is `unsupported` with its reason, as the
    ///   list shows it, or `fallback` when it gives none: an `answer` while
    ///   the setting is off is `PhoneSessionStatus.answerTurnedOffReason`;
    /// - a session the list places in no row is `not_found` with
    ///   `noSuchSessionReason`: one missing from the laptop's remote session
    ///   list, dismissed, or matched to a hidden repo. The rule is the list's
    ///   own (`PhoneSnapshotBuilder.listsRemoteSession`), over the rows
    ///   `gatherSnapshot` reads, so the two cannot drift. A session list the
    ///   daemon refuses to give is `refused` with its reason.
    ///
    /// A phone can keep a session reference from a list it was sent before
    /// the repo was hidden or the session dismissed, and it acts on nothing
    /// the laptop no longer shows it, as `phoneVisibleTerminal` holds a local
    /// session. So every action on a remote session checks it here, and
    /// nowhere else: `message.send` and `session.setModel` (`sendText`),
    /// `prompt.answer` and `transcript.open`. Only `answer` follows the
    /// setting, so only `prompt.answer` reads it; the others never read the
    /// config row.
    nonisolated func checkPhoneCapableRemoteSession(
        provider: String, sessionID: String,
        needing needed: @Sendable (PhoneCapabilities) -> PhoneCapability, orElse fallback: String
    ) async throws {
        let providers = try await providerStatuses()
        let settingOn = try Self.remoteCapabilities(ofProvider: provider, in: providers, promptAnswerEnabled: true)
        let settingOff = try Self.remoteCapabilities(ofProvider: provider, in: providers, promptAnswerEnabled: false)
        let capability = try await listedCapability(needed, settingOn: settingOn, settingOff: settingOff)
        try Self.requireCapability(capability, orElse: fallback)
        let response = try await actions.phoneRemoteSessions()
        let sessions = try Self.succeeded(RemoteSessionsResult.self, from: response, method: "remote.sessions").sessions
        let repos = try await db.repos.list()
        let worktrees = try await db.worktrees.list(excludeArchived: true)
        let scratch = try await db.worktrees.listScratch().filter { $0.status != .archived }
        // Placing a remote session reads none of the fields left empty here,
        // nor `promptAnswerEnabled` (`listsRemoteSession`).
        let input = PhoneSnapshotInput(
            repos: repos, worktrees: worktrees, scratch: scratch, terminals: [:],
            tabOrder: [:], tabLabels: [:], profiles: [], states: [:],
            openPrompts: [:], remoteSessions: sessions, providers: providers,
            promptAnswerEnabled: true)
        guard PhoneSnapshotBuilder.listsRemoteSession(provider: provider, sessionID: sessionID, in: input) else {
            throw PhoneAppError(code: .notFound, message: Self.noSuchSessionReason)
        }
    }

    /// The terminal row behind a local session, with its own capabilities
    /// (`PhoneSessionStatus.localCapabilities` with the setting for
    /// answering prompts left out), when the phone can see it
    /// (`phoneVisibleTerminal`, else `not_found`), it is a Claude session by
    /// the list's reading (`PhoneSnapshotBuilder.agent(of:)`), and the
    /// capability `needed` picks is available as the sessions list shows it.
    ///
    /// The refusals come in this order, each `unsupported`:
    /// 1. **What the session itself cannot do**, with the reason the list
    ///    shows: a Codex session, a tab in a remote lane. This check leaves
    ///    the setting out, so a session that could never answer says why,
    ///    whatever the setting.
    /// 2. **Not Claude**, with `notClaude`: any other session the list does
    ///    not show as Claude, a shell or a row with no kind and no Claude
    ///    session. The list never shows such a row, so it gives no reason of
    ///    its own; `localCapabilities` reads any terminal that is neither
    ///    Codex nor in a remote lane as Claude, which is why this guard
    ///    comes before the setting's.
    /// 3. **The setting**, read as the list reads it, and only when the
    ///    capability `needed` picks follows it (`listedCapability`): an
    ///    `answer` while it is off, with
    ///    `PhoneSessionStatus.answerTurnedOffReason`.
    ///
    /// `prompt.answer`, `session.switchProfile` and `session.fork` read a
    /// local session through this, so each refuses what the list marks
    /// unavailable, in the list's words. Only `answer` follows the setting,
    /// so switch and fork never read the config row. The capabilities
    /// returned are the session's own, so every one but `answer` is the
    /// list's; `answer` is what the session allows with the setting on.
    nonisolated func phoneCapableClaudeTerminal(
        _ terminalID: UUID, needing needed: @Sendable (PhoneCapabilities) -> PhoneCapability, notClaude: String
    ) async throws -> (terminal: TBDShared.Terminal, ownCapabilities: PhoneCapabilities) {
        let (terminal, worktree) = try await phoneVisibleTerminal(terminalID)
        let isRemoteWorktree = !worktree.location.isLocal
        // With the setting on, every capability is what the session allows.
        let ownCapabilities = PhoneSessionStatus.localCapabilities(
            terminal: terminal, isRemoteWorktree: isRemoteWorktree, promptAnswerEnabled: true)
        try Self.requireCapability(needed(ownCapabilities), orElse: notClaude)
        guard PhoneSnapshotBuilder.agent(of: terminal) == .claude else {
            throw PhoneAppError(code: .unsupported, message: notClaude)
        }
        let settingOff = PhoneSessionStatus.localCapabilities(
            terminal: terminal, isRemoteWorktree: isRemoteWorktree, promptAnswerEnabled: false)
        let capability = try await listedCapability(needed, settingOn: ownCapabilities, settingOff: settingOff)
        try Self.requireCapability(capability, orElse: notClaude)
        return (terminal, ownCapabilities)
    }
}
