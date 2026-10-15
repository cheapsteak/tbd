import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// What `Daemon.makePeerBridging` composes, driven over a real `tbd.toml` in a
/// temp checkout and an in-memory database: the stream gate (`isEnabled`), the
/// outward scope and the inward site resolver — the same factories the
/// wiring's `make` builds a bridge from. Each half of the per-repository switch
/// is asserted through production composition, so a factory that forgot the
/// switch (an always-on `peerMessagingOn`, a scope with no switch read) goes
/// red here even though every component's own tests still pass.
///
/// Tier 2: a real filesystem under the process temp directory; never `~/tbd`.
/// Nothing is started, so no provider child and no helper is spawned.
@Suite("Peer bridge composition")
struct PeerBridgeCompositionTests {

    private struct Fixture {
        let db: TBDDatabase
        let checkout: URL
        let repo: Repo
        let wiring: PeerBridgeWiring
        let switches: RepoPeerMessagingSwitches

        func setSwitch(_ text: String?) throws {
            let toml = checkout.appendingPathComponent("tbd.toml")
            if let text {
                try text.write(to: toml, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: toml)
            }
        }
    }

    private static let provider = RemoteProviderConfig(name: "cloud", exec: "/bin/true")

    private static func makeFixture() async throws -> Fixture {
        let checkout = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-compose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: checkout.path, displayName: "acme", defaultBranch: "main")
        _ = try await db.worktrees.createRemote(
            repoID: repo.id, name: "api-lane", displayName: "api-lane",
            branch: "tbd/api-lane", provider: provider.name, sessionID: "sess-1")
        let sessions = checkout.appendingPathComponent("sessions", isDirectory: true)
        let wiring = Daemon.makePeerBridging(
            database: db,
            roster: PeerRosterRunner(roster: RosterWatcher(
                sessionsDirectory: sessions,
                sessions: DatabaseLocalSessionDirectory(worktrees: db.worktrees, terminals: db.terminals),
                origin: "laptop",
                interval: .seconds(3600))),
            bridges: ShadowPeerBridgeRegistry(),
            sessionsDirectory: sessions,
            origin: "laptop")
        return Fixture(
            db: db, checkout: checkout, repo: repo, wiring: wiring,
            switches: Daemon.makePeerMessagingSwitches(database: db))
    }

    @Test func everyPieceFollowsTheRepositorysTomlBothWays() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.checkout) }
        let scope = Daemon.makeRepoScope(
            provider: Self.provider.name, database: fixture.db, switches: fixture.switches)
        let resolver = Daemon.makeShadowSiteResolver(
            provider: Self.provider.name, database: fixture.db, switches: fixture.switches)

        // No tbd.toml: off everywhere.
        #expect(await fixture.wiring.isEnabled(Self.provider) == false)
        #expect(await scope.resolve() == Set<UUID>())
        #expect(await resolver.resolution(forProviderSessionID: "sess-1") == .switchedOff)

        try fixture.setSwitch("[remote_sessions]\npeer_messaging = true\n")
        #expect(await fixture.wiring.isEnabled(Self.provider))
        let on: Set<UUID> = [fixture.repo.id]
        #expect(await scope.resolve() == on)
        #expect(await resolver.resolution(forProviderSessionID: "sess-1") == .sited(
            ShadowPeerSite(
                worktreeDisplayName: "api-lane", path: fixture.checkout.path,
                repoID: fixture.repo.id)))

        // An explicit false, read fresh with no restart.
        try fixture.setSwitch("[remote_sessions]\npeer_messaging = false\n")
        #expect(await fixture.wiring.isEnabled(Self.provider) == false)
        #expect(await scope.resolve() == Set<UUID>())
        #expect(await resolver.resolution(forProviderSessionID: "sess-1") == .switchedOff)
    }

    /// Another provider's lanes do not open this provider's stream.
    @Test func theGateIsPerProvider() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.checkout) }
        try fixture.setSwitch("[remote_sessions]\npeer_messaging = true\n")

        #expect(await fixture.wiring.isEnabled(
            RemoteProviderConfig(name: "other", exec: "/bin/true")) == false)
    }
}
