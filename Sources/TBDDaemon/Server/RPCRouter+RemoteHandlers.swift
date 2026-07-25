import Foundation
import TBDShared

/// RPC handlers for remote agent backends (`docs/remote-provider-contract.md`).
/// Every `remote.*` verb gates on `config.remoteBackendsEnabled` AND on the
/// `remoteManager` actor existing — the daemon only constructs it at boot
/// when the flag was on then (`Daemon.swift`), so a user flipping the flag
/// on without restarting still has a `nil` manager. Both causes collapse to
/// the same "remote backends disabled" error rather than crashing or
/// silently no-oping.
extension RPCRouter {
    private func remoteGate() async throws -> RemoteProviderManager? {
        guard try await db.config.get().remoteBackendsEnabled else { return nil }
        return remoteManager
    }

    func handleRemoteProviders() async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return RPCResponse(error: "remote backends disabled")
        }
        return try RPCResponse(result: RemoteProvidersResult(providers: await manager.providerStatuses()))
    }

    func handleRemoteSessions() async throws -> RPCResponse {
        guard try await remoteGate() != nil else {
            return RPCResponse(error: "remote backends disabled")
        }
        let rows = try await db.remoteSessions.list()
        let sessions = rows.compactMap { row -> RemoteSessionInfo? in
            guard let payload = row.decodedPayload else { return nil }
            return RemoteSessionInfo(provider: row.provider, payload: payload,
                                     gone: row.gone, dismissed: row.dismissed,
                                     lastSeen: row.lastSeen)
        }
        return try RPCResponse(result: RemoteSessionsResult(sessions: sessions))
    }

    func handleRemoteCreate(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return RPCResponse(error: "remote backends disabled")
        }
        let params = try decoder.decode(RemoteCreateParams.self, from: paramsData)
        // ponytail: the idempotency key is handler-scoped (retry-once on
        // timeout), not persisted — the provider dedupes on it for the
        // lifetime of a single create call, and a create that outlives even
        // the retry surfaces via the next snapshot poll's adoption anyway,
        // so there's nothing a persisted key would add.
        let key = "tbd-\(UUID().uuidString.lowercased())"
        let body = #"{"params": \#(params.paramsJSON), "idempotency_key": "\#(key)"}"#
        let stdin = Data(body.utf8)
        let result: ProviderResult
        do {
            result = try await manager.invoke(
                providerName: params.provider, verb: ["create"], stdin: stdin, timeout: 60)
        } catch is ProviderRunError {
            // One retry with the SAME key — the provider dedupes, so a
            // timed-out-but-actually-succeeded create doesn't double-spawn.
            result = try await manager.invoke(
                providerName: params.provider, verb: ["create"], stdin: stdin, timeout: 60)
        }
        if result.failureClass != nil {
            return RPCResponse(error: result.decodedError?.message ?? "create failed (exit \(result.exitCode))")
        }
        let session = try result.decoded(RemoteSessionPayload.self)
        // Adopt immediately so the sidebar shows `starting` before the next poll.
        await manager.applyUpsert(session, provider: params.provider)
        return try RPCResponse(result: session)
    }

    func handleRemoteStop(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return RPCResponse(error: "remote backends disabled")
        }
        let params = try decoder.decode(RemoteStopParams.self, from: paramsData)
        let result = try await manager.invoke(
            providerName: params.provider, verb: ["stop", params.sessionID], stdin: nil, timeout: 30)
        if result.failureClass != nil {
            return RPCResponse(error: result.decodedError?.message ?? "stop failed (exit \(result.exitCode))")
        }
        if let session = try? result.decoded(RemoteSessionPayload.self) {
            await manager.applyUpsert(session, provider: params.provider)
        }
        return .ok()
    }

    func handleRemoteSend(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return RPCResponse(error: "remote backends disabled")
        }
        let params = try decoder.decode(RemoteSendParams.self, from: paramsData)
        let result = try await manager.invoke(
            providerName: params.provider, verb: ["send", params.sessionID],
            stdin: Data(params.text.utf8), timeout: 30)
        if result.failureClass != nil {
            return RPCResponse(error: result.decodedError?.message ?? "send failed (exit \(result.exitCode))")
        }
        return .ok()
    }

    func handleRemoteLog(_ paramsData: Data) async throws -> RPCResponse {
        guard let manager = try await remoteGate() else {
            return RPCResponse(error: "remote backends disabled")
        }
        let params = try decoder.decode(RemoteLogParams.self, from: paramsData)
        var verb = ["log", params.sessionID]
        if let lines = params.lines { verb += ["--lines", String(lines)] }
        let result = try await manager.invoke(
            providerName: params.provider, verb: verb, stdin: nil, timeout: 30)
        if result.failureClass != nil {
            return RPCResponse(error: result.decodedError?.message ?? "log failed (exit \(result.exitCode))")
        }
        // Raw bytes by contract — lossy UTF-8 decode (never sanitized or
        // re-encoded) so ANSI passthrough from the provider survives intact.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: result.stdout, as: UTF8.self)
        return try RPCResponse(result: RemoteLogResult(text: text))
    }

    func handleRemoteDismiss(_ paramsData: Data) async throws -> RPCResponse {
        guard try await remoteGate() != nil else {
            return RPCResponse(error: "remote backends disabled")
        }
        let params = try decoder.decode(RemoteDismissParams.self, from: paramsData)
        try await db.remoteSessions.dismiss(provider: params.provider, sessionID: params.sessionID)
        subscriptions.broadcast(delta: .remoteSessionsChanged)
        return .ok()
    }
}
