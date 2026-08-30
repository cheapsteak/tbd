import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `config.setRemotePeerMessagingEnabled` — the write half of the remote
/// peer-messaging gate (`docs/specs/2026-08-29-remote-peer-messaging-design.md`,
/// "Flag and rollout").
///
/// The column's three states, and the store setter behind this method, are
/// guarded by `RemotePeerMessagingFlagSchemaTests`. What is asserted here is the
/// part that made the flag unusable without it: that a gesture arriving over the
/// socket reaches that setter at all, and that the read half every user consults
/// — `config.get` and `peer.status` — reports the value the gesture wrote.
@Suite("Remote peer messaging RPC")
struct RemotePeerMessagingRPCTests {

    private func makeRouterAndDB() throws -> (RPCRouter, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
        return (router, db)
    }

    private func setMessaging(_ router: RPCRouter, enabled: Bool) async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetRemotePeerMessagingEnabled,
            params: ConfigSetRemotePeerMessagingEnabledParams(enabled: enabled))
        let response = await router.handle(request)
        #expect(response.success)
    }

    // MARK: - The gesture reaches the store

    @Test("config.setRemotePeerMessagingEnabled persists the flag to true")
    func setEnabledPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setMessaging(router, enabled: true)
        #expect(try await db.config.get().remotePeerMessagingEnabled == true)
    }

    /// The off direction is not the same code path by construction — a handler
    /// that ignored its params would pass the test above and fail this one.
    @Test("config.setRemotePeerMessagingEnabled persists the flag to false")
    func setDisabledPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setMessaging(router, enabled: true)
        try await setMessaging(router, enabled: false)
        #expect(try await db.config.get().remotePeerMessagingEnabled == false)
    }

    /// Writing `false` over a never-chosen row is still an explicit gesture: it
    /// must leave `0` behind, not NULL, so the opt-out survives graduation of
    /// `Config.remotePeerMessagingDefault`.
    @Test("setting it off from the unchosen state records an explicit opt-out")
    func settingOffFromUnchosenRecordsAnExplicitChoice() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setMessaging(router, enabled: false)
        let record = try #require(try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        })
        #expect(record.remote_peer_messaging_enabled == false)
        #expect(
            record.toModel(remotePeerMessagingDefault: true)
                .remotePeerMessagingEnabled == false,
            "an opt-out made over RPC must outlive a change to the shipped default")
    }

    // MARK: - What the read half reports afterwards

    /// `tbd peer list` reads the gate from `config.get`, and `peer.status`
    /// resolves it fresh per call. Both must report the value just written —
    /// this is the loop that told a user nothing had changed while the write
    /// path did not exist at all.
    @Test("config.get and peer.status report the value the gesture wrote")
    func readHalfFollowsTheGesture() async throws {
        let (router, _) = try makeRouterAndDB()

        var status = try await router.handle(RPCRequest(method: RPCMethod.peerStatus))
            .decodeResult(PeerBridgeStatus.self)
        #expect(status.messagingEnabled == Config.remotePeerMessagingDefault)

        try await setMessaging(router, enabled: true)
        var config = try await router.handle(RPCRequest(method: RPCMethod.configGet))
            .decodeResult(Config.self)
        status = try await router.handle(RPCRequest(method: RPCMethod.peerStatus))
            .decodeResult(PeerBridgeStatus.self)
        #expect(config.remotePeerMessagingEnabled == true)
        #expect(status.messagingEnabled == true)

        try await setMessaging(router, enabled: false)
        config = try await router.handle(RPCRequest(method: RPCMethod.configGet))
            .decodeResult(Config.self)
        status = try await router.handle(RPCRequest(method: RPCMethod.peerStatus))
            .decodeResult(PeerBridgeStatus.self)
        #expect(config.remotePeerMessagingEnabled == false)
        #expect(status.messagingEnabled == false)
    }

    /// The method name is the wire contract the CLI types: a rename that misses
    /// one side leaves the flag unreachable again, silently.
    @Test("the method name is the one the CLI calls")
    func methodNameIsPinned() {
        #expect(
            RPCMethod.configSetRemotePeerMessagingEnabled
                == "config.setRemotePeerMessagingEnabled")
    }
}
