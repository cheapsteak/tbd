import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TestSupport

/// `peer.status`'s report of each repository's peer-messaging switch — the read
/// half `tbd peer list` prints (`docs/specs/2026-08-29-remote-peer-messaging-design.md`,
/// "The per-repository switch").
///
/// The switch lives in each repository's committed `tbd.toml`, so these tests
/// write real files into a temp checkout and assert the daemon reads them fresh
/// on every call. Tier 2: a real filesystem under a temp dir, never `~/tbd`.
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

    private func makeCheckout() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func status(_ router: RPCRouter) async throws -> PeerBridgeStatus {
        try await router.handle(RPCRequest(method: RPCMethod.peerStatus))
            .decodeResult(PeerBridgeStatus.self)
    }

    /// Each repository is reported with the state its own `tbd.toml` gives it,
    /// and the file is re-read on every call: editing it changes the very next
    /// answer, with no restart.
    @Test("peer.status reports each repository's switch, read fresh")
    func reportsEachRepositorysSwitchFresh() async throws {
        let (router, db) = try makeRouterAndDB()
        let onCheckout = try makeCheckout()
        let offCheckout = try makeCheckout()
        defer {
            try? FileManager.default.removeItem(at: onCheckout)
            try? FileManager.default.removeItem(at: offCheckout)
        }
        let toml = onCheckout.appendingPathComponent("tbd.toml")
        try "[remote_sessions]\npeer_messaging = true\n"
            .write(to: toml, atomically: true, encoding: .utf8)
        _ = try await db.repos.create(
            path: onCheckout.path, displayName: "acme-on", defaultBranch: "main")
        _ = try await db.repos.create(
            path: offCheckout.path, displayName: "acme-off", defaultBranch: "main")

        var repos = try #require(try await status(router).repos)
        #expect(repos.map(\.repoName) == ["acme-off", "acme-on"])
        #expect(repos.map(\.enabled) == [false, true])
        #expect(repos.allSatisfy { $0.problems.isEmpty })
        #expect(repos[1].tomlPath == toml.path)

        try "[remote_sessions]\npeer_messaging = false\n"
            .write(to: toml, atomically: true, encoding: .utf8)
        repos = try #require(try await status(router).repos)
        #expect(repos.map(\.enabled) == [false, false])
    }

    /// A value TBD cannot understand is off, and the problem travels to the
    /// listing with the file's path.
    @Test("peer.status carries a tbd.toml problem with its path")
    func carriesProblems() async throws {
        let (router, db) = try makeRouterAndDB()
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(at: checkout) }
        try "[remote_sessions]\npeer_messaging = \"yes\"\n"
            .write(to: checkout.appendingPathComponent("tbd.toml"),
                   atomically: true, encoding: .utf8)
        _ = try await db.repos.create(
            path: checkout.path, displayName: "acme", defaultBranch: "main")

        let repo = try #require(try await status(router).repos?.first)
        #expect(repo.enabled == false)
        #expect(repo.problems.count == 1)
        #expect(repo.tomlPath.hasSuffix("/tbd.toml"))
    }

    /// An older `tbd` CLI decodes `peer.status` with `messagingEnabled`
    /// required, and the installed CLI often lags the daemon. The daemon keeps
    /// emitting it — true when any repository is on — so that CLI still reads
    /// the answer instead of failing to decode it.
    @Test("peer.status still emits messagingEnabled for older CLIs")
    func emitsTheCompatField() async throws {
        struct OlderCLIStatus: Decodable { let messagingEnabled: Bool }
        let (router, db) = try makeRouterAndDB()
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(at: checkout) }
        _ = try await db.repos.create(
            path: checkout.path, displayName: "acme", defaultBranch: "main")

        var older = try await router.handle(RPCRequest(method: RPCMethod.peerStatus))
            .decodeResult(OlderCLIStatus.self)
        #expect(older.messagingEnabled == false)

        try "[remote_sessions]\npeer_messaging = true\n"
            .write(to: checkout.appendingPathComponent("tbd.toml"),
                   atomically: true, encoding: .utf8)
        older = try await router.handle(RPCRequest(method: RPCMethod.peerStatus))
            .decodeResult(OlderCLIStatus.self)
        #expect(older.messagingEnabled == true)
    }

    /// The machine-wide switch is gone, and so is the method that moved it: a
    /// caller that still sends it is told the method does not exist rather
    /// than having it silently succeed.
    @Test("the machine-wide setter no longer exists")
    func machineWideSetterIsGone() async throws {
        let (router, _) = try makeRouterAndDB()
        let response = await router.handle(
            RPCRequest(method: "config.setRemotePeerMessagingEnabled"))
        #expect(response.success == false)
    }
}
