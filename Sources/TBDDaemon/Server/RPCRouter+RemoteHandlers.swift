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
        guard try await remoteGate() != nil else {
            return Self.remoteBackendsDisabledResponse
        }
        let rows = try await db.remoteSessions.list()
        let sessions = rows.compactMap { row -> RemoteSessionInfo? in
            guard let payload = row.decodedPayload else { return nil }
            return RemoteSessionInfo(provider: row.provider, payload: payload,
                                     gone: row.gone, dismissed: row.dismissed,
                                     lastSeen: row.lastSeen, resolvedRepoID: row.resolvedRepoIDUUID)
        }
        return try RPCResponse(result: RemoteSessionsResult(sessions: sessions))
    }

    func handleRemoteCreate(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteCreateParams.self, from: paramsData)
        guard let paramsJSON = Self.normalizedParamsJSON(params.paramsJSON) else {
            return RPCResponse(error: "remote.create paramsJSON must be a JSON object; got: \(params.paramsJSON)")
        }
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
                return RPCResponse(error: Self.friendlyMessage(for: error, provider: params.provider))
            }
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "create failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.create provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            return RPCResponse(error: message)
        }
        let session = try result.decoded(RemoteSessionPayload.self)
        // Adopt immediately so the sidebar shows `starting` before the next poll.
        await manager.applyUpsert(session, provider: params.provider)
        return try RPCResponse(result: session)
    }

    func handleRemoteStop(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteStopParams.self, from: paramsData)
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: ["stop", params.sessionID], stdin: nil, timeout: 30)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error("remote.stop provider=\(params.provider, privacy: .public) timed out")
            return RPCResponse(error: Self.friendlyMessage(for: error, provider: params.provider))
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "stop failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.stop provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            return RPCResponse(error: message)
        }
        if let session = try? result.decoded(RemoteSessionPayload.self) {
            await manager.applyUpsert(session, provider: params.provider)
        }
        return .ok()
    }

    func handleRemoteSend(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return Self.remoteBackendsDisabledResponse
        }
        let params = try decoder.decode(RemoteSendParams.self, from: paramsData)
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: ["send", params.sessionID],
                stdin: Data(params.text.utf8), timeout: 30)
        } catch let error as ProviderRunError {
            remoteHandlerLogger.error("remote.send provider=\(params.provider, privacy: .public) timed out")
            return RPCResponse(error: Self.friendlyMessage(for: error, provider: params.provider))
        }
        if result.failureClass != nil {
            let message = result.decodedError?.message ?? "send failed (exit \(result.exitCode))"
            remoteHandlerLogger.error(
                "remote.send provider=\(params.provider, privacy: .public) failed: \(message, privacy: .public)")
            return RPCResponse(error: message)
        }
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
}
