import Foundation
import os
import TBDShared

private let remoteHandlerLogger = Logger(subsystem: "com.tbd.daemon", category: "remote")

/// A filing decision recorded in anticipation of a retirement verb, held across
/// the call so it can be re-stamped when the verb returns or taken back when it
/// fails.
///
/// It carries `prior` and `decidedAt` because withdrawal is conditional on
/// both: the map may hold an earlier decision that did happen and must survive,
/// and a decision recorded by some other path after this one was written is
/// newer than both and must not be clobbered by a late withdrawal. Deciding
/// that at the withdrawal site would mean re-deriving what
/// `noteFilingDecision` already told us.
struct RemoteFilingWatermark {
    let manager: RemoteProviderManager
    let worktreeID: UUID
    /// The instant written before the verb was invoked.
    let decidedAt: Date
    /// Whatever the map held before `decidedAt` was written, if anything.
    let prior: Date?

    /// The verb did not happen: put back what was there before.
    func withdraw() async {
        await manager.withdrawFilingDecision(
            worktreeID: worktreeID, restoring: prior, ifStillAt: decidedAt)
    }

    /// The verb returned: move the watermark forward past every poll that could
    /// have been launched while it ran.
    func restamp(at date: Date) async {
        await manager.noteFilingDecision(worktreeID: worktreeID, at: date)
    }
}

/// A deletion recorded in anticipation of `delete`, held across the call so it
/// can be re-stamped when the verb returns or taken back when it fails.
///
/// The session-shaped twin of `RemoteFilingWatermark`, and it is keyed by
/// `(provider, sessionID)` rather than by a worktree for the reason
/// `RemoteProviderManager.deletions` gives: most deletable sessions were never
/// adopted, so a worktree-keyed watermark would protect only the rare case.
/// It carries `prior` and `decidedAt` for exactly the reasons the filing twin
/// documents above.
struct RemoteDeletionWatermark {
    let manager: RemoteProviderManager
    let provider: String
    let sessionID: String
    /// The instant written before the verb was invoked.
    let decidedAt: Date
    /// Whatever the map held before `decidedAt` was written, if anything.
    let prior: Date?

    /// The delete did not happen: put back what was there before, so a session
    /// that is still alive is not hidden from the mirror over a destruction
    /// that never occurred.
    func withdraw() async {
        await manager.withdrawDeletion(
            provider: provider, sessionID: sessionID, restoring: prior, ifStillAt: decidedAt)
    }

    /// The verb returned: move the watermark forward past every poll that could
    /// have been launched while it ran.
    func restamp(at date: Date) async {
        await manager.noteDeletion(provider: provider, sessionID: sessionID, at: date)
    }
}

/// RPC handlers for remote agent backends (`docs/remote-provider-contract.md`).
/// Every `remote.*` verb gates on `config.remoteBackendsEnabled` AND on the
/// `remoteManager` actor existing — the daemon only constructs it at boot
/// when the flag was on then (`Daemon.swift`), so a user flipping the flag
/// on without restarting still has a `nil` manager. Both causes collapse to
/// the same "remote backends disabled" error rather than crashing or
/// silently no-oping.
extension RPCRouter {
    /// The refusal response every gated `remote.*` handler returns. Kept as
    /// a single shared value (rather than re-typed at each call site) so the
    /// exact string — which tests assert equality against — can't drift if
    /// one call site is edited and the others aren't.
    /// Internal rather than private because `worktree.archive` /
    /// `worktree.revive` branch into the remote path too and must refuse with
    /// the same words when the subsystem is off.
    static let remoteBackendsDisabledResponse = RPCResponse(error: "remote backends disabled")

    /// The inner gate's refusal. A separate string from the outer one because
    /// they are separate conditions: the outer flag says remote backends are
    /// off entirely, this says the compiled cloud provider is.
    private static let claudeCloudDisabledResponse = RPCResponse(error: "claude cloud sessions disabled")

    /// `remote.delete`'s own refusal, and the only feature-flag refusal in this
    /// file. It names the flag and how to lift it, because a refusal that only
    /// says "disabled" leaves a soak participant guessing which of three gates
    /// stopped them — the subsystem, the cloud gate, or this one.
    ///
    /// Kept as a shared value for the same reason
    /// `remoteBackendsDisabledResponse` is: tests assert equality against the
    /// exact string.
    static let remoteDeleteDisabledResponse = RPCResponse(error:
        "remote delete is disabled (config remote_delete_enabled); " +
        "turn it on with `tbd remote allow-delete on`")

    /// The per-invocation timeout for the `create` verb, applied to both the
    /// initial call and its one same-key retry below. Provider-agnostic at
    /// this layer — every `remote.*` backend's `create` gets this budget —
    /// but for the compiled `claude-cloud` provider it is in a load-bearing
    /// numeric relationship with `ClaudeCloudInvoker.pendingFailureWindow`
    /// (`ClaudeCloudList.swift`): that window must stay strictly greater than
    /// this timeout, or a `create` still running past its own timeout budget
    /// could have its ledger row reclaimed and re-spawned out from under it.
    /// Pinned by `ClaudeCloudTimeoutRelationshipTests`.
    static let remoteCreateTimeout: TimeInterval = 60

