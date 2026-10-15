import Foundation
import TBDShared

/// `peer.status` — everything TBD knows about the remote peer-messaging bridge,
/// in one read-only answer.
///
/// It exists because `tbd peer list` reaches the daemon over a socket and never
/// opens its database, while three of the facts a correct listing needs live
/// only daemon-side: the durable shadow-peer ledger (the *only* way a shadow is
/// recognised — its record carries no field Claude Code does not define, so
/// there is nothing inside one to look for), each provider's peer-link state,
/// and whether the provider declared the `messages` capability at all.
///
/// **Degrading, never refusing.** Each of the four sources can be missing on
/// its own — no daemon-side bridge, no reconciler yet, an unreadable repo
/// table, an unreadable ledger — and each absence narrows the answer rather
/// than failing the call. A diagnostic that fails hard is useless exactly when it is needed,
/// and the caller's job here is to say what it could not establish.
///
/// Design: `docs/specs/2026-08-29-remote-peer-messaging-design.md`
/// §§ "Reclamation and detection", "Conformance".
extension RPCRouter {
    func handlePeerStatus() async throws -> RPCResponse {
        // Every registered repository's switch, read fresh from the `tbd.toml`
        // in its main checkout — the same read the bridge makes on its tick,
        // so the listing reports what the bridge will act on. Nil, not empty,
        // when the repo table could not be read.
        let repoStatuses = (try? await db.repos.list())?
            .sorted { $0.displayName < $1.displayName }
            .map { repo -> PeerMessagingRepoStatus in
                let setting = PeerMessagingSetting.read(checkoutPath: repo.path)
                return PeerMessagingRepoStatus(
                    repoID: repo.id, repoName: repo.displayName,
                    tomlPath: setting.path, enabled: setting.enabled,
                    problems: setting.problems)
            }

        // Empty when `remote_backends_enabled` was off at boot, so no provider
        // was ever described. `remoteBackendsLive` below is what tells that
        // apart from a fleet that simply has no providers registered.
        var report = PeerBridgeReport()
        if let remoteManager {
            report = await remoteManager.peerBridgeReport()
        }
        let rows = (try? await db.shadowPeerArtifacts.all()) ?? []
        let shadows = rows.map { row -> PeerShadowArtifactRow in
            let live = report.liveShadowsByPID[row.pid]
            return PeerShadowArtifactRow(
                pid: Int32(row.pid),
                provider: row.provider,
                handle: row.handle,
                name: row.name,
                recordSessionID: row.sessionID,
                // Nil when no live link vouches for the row. Deliberately not
                // filled in from anywhere else: the ledger's `sessionID` is the
                // published record's own id and naming it here would report the
                // wrong session under the right label.
                remoteSessionID: live?.remoteSessionID,
                socketPath: row.socketPath,
                recordPath: row.recordPath,
                daemonGeneration: row.daemonGeneration,
                publishedAt: row.publishedAt,
                live: live != nil)
        }

        // Nil until this daemon has actually swept once. Not a zeroed result:
        // "swept, found nothing" and "never swept" are different facts, and
        // only one of them is reassuring.
        var sweep: PeerShadowSweep?
        if let reconciler = shadowPeerReconciler, let last = await reconciler.lastSweep() {
            sweep = PeerShadowSweep(
                at: last.at,
                helpersKilled: last.result.helpersKilled,
                recordsUnlinked: last.result.recordsUnlinked,
                socketsUnlinked: last.result.socketsUnlinked,
                rowsForgotten: last.result.rowsForgotten,
                liveShadowsKept: last.result.liveShadowsKept,
                withinGrace: last.result.withinGrace,
                unvouchedFor: last.result.unvouchedFor,
                foreignArtifactsLeftAlone: last.result.foreignArtifactsLeftAlone,
                deferred: last.result.deferred)
        }

        return try RPCResponse(result: PeerBridgeStatus(
            repos: repoStatuses,
            remoteBackendsLive: remoteManager != nil,
            providers: report.providers,
            shadows: shadows,
            lastSweep: sweep))
    }
}
