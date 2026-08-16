import Foundation
import os
import TBDShared

private let remoteHandlerLogger = Logger(subsystem: "com.tbd.daemon", category: "remote")

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
    private static let remoteBackendsDisabledResponse = RPCResponse(error: "remote backends disabled")

    private static func staleSnapshotMutationResponse(provider: String) -> RPCResponse {
        RPCResponse(error: "provider '\(provider)' inventory is stale; refresh must recover before changing remote sessions")
    }

    private func remoteGate() async throws -> RemoteProviderManager? {
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
        if await manager.hasStaleSnapshot(provider: params.provider) {
            return Self.staleSnapshotMutationResponse(provider: params.provider)
        }
        guard let paramsJSON = Self.normalizedParamsJSON(params.paramsJSON) else {
            return RPCResponse(error: "remote.create paramsJSON must be a JSON object; got: \(params.paramsJSON)")
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
        let body = #"{"params": \#(paramsJSON), "idempotency_key": "\#(key)"}"#
        let stdin = Data(body.utf8)
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: ["create"], stdin: stdin, timeout: 60)
        } catch is ProviderRunError {
            // One retry with the SAME key — the provider dedupes, so a
            // timed-out-but-actually-succeeded create doesn't double-spawn.
            do {
                result = try await manager.invoke(
                    providerName: params.provider, verb: ["create"], stdin: stdin, timeout: 60)
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
        // Adopt immediately so the sidebar shows `starting` before the next poll.
        await manager.applyUpsert(session, provider: params.provider)
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
    /// `describe` response `providerStatuses()` already exposes — the same
    /// data the app reads client-side via
    /// `remoteProviders.first { ... }?.describe?.capabilities`
    /// (`AppState+Remote.swift`). No new manager surface: this is a read of
    /// existing state, not a probe.
    private func declaredCapabilities(_ manager: RemoteProviderManager, provider: String) async -> Set<String> {
        let status = await manager.providerStatuses().first { $0.config.name == provider }
        return Set(status?.describe?.capabilities ?? [])
    }

    private static func missingCapabilityResponse(provider: String, capability: String) -> RPCResponse {
        RPCResponse(error:
            "provider '\(provider)' has not declared capability '\(capability)' " +
            "(docs/remote-provider-contract.md § \(capability) <id>)")
    }

    /// Retires a session from the working inventory
    /// (`docs/remote-provider-contract.md` § `archive <id>` / `unarchive
    /// <id>`). Mirrors `handleRemoteStop`'s shape exactly: same gate, same
    /// stale-snapshot guard, same timeout/failureClass handling, same
    /// best-effort mirror upsert of whatever session object the provider
    /// hands back — so the row reflects the new `archived` value immediately
    /// rather than waiting for the next poll.
    ///
    /// The one addition is the capability check below. `archive` is
    /// optional, and the contract states a caller "MUST NOT invoke a verb
    /// whose capability the provider has not declared" — unlike `rename`
    /// (whose doc comment explains why it skips this check: the app already
    /// decides there), nothing upstream of this handler is trusted to have
    /// checked, so it refuses before any process is spawned rather than
    /// letting the refusal masquerade as an ordinary provider failure.
    func handleRemoteArchive(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteArchiveParams.self, from: paramsData)
        if await manager.hasStaleSnapshot(provider: params.provider) {
            return Self.staleSnapshotMutationResponse(provider: params.provider)
        }
        guard await declaredCapabilities(manager, provider: params.provider).contains("archive") else {
            return Self.missingCapabilityResponse(provider: params.provider, capability: "archive")
        }
        let actuationID = try await beginActuation(
            .remoteArchive, actor: actor,
            target: .remote(provider: params.provider, session: params.sessionID))
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: ["archive", params.sessionID], stdin: nil, timeout: 30)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error("remote.archive provider=\(params.provider, privacy: .public) timed out")
            let message = Self.friendlyMessage(for: error, provider: params.provider)
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "archive failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.archive provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        if let session = try? result.decoded(RemoteSessionPayload.self) {
            await manager.applyUpsert(session, provider: params.provider)
        }
        await finishActuation(actuationID, .dispatched)
        return .ok()
    }

    /// Returns an archived session to the working inventory. See
    /// `handleRemoteArchive`'s doc comment for the shared shape and the
    /// capability-check rationale; this differs only in verb and capability
    /// name.
    func handleRemoteUnarchive(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteUnarchiveParams.self, from: paramsData)
        if await manager.hasStaleSnapshot(provider: params.provider) {
            return Self.staleSnapshotMutationResponse(provider: params.provider)
        }
        guard await declaredCapabilities(manager, provider: params.provider).contains("unarchive") else {
            return Self.missingCapabilityResponse(provider: params.provider, capability: "unarchive")
        }
        let actuationID = try await beginActuation(
            .remoteUnarchive, actor: actor,
            target: .remote(provider: params.provider, session: params.sessionID))
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: ["unarchive", params.sessionID], stdin: nil, timeout: 30)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error("remote.unarchive provider=\(params.provider, privacy: .public) timed out")
            let message = Self.friendlyMessage(for: error, provider: params.provider)
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "unarchive failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.unarchive provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            await finishActuation(actuationID, .transportFailed, error: message)
            return RPCResponse(error: message)
        }
        if let session = try? result.decoded(RemoteSessionPayload.self) {
            await manager.applyUpsert(session, provider: params.provider)
        }
        await finishActuation(actuationID, .dispatched)
        return .ok()
    }

    func handleRemoteSend(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteSendParams.self, from: paramsData)
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

    func handleRemoteDismiss(_ paramsData: Data) async throws -> RPCResponse {
        guard try await remoteGate() != nil else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteDismissParams.self, from: paramsData)
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
        try await manager.recordAttachExit(provider: params.provider, exitCode: params.exitCode)
        return .ok()
    }
}