    /// The second, inner gate. `claude_cloud_enabled` is checked INSIDE
    /// `remoteGate()` — cloud is reached through the same `remote.*` verbs, so
    /// it requires BOTH flags and the inner one is never a bypass.
    ///
    /// The two stay separate rather than merging because
    /// `remote_backends_enabled` was written to be DELETABLE after soak, on
    /// the reasoning that the feature is inert without a registered provider
    /// file. A provider compiled into the daemon is never inert, so folding
    /// this into it would silently convert a disposable flag into a permanent
    /// one. When the outer flag is eventually deleted, its gate goes and this
    /// becomes the sole gate for cloud.
    ///
    /// Returns the refusal to send, or nil when the invocation is permitted.
    ///
    /// Internal rather than private for the same reason as `remoteGate()`
    /// above: `worktree.archive` / `worktree.revive`'s remote branches
    /// (`RPCRouter+WorktreeHandlers.swift`) reach a provider verb too — via
    /// `RemoteLaneLifecycle+Actuate`'s `archiveDecision`/`reviveDecision` —
    /// and must refuse with the same inner-gate message when cloud is off,
    /// not just when the outer flag is.
    func cloudGate(provider: String) async throws -> RPCResponse? {
        guard provider == ClaudeCloudProvider.name else { return nil }
        guard try await db.config.get().claudeCloudEnabled else {
            return Self.claudeCloudDisabledResponse
        }
        return nil
    }

    private static func staleSnapshotMutationResponse(provider: String) -> RPCResponse {
        RPCResponse(error: "provider '\(provider)' inventory is stale; refresh must recover before changing remote sessions")
    }

    /// Internal for the same reason as `remoteBackendsDisabledResponse` above:
    /// the worktree handlers' remote branches pass through the same gate.
    func remoteGate() async throws -> RemoteProviderManager? {
        guard try await db.config.get().remoteBackendsEnabled else { return nil }
        return remoteManager
    }

    /// `paramsJSON` is spliced raw into the provider's create request body
    /// (`{"params": <here>, ...}`). An empty/blank string is the common "no
    /// create params" shape and normalizes to `{}`; anything else must
    /// decode as a JSON object, or a malformed value would otherwise only
    /// surface as an opaque provider exit-2 with no indication of what was
    /// wrong.
    private static func normalizedParamsJSON(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "{}" }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              obj is [String: Any] else {
            return nil
        }
        return trimmed
    }

    /// Turns a provider timeout into a message the app can show, instead of
    /// letting `ProviderRunError.timeout`'s raw enum description
    /// (`timeout(verb: "stop")`) leak through the router's catch-all.
    private static func friendlyMessage(for error: ProviderRunError, provider: String) -> String {
        switch error {
        case .timeout(let verb):
            return "provider '\(provider)' timed out running '\(verb)'"
        }
    }

    func handleRemoteProviders() async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        // Re-read the registry first, so a provider added to
        // `agent-providers.json` while the daemon runs is registered and
        // enrolled rather than staying invisible until a restart.
        await manager.refreshRegistry()
        return try RPCResponse(result: RemoteProvidersResult(providers: await manager.providerStatuses()))
    }

    func handleRemoteSessions() async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let staleProviders = Set(
            await manager.providerStatuses()
                .filter(\.hasStaleSnapshot)
                .map { $0.config.name })
        let rows = try await db.remoteSessions.list()
        let sessions = rows.compactMap { row -> RemoteSessionInfo? in
            guard var payload = row.decodedPayload else { return nil }
            if staleProviders.contains(row.provider) {
                payload = payload.projectedForStaleSnapshot()
            }
            return RemoteSessionInfo(provider: row.provider, payload: payload,
                                     gone: row.gone, dismissed: row.dismissed,
                                     lastSeen: row.lastSeen, resolvedRepoID: row.resolvedRepoIDUUID,
                                     pinnedAt: row.pinnedAt)
        }
        return try RPCResponse(result: RemoteSessionsResult(sessions: sessions))
    }

    func handleRemoteCreate(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteCreateParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        if await manager.hasStaleSnapshot(provider: params.provider) {
            return Self.staleSnapshotMutationResponse(provider: params.provider)
        }
        guard let paramsJSON = Self.normalizedParamsJSON(params.paramsJSON) else {
            return RPCResponse(error: "remote.create paramsJSON must be a JSON object; got: \(params.paramsJSON)")
        }
        // `seed` is refused here rather than sent and hoped for, and refused
        // BEFORE the actuation row and before anything is spawned. The contract
        // requires a provider to ignore stdin fields it does not recognize, so
        // an unchecked send to a provider that never declared `seed` would exit
        // 0 with a brand-new empty session while the caller believed its
        // conversation had been carried over — the exact silent wrong answer
        // the capability gate exists to prevent. That is also why the check
        // sits here and not at a caller: nothing upstream is trusted to have
        // made it (the same rule `handleRemoteRetain` follows).
        if params.seedRetainedKey != nil {
            let capabilities = await declaredCapabilities(manager, provider: params.provider)
            guard capabilities.contains("seed") else {
                return Self.missingCapabilityResponse(
                    provider: params.provider, capability: "seed", section: "create")
            }
        }
        // The session ID is the provider's return value, so the request row
        // carries the provider alone; the resolved ID lands with the observed
        // rung, not here.
        let actuationID = try await beginActuation(
            .remoteCreate, actor: actor,
            target: .remote(provider: params.provider))
        // ponytail: the idempotency key is handler-scoped (retry-once on
        // timeout), not persisted — the provider dedupes on it for the
        // lifetime of a single create call, and a create that outlives even
        // the retry surfaces via the next snapshot poll's adoption anyway,
        // so there's nothing a persisted key would add.
        let key = "tbd-\(UUID().uuidString.lowercased())"
        let body = ProviderCreateBody.compose(
            paramsJSON: paramsJSON, seedRetainedKey: params.seedRetainedKey,
            idempotencyKey: key)
        let stdin = Data(body.utf8)
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: ["create"], stdin: stdin, timeout: Self.remoteCreateTimeout)
        } catch is ProviderRunError {
            // One retry with the SAME key — the provider dedupes, so a
            // timed-out-but-actually-succeeded create doesn't double-spawn.
            do {
                result = try await manager.invoke(
                    providerName: params.provider, verb: ["create"], stdin: stdin, timeout: Self.remoteCreateTimeout)
            } catch let error as ProviderRunError {
                remoteHandlerLogger.error(
                    "remote.create provider=\(params.provider, privacy: .public) timed out on both the initial call and the retry")
                let message = Self.friendlyMessage(for: error, provider: params.provider)
                await finishActuation(actuationID, .transportFailed, error: message)
                return RPCResponse(error: message)
            }
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "create failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.create provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        // A provider that exits 0 and returns garbage has lied at the transport
        // level, so its decode failure is an outcome like any other: without
        // this the throw would leave the request row unconfirmed forever, and
        // the record could not tell "the create failed" from "the outcome was
        // lost". The error propagates unchanged.
        let session = try await actuating(actuationID) {
            try result.decoded(RemoteSessionPayload.self)
        }
        // Adopt immediately so the sidebar shows `starting` before the next
        // poll — and, when the lane was started from a worktree's nested `+`,
        // with the parent the user clicked. That override rides the response,
        // not the provider: nothing about `parentWorktreeID` reached the
        // create call above.
        //
        // Known gap, deliberately unclosed: if BOTH invocations above time out
        // the create still surfaces, but through a later `list` poll that
        // carries no override — so the lane lands top-level and the user drags
        // it once. Closing it would mean persisting pending state for a case
        // that costs one drag.
        await manager.applyUpsert(
            session, provider: params.provider, parentWorktreeID: params.parentWorktreeID)
        // …and ask for one immediate snapshot, because a provider whose rows
        // arrive by adoption has nothing on screen until one lands. The upsert
        // above has already spent this row's one parent assignment, so the
        // snapshot cannot move it back to top level.
        await manager.refreshAfterCreate(provider: params.provider)
        await finishActuation(actuationID, .dispatched)
        return try RPCResponse(result: session)
    }

    func handleRemoteStop(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteStopParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        if await manager.hasStaleSnapshot(provider: params.provider) {
            return Self.staleSnapshotMutationResponse(provider: params.provider)
        }
        let actuationID = try await beginActuation(
            .remoteStop, actor: actor,
            target: .remote(provider: params.provider, session: params.sessionID))
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: ["stop", params.sessionID], stdin: nil, timeout: 30)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error("remote.stop provider=\(params.provider, privacy: .public) timed out")
            let message = Self.friendlyMessage(for: error, provider: params.provider)
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "stop failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.stop provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        if let session = try? result.decoded(RemoteSessionPayload.self) {
            await manager.applyUpsert(session, provider: params.provider)
        }
        await finishActuation(actuationID, .dispatched)
        return .ok()
    }

    /// The provider's declared capability set, read from the cached
    /// `describe` response — the same data the app reads client-side via
    /// `remoteProviders.first { ... }?.describe?.capabilities`
    /// (`AppState+Remote.swift`). A read of existing state, not a probe.
    ///
    /// Delegates to the manager rather than deriving it a second time, so
    /// this gate and the remote lane's archive/revive routing can never
    /// disagree about what a provider declared.
    private func declaredCapabilities(_ manager: RemoteProviderManager, provider: String) async -> Set<String> {
        await manager.declaredCapabilities(provider: provider)
    }

    /// The refusal a handler returns instead of invoking a verb the provider
    /// has not declared. `section` names the contract heading to read, and
    /// defaults to the `<verb> <id>` shape the session-addressed verbs use;
    /// the exchange verbs pass their own, because `import` takes no id and
    /// `recall` takes a key rather than one.
    private static func missingCapabilityResponse(
        provider: String, capability: String, section: String? = nil
    ) -> RPCResponse {
        RPCResponse(error:
            "provider '\(provider)' has not declared capability '\(capability)' " +
            "(docs/remote-provider-contract.md § \(section ?? "\(capability) <id>"))")
    }

    /// Retires a session from the working inventory
    /// (`docs/remote-provider-contract.md` § `archive <id>` / `unarchive
    /// <id>`). Mirrors `handleRemoteStop`'s shape exactly: same gate, same
    /// stale-snapshot guard, same timeout/failureClass handling, same
    /// best-effort mirror upsert of whatever session object the provider
    /// hands back — so the row reflects the new `archived` value immediately
    /// rather than waiting for the next poll.
    ///
    /// The one addition is the capability check in `retire`. `archive` is
    /// optional, and the contract states a caller "MUST NOT invoke a verb
    /// whose capability the provider has not declared" — unlike `rename`
    /// (whose doc comment explains why it skips this check: the app already
    /// decides there), nothing upstream of this handler is trusted to have
    /// checked, so it refuses before any process is spawned rather than
    /// letting the refusal masquerade as an ordinary provider failure.
    ///
    /// The gate runs here rather than inside `retire` so a request arriving
    /// with the subsystem off is refused before its params are decoded:
    /// "remote backends disabled" is the truthful answer to a malformed
    /// request too, and the decode would otherwise throw first.
    ///
    /// `now` supplies the filing watermark's instants, which are **compared**
    /// against a poll's request start rather than displayed — the date seam
    /// rather than the clock seam (`Tests/CLAUDE.md`, "Clock and date seams").
    /// Defaulted, so no call site changes.
    func handleRemoteArchive(
        _ paramsData: Data, actor: ActuationActor? = nil,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteArchiveParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        return try await retire(
            verb: "archive", surface: .remoteArchive, manager: manager,
            provider: params.provider, sessionID: params.sessionID, actor: actor, now: now)
    }

    /// Returns an archived session to the working inventory. See
    /// `handleRemoteArchive`'s doc comment for the shared shape and the
    /// capability-check rationale; this differs only in verb and surface.
    func handleRemoteUnarchive(
        _ paramsData: Data, actor: ActuationActor? = nil,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteUnarchiveParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        return try await retire(
            verb: "unarchive", surface: .remoteUnarchive, manager: manager,
            provider: params.provider, sessionID: params.sessionID, actor: actor, now: now)
    }

    /// The body both retirement handlers share. One implementation rather than
    /// two near-identical ones, because everything the two verbs differ by is a
    /// name: the verb word doubles as the capability the contract requires be
    /// declared, and the surface names the actuation.
    ///
    /// **The filing watermark is the reason this is not just `handleRemoteStop`
    /// with another verb.** `archive` and `unarchive` move a session's filing
    /// status, and every write to a remote row's status is watermarked
    /// whichever path made it — the same obligation
    /// `RemoteLaneLifecycle.performArchive` carries, discharged in the same
    /// order and for the same reasons:
    ///
    /// 1. stamp **before** the verb, so a `list` already in flight cannot act on
    ///    the bound row while the verb runs. The provider commits the retirement
    ///    partway through a call that takes up to 30 seconds, and a poll landing
    ///    in that window would otherwise read the provider's already-committed
    ///    `archived: true` against a row nothing had watermarked and file it on
    ///    the daemon's own `remote-filing-sync` rail — an extra actuation row,
    ///    and a notification crediting the provider for the user's own gesture;
    /// 2. stamp again once the verb has returned, before the response is
    ///    mirrored. A poll launched *after* step 1 but before the verb returned
    ///    still carries the provider's pre-gesture word, and a watermark that
    ///    only covers step 1 does not cover it;
    /// 3. mirror the response, whose `applyUpsert` runs the filing sync with an
    ///    arrival later than both stamps — so this gesture's own report is the
    ///    one the sync acts on.
    ///
    /// A verb that fails withdraws the watermark rather than deleting it
    /// (`withdrawFilingDecision(worktreeID:restoring:ifStillAt:)`): the row may
    /// carry an earlier decision that did happen and whose window is still
    /// open, and a gesture that failed has no business closing it.
    ///
    /// Unlike the lane path there is no row write here — this surface is
    /// addressed by `(provider, sessionID)`, not by worktree — so a session
    /// nobody has adopted has no bound row, nothing to watermark, and takes the
    /// unwatermarked path cleanly rather than erroring.
    private func retire(
        verb: String, surface: ActuationSurface, manager: RemoteProviderManager,
        provider: String, sessionID: String, actor: ActuationActor?,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> RPCResponse {
        if await manager.hasStaleSnapshot(provider: provider) {
            return Self.staleSnapshotMutationResponse(provider: provider)
        }
        guard await declaredCapabilities(manager, provider: provider).contains(verb) else {
            return Self.missingCapabilityResponse(provider: provider, capability: verb)
        }
        let actuationID = try await beginActuation(
            surface, actor: actor, target: .remote(provider: provider, session: sessionID))
        let watermark = await beginFilingWatermark(
            manager: manager, provider: provider, sessionID: sessionID, at: now())
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: provider, verb: [verb, sessionID], stdin: nil, timeout: 30)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error(
                "remote.\(verb, privacy: .public) provider=\(provider, privacy: .public) timed out")
            let message = Self.friendlyMessage(for: error, provider: provider)
            await watermark?.withdraw()
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "\(verb) failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.\(verb, privacy: .public) provider=\(provider, privacy: .public) failed: \(message, privacy: .public)")
            await watermark?.withdraw()
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        await watermark?.restamp(at: now())
        if let session = try? result.decoded(RemoteSessionPayload.self) {
            await manager.applyUpsert(session, provider: provider, date: now())
        }
        await finishActuation(actuationID, .dispatched)
        return .ok()
    }

    /// Resolves the worktree row bound to `(provider, sessionID)` and records a
    /// filing decision against it, returning the handle a caller withdraws or
    /// re-stamps through.
    ///
    /// `nil` means there is nothing to watermark, and it is a normal outcome
    /// twice over: a session nobody adopted has no bound row, and a row this
    /// daemon cannot read right now is one no watermark could protect anyway.
    /// Neither may fail the gesture — the provider verb is the act the user
    /// asked for, and refusing it because a mirror lookup failed would trade a
    /// working retirement for a bookkeeping detail.
    private func beginFilingWatermark(
        manager: RemoteProviderManager, provider: String, sessionID: String, at date: Date
    ) async -> RemoteFilingWatermark? {
        let bound: Worktree?
        do {
            bound = try await db.worktrees.findRemote(provider: provider, sessionID: sessionID)
        } catch {
            remoteHandlerLogger.warning(
                "could not resolve the row bound to \(provider, privacy: .public)/\(sessionID, privacy: .public); proceeding unwatermarked: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let bound else { return nil }
        let prior = await manager.noteFilingDecision(worktreeID: bound.id, at: date)
        return RemoteFilingWatermark(
            manager: manager, worktreeID: bound.id, decidedAt: date, prior: prior)
    }

    func handleRemoteSend(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteSendParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        if await manager.hasStaleSnapshot(provider: params.provider) {
            return Self.staleSnapshotMutationResponse(provider: params.provider)
        }
        let actuationID = try await beginActuation(
            .remoteSend, actor: actor,
            target: .remote(provider: params.provider, session: params.sessionID),
            message: params.text, submit: true)
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: ["send", params.sessionID],
                stdin: Data(params.text.utf8), timeout: 30)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error("remote.send provider=\(params.provider, privacy: .public) timed out")
            let message = Self.friendlyMessage(for: error, provider: params.provider)
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "send failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.send provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        await finishActuation(actuationID, .dispatched)
        return .ok()
    }

    func handleRemoteLog(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteLogParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        var verb = ["log", params.sessionID]
        if let lines = params.lines { verb += ["--lines", String(lines)] }
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: verb, stdin: nil, timeout: 30)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error("remote.log provider=\(params.provider, privacy: .public) timed out")
            return RPCResponse(error: Self.friendlyMessage(for: error, provider: params.provider))
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "log failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.log provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            return RPCResponse(error: message)
        }
        // Raw bytes by contract — lossy UTF-8 decode (never sanitized or
        // re-encoded) so ANSI passthrough from the provider survives intact.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: result.stdout, as: UTF8.self)
        return try RPCResponse(result: RemoteLogResult(text: text))
    }

    /// Pushes a rename to the provider (`<exec> rename <id> <title>`,
    /// capability `rename`). Mirrors `handleRemoteStop`'s shape exactly: same
    /// gate, same timeout/friendly-timeout-message handling, same
    /// failureClass → message surfacing, and the same best-effort mirror
    /// upsert of whatever session object the provider hands back. Whether the
    /// provider actually declares the capability is an APP-side decision
    /// (`AppState.pushRemoteRenameIfSupported`) — same division of
    /// responsibility as `remote.send`/`remote.log`, which also don't
    /// re-check capabilities here; a provider that doesn't implement `rename`
    /// simply exits non-2 and this surfaces that as an ordinary failure.
    func handleRemoteRename(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteRenameParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        if await manager.hasStaleSnapshot(provider: params.provider) {
            return Self.staleSnapshotMutationResponse(provider: params.provider)
        }
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider,
                verb: ["rename", params.sessionID, params.title],
                stdin: nil, timeout: 30)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error("remote.rename provider=\(params.provider, privacy: .public) timed out")
            return RPCResponse(error: Self.friendlyMessage(for: error, provider: params.provider))
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "rename failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.rename provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            return RPCResponse(error: message)
        }
        if let session = try? result.decoded(RemoteSessionPayload.self) {
            await manager.applyUpsert(session, provider: params.provider)
        }
        return .ok()
    }

    // MARK: - The transcript exchange

    /// The budget for all three exchange verbs, matching the contract's
    /// 60-second timeout for `retain`, `import`, and `recall` — a transcript is
    /// a whole conversation, and the two store-writing verbs may be moving it
    /// across a network.
    private static let exchangeTimeout: TimeInterval = 60

    /// Retains one of the provider's own sessions' transcripts
    /// (`docs/remote-provider-contract.md` § `retain <id>`). Mirrors
    /// `handleRemoteLog`'s shape — same outer gate, same cloud gate, same
    /// timeout and `failureClass` branches — with two additions.
    ///
    /// **The capability is checked before anything is invoked.** The contract
    /// states a caller "MUST NOT invoke a verb whose capability the provider
    /// has not declared", and nothing upstream of this handler is trusted to
    /// have checked, so a missing capability is a refusal naming it rather than
    /// an opaque provider failure — the same rule `retire` follows for
    /// `archive`/`unarchive`.
    ///
    /// **The receipt is recorded before the response is returned.** A key is
    /// opaque and the contract gives no way to enumerate the keys a provider
    /// issued, so a key that does not reach `retained_transcript` is a
    /// retained transcript nobody can ever recall. Recording it is therefore
    /// part of the verb, not bookkeeping around it — but a row that fails to
    /// write must not fail a retention the provider already performed, so the
    /// failure is logged and the receipt is still returned.
    func handleRemoteRetain(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteRetainParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        guard await declaredCapabilities(manager, provider: params.provider).contains("retain") else {
            return Self.missingCapabilityResponse(
                provider: params.provider, capability: "retain", section: "retain <id> / import")
        }
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: ["retain", params.sessionID],
                stdin: nil, timeout: Self.exchangeTimeout)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error("remote.retain provider=\(params.provider, privacy: .public) timed out")
            return RPCResponse(error: Self.friendlyMessage(for: error, provider: params.provider))
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "retain failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.retain provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            return RPCResponse(error: message)
        }
        let receipt = try result.decoded(RetainReceipt.self, provider: params.provider)
        await recordReceipt(receipt, provider: params.provider, sessionID: params.sessionID)
        return try RPCResponse(result: receipt)
    }

    /// Puts a transcript from anywhere — including this machine — into a
    /// provider's durable store (`docs/remote-provider-contract.md` §
    /// `import`). See `handleRemoteRetain` for the shared shape and for why the
    /// capability check and the receipt row are both part of the verb.
    ///
    /// Unlike `retain` there is no session on this provider, so the recorded
    /// row carries no source session id and no origin lane. Malformed JSONL is
    /// the provider's `invalid_params`, surfaced through the ordinary
    /// `failureClass` branch rather than pre-validated here: the contract makes
    /// the provider the validator of record, and a caller that parsed the
    /// records first would be a second, divergent one.
    func handleRemoteImport(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteImportParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        guard await declaredCapabilities(manager, provider: params.provider).contains("import") else {
            return Self.missingCapabilityResponse(
                provider: params.provider, capability: "import", section: "retain <id> / import")
        }
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: ["import"],
                stdin: Data(params.jsonl.utf8), timeout: Self.exchangeTimeout)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error("remote.import provider=\(params.provider, privacy: .public) timed out")
            return RPCResponse(error: Self.friendlyMessage(for: error, provider: params.provider))
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "import failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.import provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            return RPCResponse(error: message)
        }
        let receipt = try result.decoded(RetainReceipt.self, provider: params.provider)
        await recordReceipt(receipt, provider: params.provider, sessionID: nil)
        return try RPCResponse(result: receipt)
    }

    /// Reads a retained transcript back (`docs/remote-provider-contract.md` §
    /// `recall <key>`). See `handleRemoteRetain` for the shared shape.
    ///
    /// **stdout is the whole response.** `recall` writes nothing to stderr —
    /// the contract keeps exactly one stderr exception, `transcript`'s cursor
    /// envelope, and a retained transcript is immutable so a cursor would have
    /// nothing to mean. Truncation is detected against the receipt's `bytes`
    /// instead, which is why a short read is logged here naming both counts.
    ///
    /// A short read is **not** an error: the records that did arrive are real,
    /// and refusing them would turn a partial transcript into no transcript.
    /// The caller gets the bytes and the log says what was missing.
    func handleRemoteRecall(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteRecallParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        guard await declaredCapabilities(manager, provider: params.provider).contains("recall") else {
            return Self.missingCapabilityResponse(
                provider: params.provider, capability: "recall", section: "recall <key>")
        }
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: ["recall", params.key],
                stdin: nil, timeout: Self.exchangeTimeout)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error("remote.recall provider=\(params.provider, privacy: .public) timed out")
            return RPCResponse(error: Self.friendlyMessage(for: error, provider: params.provider))
        }
        if result.failureClass != nil {
            // Carries `not_found` and `expired` — the two codes this verb
            // defines — through unchanged, so a caller can say a record lapsed
            // rather than claim it never existed.
            let message = result.decodedError?.message ?? "recall failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.recall provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            return RPCResponse(error: message)
        }
        await warnOnShortRecall(
            provider: params.provider, key: params.key, received: result.stdout.count)
        // JSONL records by contract — lossy UTF-8 decode, never sanitized or
        // re-encoded, on the same terms as `remote.log`'s raw bytes.
        // swiftlint:disable:next optional_data_string_conversion
        let jsonl = String(decoding: result.stdout, as: UTF8.self)
        var localPath: String?
        if params.saveLocally {
            localPath = await saveRecalledTranscript(
                result.stdout, provider: params.provider, key: params.key)
        }
        return try RPCResponse(result: RemoteRecallResult(jsonl: jsonl, localPath: localPath))
    }

    /// The conversation of a session the provider still has
    /// (`docs/remote-provider-contract.md` § `transcript <id>`). See
    /// `handleRemoteRetain` for the shared shape and for why the capability is
    /// checked before anything is invoked.
    ///
    /// **stderr is dropped on the floor, deliberately.** `transcript` is the
    /// contract's one stderr exception: it may write a continuation-cursor
    /// envelope there. This RPC reads the whole transcript in one call and has
    /// nowhere to keep a cursor between calls, so carrying it across the RPC
    /// boundary would hand every caller a token none of them could use. A
    /// caller that wants what accumulated since refetches.
    ///
    /// It is emphatically not `log`. The contract states the two are different
    /// data rather than two encodings of one — structured conversation records
    /// against raw ANSI scrollback — and that a caller MUST NOT substitute one
    /// for the other, so this verb exists rather than `remote.log` being reused.
    func handleRemoteTranscript(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteTranscriptParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        guard await declaredCapabilities(manager, provider: params.provider).contains("transcript") else {
            return Self.missingCapabilityResponse(
                provider: params.provider, capability: "transcript",
                section: "transcript <id> [--since <cursor>]")
        }
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: ["transcript", params.sessionID],
                stdin: nil, timeout: Self.exchangeTimeout)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error(
                "remote.transcript provider=\(params.provider, privacy: .public) timed out")
            return RPCResponse(error: Self.friendlyMessage(for: error, provider: params.provider))
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "transcript failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.transcript provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            return RPCResponse(error: message)
        }
        // JSONL records by contract — lossy UTF-8 decode, never sanitized or
        // re-encoded, on the same terms as `remote.recall`'s bytes.
        // swiftlint:disable:next optional_data_string_conversion
        let jsonl = String(decoding: result.stdout, as: UTF8.self)
        return try RPCResponse(result: RemoteTranscriptResult(jsonl: jsonl))
    }

    /// Lists the receipts TBD holds, optionally filtered to one provider.
    ///
    /// Local-only — it reads TBD's own rows and never invokes a provider verb,
    /// so unlike the three verbs above it needs no `RemoteProviderManager`, no
    /// cloud gate, and no capability. It still passes through `remoteGate()`
    /// because the whole feature hides behind `config.remoteBackendsEnabled`,
    /// which is the same reason `handleRemoteSetPin` does.
    func handleRemoteRetainedList(_ paramsData: Data) async throws -> RPCResponse {
        guard try await remoteGate() != nil else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteRetainedListParams.self, from: paramsData)
        let transcripts: [RetainedTranscript]
        if let provider = params.provider {
            transcripts = try await db.retainedTranscripts.all(provider: provider)
        } else {
            transcripts = try await db.retainedTranscripts.all()
        }
        return try RPCResponse(result: RemoteRetainedListResult(transcripts: transcripts))
    }

    /// Writes one receipt into `retained_transcript`, filling in whatever TBD
    /// already knows about the session it came from.
    ///
    /// Never throws. A retention the provider already performed must not be
    /// reported as a failure because a local row would not write — the key
    /// would then be lost twice over, since the response the caller never saw
    /// carried it. The error is logged loudly instead, naming the key, because
    /// that log line is the last place the key exists.
    private func recordReceipt(
        _ receipt: RetainReceipt, provider: String, sessionID: String?
    ) async {
        var sourceTitle: String?
        var resolvedRepoID: UUID?
        var originWorktreeID: UUID?
        if let sessionID {
            let row = try? await db.remoteSessions.row(provider: provider, sessionID: sessionID)
            sourceTitle = row?.decodedPayload?.title
            resolvedRepoID = row?.resolvedRepoIDUUID
            originWorktreeID = try? await db.worktrees
                .findRemote(provider: provider, sessionID: sessionID)?.id
        }
        do {
            try await db.retainedTranscripts.insert(RetainedTranscript(
                provider: provider, key: receipt.key, expiresAt: receipt.expiresAt,
                bytes: receipt.bytes, sourceSessionID: sessionID, sourceTitle: sourceTitle,
                resolvedRepoID: resolvedRepoID, originWorktreeID: originWorktreeID,
                localPath: nil))
        } catch {
            remoteHandlerLogger.error("""
                could not record the retained-transcript receipt for \
                \(provider, privacy: .public) key \(receipt.key, privacy: .public): \
                \(error.localizedDescription, privacy: .public). The key is in this log line \
                and nowhere else — nothing enumerates a provider's keys
                """)
        }
    }

    /// Compares what `recall` returned against the byte count the receipt
    /// claimed, and logs at `.error` when it falls short.
    ///
    /// Silent when TBD holds no receipt for this key — a key recalled from
    /// another machine, or one recorded before this table existed, gives
    /// nothing to compare against, and a comparison against zero would report
    /// every such recall as short.
    private func warnOnShortRecall(provider: String, key: String, received: Int) async {
        guard let receipt = try? await db.retainedTranscripts.find(provider: provider, key: key),
              received < receipt.bytes else { return }
        remoteHandlerLogger.error("""
            remote.recall provider=\(provider, privacy: .public) returned \
            \(received, privacy: .public) bytes for a receipt claiming \
            \(receipt.bytes, privacy: .public); the transcript is truncated
            """)
    }

    /// Writes the recalled records under `~/tbd/transcripts/<provider>/<key>.jsonl`
    /// and records that path on the receipt row. Returns the path written, or
    /// nil when nothing was written.
    ///
    /// The path comes from `TBDConstants`, never composed from `$HOME`, so the
    /// test fence covers it.
    ///
    /// A failed write is nil rather than an error: the records arrived, and the
    /// caller has them in the response regardless of whether this disk would
    /// take a copy.
    private func saveRecalledTranscript(_ data: Data, provider: String, key: String) async -> String? {
        let url = TBDConstants.retainedTranscriptPath(provider: provider, key: key)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            remoteHandlerLogger.error("""
                could not write the recalled transcript for \(provider, privacy: .public) \
                key \(key, privacy: .public) to \(url.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }
        do {
            try await db.retainedTranscripts.setLocalPath(
                provider: provider, key: key, localPath: url.path)
        } catch {
            // The file is on disk either way; only the row's pointer to it is
            // lost, and the GC leg reconciles files against rows.
            remoteHandlerLogger.warning("""
                wrote \(url.path, privacy: .public) but could not record it on the receipt row: \
                \(error.localizedDescription, privacy: .public)
                """)
        }
        return url.path
    }

    /// The contract's budget for `delete`. Shorter than the exchange verbs'
    /// 60 seconds because a delete moves no transcript — with `--retain` the
    /// provider is doing both, and the contract still says 30, so this follows
    /// the contract rather than second-guessing it.
    private static let deleteTimeout: TimeInterval = 30

    /// Destroys a provider-hosted session (`docs/remote-provider-contract.md` §
    /// `delete <id> [--retain]`). Mirrors `handleRemoteStop`'s shape — same
    /// outer gate, same cloud gate, same `ProviderRunError` timeout branch,
    /// same `failureClass` branch surfacing `decodedError?.message` — with
    /// three additions the other verbs do not carry.
    ///
    /// **The feature flag is checked before the capability, and after the two
    /// subsystem gates.** The subsystem gates answer whether the request is
    /// admissible at all, and every provider-named `remote.*` method must
    /// refuse identically when they are shut; the flag is this feature's own
    /// policy and belongs after them. It sits before the capability check and
    /// before anything is spawned, so a daemon with the flag off never runs a
    /// provider's `delete` for any reason.
    ///
    /// **`--retain` needs the `retain` capability too.** The contract makes the
    /// flag valid only where the provider declares `retain`; sending it to a
    /// provider that does not would either be ignored — destroying a session
    /// the caller believed was being preserved — or fail after the fact.
    ///
    /// **A successful delete drops the mirror row at once.** See
    /// `RemoteSessionStore.deleteRow` for why this must not wait for the drift
    /// rule; it is the piece of this handler most likely to read as redundant
    /// and be removed.
    ///
    /// **And the drop is interlocked against polls in flight.** Dropping a row
    /// races the `list` loop: a poll that captured its snapshot before the
    /// provider committed the deletion applies it afterwards and re-inserts the
    /// row with `gone` false, which is the two-poll limbo the immediate drop
    /// exists to prevent, arrived at by a different route. So the delete stamps
    /// a deletion watermark before the verb and again after it returns, and
    /// withdraws it on every failure exit —
    /// `RemoteProviderManager.noteDeletion`.
    ///
    /// `deleted: false` is a success, not an error: the contract has deleting
    /// an unknown or already-deleted id exit 0 saying so, and the caller's
    /// intent — that this session not exist — holds either way. The row is
    /// dropped and the lane filed on that reading too, because the provider has
    /// just stated the session is not there.
    func handleRemoteDelete(
        _ paramsData: Data, actor: ActuationActor? = nil,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteDeleteParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        guard try await db.config.get().remoteDeleteEnabled else {
            return Self.remoteDeleteDisabledResponse
        }
        let capabilities = await declaredCapabilities(manager, provider: params.provider)
        guard capabilities.contains("delete") else {
            return Self.missingCapabilityResponse(
                provider: params.provider, capability: "delete",
                section: "delete <id> [--retain]")
        }
        if params.retain, !capabilities.contains("retain") {
            return Self.missingCapabilityResponse(
                provider: params.provider, capability: "retain",
                section: "delete <id> [--retain]")
        }
        let actuationID = try await beginActuation(
            .remoteDelete, actor: actor,
            target: .remote(provider: params.provider, session: params.sessionID))
        // Stamped BEFORE the verb, and again after it returns. See
        // `RemoteProviderManager.noteDeletion` for what each stamp covers;
        // without them the row this handler drops below is re-inserted, with
        // `gone` false, by the next `list` whose snapshot predates the delete —
        // reproducing exactly the two-poll limbo the immediate drop exists to
        // prevent.
        let decidedAt = now()
        let deletion = RemoteDeletionWatermark(
            manager: manager, provider: params.provider, sessionID: params.sessionID,
            decidedAt: decidedAt,
            prior: await manager.noteDeletion(
                provider: params.provider, sessionID: params.sessionID, at: decidedAt))
        var verb = ["delete", params.sessionID]
        if params.retain { verb.append("--retain") }
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: verb, stdin: nil,
                timeout: Self.deleteTimeout)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error(
                "remote.delete provider=\(params.provider, privacy: .public) timed out")
            let message = Self.friendlyMessage(for: error, provider: params.provider)
            await deletion.withdraw()
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "delete failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.delete provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            await deletion.withdraw()
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        let outcome: RemoteDeleteResult
        do {
            outcome = try result.decoded(RemoteDeleteResult.self, provider: params.provider)
        } catch {
            // The session may well be destroyed — the provider exited 0 — but
            // TBD cannot say so from an unreadable answer, and must not drop
            // the row on a guess. A contract bug is reported as one.
            let message = "provider '\(params.provider)' returned an unreadable delete result"
            remoteHandlerLogger.error(
                "remote.delete provider=\(params.provider, privacy: .public): \(message, privacy: .public)")
            await deletion.withdraw()
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        // The session is destroyed, whether this call did it or found it
        // already gone. Either way a poll launched while the verb ran carries
        // the pre-delete inventory, so the watermark moves past it before the
        // row is dropped.
        await deletion.restamp(at: now())
        await recordDeleteAftermath(outcome, params: params, now: now)
        await finishActuation(actuationID, .dispatched)
        return try RPCResponse(result: outcome)
    }

    /// Everything TBD writes down once a `delete` has come back successfully,
    /// in the one order that works.
    ///
    /// 1. **Record the receipt first**, while the mirror row and the lane are
    ///    still there to be read: `recordReceipt` fills the row's title, repo
    ///    and originating lane from them, and those are what make a key
    ///    findable by a human months later. After step 2 they are gone.
    /// 2. **Drop the mirror row**, immediately — see
    ///    `RemoteSessionStore.deleteRow`.
    /// 3. **File the adopted lane**, so a deleted lane keeps its place in the
    ///    repo's Archived tab with its branch and PR context.
    ///
    /// Nothing here can fail the delete. The provider has already destroyed the
    /// session; a bookkeeping write that throws is logged and the caller still
    /// hears that the destruction happened, because reporting failure would
    /// invite a retry of an act that cannot be repeated.
    private func recordDeleteAftermath(
        _ outcome: RemoteDeleteResult, params: RemoteDeleteParams,
        now: @Sendable () -> Date
    ) async {
        if let receipt = outcome.retained {
            await recordReceipt(
                receipt, provider: params.provider, sessionID: params.sessionID)
        }
        let lane = try? await db.worktrees.findRemote(
            provider: params.provider, sessionID: params.sessionID)
        do {
            if try await db.remoteSessions.deleteRow(
                provider: params.provider, sessionID: params.sessionID) {
                subscriptions.broadcast(delta: .remoteSessionsChanged)
            }
        } catch {
            remoteHandlerLogger.error("""
                deleted \(params.provider, privacy: .public)/\(params.sessionID, privacy: .public) \
                but could not drop its mirror row: \(error.localizedDescription, privacy: .public). \
                The drift rule will reach the same answer two polls from now
                """)
        }
        guard let lane, let manager = remoteManager else { return }
        let lanes = RemoteLaneLifecycle(db: db, subscriptions: subscriptions, manager: manager)
        do {
            if let message = try await lanes.archiveLaneAfterDelete(lane, now: now) {
                remoteHandlerLogger.error("""
                    deleted \(params.provider, privacy: .public)/\(params.sessionID, privacy: .public) \
                    but could not file its lane: \(message, privacy: .public)
                    """)
            }
        } catch {
            remoteHandlerLogger.error("""
                deleted \(params.provider, privacy: .public)/\(params.sessionID, privacy: .public) \
                but could not file its lane: \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    func handleRemoteDismiss(_ paramsData: Data) async throws -> RPCResponse {
        guard try await remoteGate() != nil else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteDismissParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        let changed = try await db.remoteSessions.dismiss(provider: params.provider, sessionID: params.sessionID)
        if changed {
            subscriptions.broadcast(delta: .remoteSessionsChanged)
        }
        return .ok()
    }

    /// Pin or unpin a remote session for the sidebar dock. Local-only — it
    /// touches the mirror row and never invokes a provider verb, so unlike
    /// every handler above it needs no `RemoteProviderManager` (a session
    /// whose provider has gone unhealthy, or whose row is already `gone`, can
    /// still be unpinned). It still passes through `remoteGate()` because the
    /// whole feature hides behind `config.remoteBackendsEnabled`.
    ///
    /// The timestamp is stamped HERE rather than by the client, so pin order
    /// is server-assigned and consistent across clients — the same contract
    /// `handleWorktreeSetPin` follows.
    func handleRemoteSetPin(_ paramsData: Data) async throws -> RPCResponse {
        guard try await remoteGate() != nil else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteSetPinParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        let changed = try await db.remoteSessions.setPinned(
            provider: params.provider, sessionID: params.sessionID,
            pinnedAt: params.pinned ? Date() : nil)
        if changed {
            subscriptions.broadcast(delta: .remoteSessionsChanged)
        }
        return .ok()
    }

    /// Correlate an `attach` exit the APP observed with provider health.
    /// `attach` is exec'd on a terminal's own TTY by the app, so this is the
    /// only way that exit code ever reaches the daemon — and the exit code is
    /// all there is, since attach's stdout is a PTY stream that MUST NOT be
    /// parsed (`docs/remote-provider-contract.md` § `attach`).
    ///
    /// Purely additive: every classification decision (which classes move
    /// health, preserving existing remediation, the single bounded re-probe)
    /// lives in `RemoteProviderManager.recordAttachExit`. An unknown provider
    /// throws `RemoteProviderError.unknownProvider` out of this handler and
    /// surfaces through the router's catch-all, exactly like the `invoke`-based
    /// handlers above.
    func handleRemoteReportAttachExit(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteReportAttachExitParams.self, from: paramsData)
        if let refusal = try await cloudGate(provider: params.provider) { return refusal }
        try await manager.recordAttachExit(provider: params.provider, exitCode: params.exitCode)
        return .ok()
    }
}
