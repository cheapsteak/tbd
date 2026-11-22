import DaemonTestSupport
import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Records every `StateDelta` the router broadcasts.
private final class CapturedDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.withLock { deltas.append(delta) }
    }

    var all: [StateDelta] { lock.withLock { deltas } }

    /// The registry-filter deltas, in order.
    var filterChanges: [RepoRegistryRemoteHiddenDelta] {
        all.compactMap {
            if case .repoRegistryRemoteHiddenChanged(let delta) = $0 { return delta }
            return nil
        }
    }
}

/// Tier 1. The per-repo registry-provider filter the Mac sidebar and the
/// phone share: the `repo.registry_remote_hidden` column, its three states,
/// and the socket RPC that writes it.
/// Spec: docs/specs/2026-11-22-phone-remote-session-filter-design.md.
@Suite("Repo registry remote filter")
struct RepoRegistryRemoteHiddenTests {
    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)
    /// The last migration before the column's.
    private static let beforeTheColumn = "20261120232500_terminal_tmux_session_index"

    // MARK: - Schema

    /// The column is nullable and has no SQL default, so a row nobody chose
    /// for stays NULL rather than reading as a deliberate off.
    @Test func theColumnIsNullableWithNoDefault() async throws {
        let db = try TBDDatabase(inMemory: true)
        let column = try await db.writerForTests.read { conn -> (notNull: Int, defaultValue: String?)? in
            guard let row = try Row.fetchAll(conn, sql: "PRAGMA table_info(repo)")
                .first(where: { ($0["name"] as String?) == "registry_remote_hidden" }) else { return nil }
            let notNull: Int = row["notnull"]
            let defaultValue: String? = row["dflt_value"]
            return (notNull: notNull, defaultValue: defaultValue)
        }
        let found = try #require(column, "repo has no registry_remote_hidden column")
        #expect(found.notNull == 0)
        #expect(found.defaultValue == nil)
    }

    /// A row written before the column reads NULL, not 0, both as stored and
    /// through the model.
    @Test func aPreMigrationRowReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.beforeTheColumn)

        let repoID = "33333333-3333-3333-3333-333333333333"
        try queue.write { conn in
            try conn.execute(sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/rrh-pre-repo', 'acme', 'main', ?)
                """, arguments: [repoID, epoch])
        }

        try migrator.migrate(queue)

        let isNull: Bool? = try queue.read { conn in
            try Bool.fetchOne(
                conn, sql: "SELECT registry_remote_hidden IS NULL FROM repo WHERE id = ?", arguments: [repoID])
        }
        #expect(isNull == true)
        let record = try queue.read { conn in try RepoRecord.fetchOne(conn, key: repoID) }
        let model = try #require(record?.toModel())
        #expect(model.registryRemoteHidden == nil)
    }

    // MARK: - The store

    @Test func aNewRepoHasNotChosen() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/rrh-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        #expect(repo.registryRemoteHidden == nil)
        #expect(try await db.repos.get(id: repo.id)?.registryRemoteHidden == nil)
    }

    /// On then off reads `true` then `false`, and off is stored as 0, a
    /// choice, never back as NULL.
    @Test func settingOnThenOffReadsBothChoices() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/rrh-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")

        try await db.repos.setRegistryRemoteHidden(id: repo.id, hidden: true)
        #expect(try await db.repos.get(id: repo.id)?.registryRemoteHidden == true)

        try await db.repos.setRegistryRemoteHidden(id: repo.id, hidden: false)
        #expect(try await db.repos.get(id: repo.id)?.registryRemoteHidden == false)
        let stored: Int? = try await db.writerForTests.read { conn in
            try Int.fetchOne(
                conn, sql: "SELECT registry_remote_hidden FROM repo WHERE id = ?", arguments: [repo.id.uuidString])
        }
        #expect(stored == 0)
    }

    /// A record update for another field, as a rename makes, keeps the value.
    @Test func aRenameKeepsTheChoice() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/rrh-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        try await db.repos.setRegistryRemoteHidden(id: repo.id, hidden: true)

        try await db.repos.rename(id: repo.id, displayName: "acme-renamed")

        #expect(try await db.repos.get(id: repo.id)?.registryRemoteHidden == true)
    }

    // MARK: - The wire

    /// An older daemon sends no field, which decodes as nobody having chosen;
    /// nil encodes no key; each choice survives a round trip.
    @Test func theModelCarriesThreeStates() throws {
        let json = """
        {"id":"44444444-4444-4444-4444-444444444444","path":"/tmp/x","displayName":"X",
         "defaultBranch":"main","createdAt":0,"status":"ok","hidden":false,"expanded":true}
        """
        let old = try JSONDecoder().decode(Repo.self, from: Data(json.utf8))
        #expect(old.registryRemoteHidden == nil)

        let unset = Repo(path: "/tmp/acme", displayName: "acme")
        let unsetJSON = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(unset)) as? [String: Any])
        #expect(unsetJSON["registryRemoteHidden"] == nil)

        for choice in [true, false] {
            let repo = Repo(path: "/tmp/acme", displayName: "acme", registryRemoteHidden: choice)
            let decoded = try JSONDecoder().decode(Repo.self, from: JSONEncoder().encode(repo))
            #expect(decoded.registryRemoteHidden == choice)
        }
    }

    // MARK: - The RPC

    private func makeRouter(db: TBDDatabase) -> (router: RPCRouter, deltas: CapturedDeltas) {
        let deltas = CapturedDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), hooks: HookResolver(), subscriptions: subs, leftoverTmuxProbe: .absent)
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, subscriptions: subs, actuationLog: makeTestActuationLog())
        return (router, deltas)
    }

    /// The RPC writes 1, then 0, and broadcasts one delta per write, each
    /// carrying the value written.
    @Test func theRPCWritesTheChoiceAndBroadcastsOneDelta() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let repo = try await db.repos.create(
            path: "/tmp/rrh-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")

        let on = await router.handle(try RPCRequest(
            method: RPCMethod.repoSetRegistryRemoteHidden,
            params: RepoSetRegistryRemoteHiddenParams(repoID: repo.id, hidden: true)))
        #expect(on.success)
        #expect(try await db.repos.get(id: repo.id)?.registryRemoteHidden == true)
        #expect(deltas.filterChanges == [RepoRegistryRemoteHiddenDelta(repoID: repo.id, hidden: true)])

        let off = await router.handle(try RPCRequest(
            method: RPCMethod.repoSetRegistryRemoteHidden,
            params: RepoSetRegistryRemoteHiddenParams(repoID: repo.id, hidden: false)))
        #expect(off.success)
        #expect(try await db.repos.get(id: repo.id)?.registryRemoteHidden == false)
        #expect(deltas.filterChanges == [
            RepoRegistryRemoteHiddenDelta(repoID: repo.id, hidden: true),
            RepoRegistryRemoteHiddenDelta(repoID: repo.id, hidden: false),
        ])
        #expect(deltas.all.count == 2, "the RPC broadcast something besides its own delta")
    }

    /// An unknown repo is an error, and nothing is broadcast.
    @Test func theRPCRefusesAnUnknownRepo() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.repoSetRegistryRemoteHidden,
            params: RepoSetRegistryRemoteHiddenParams(repoID: UUID(), hidden: true)))

        #expect(!response.success)
        #expect(response.error?.contains("Repository not found") == true)
        #expect(deltas.all.isEmpty)
    }

    /// The delta round-trips under the name the app and the phone publisher
    /// read.
    @Test func theDeltaRoundTrips() throws {
        let repoID = UUID()
        let data = try JSONEncoder().encode(StateDelta.repoRegistryRemoteHiddenChanged(
            RepoRegistryRemoteHiddenDelta(repoID: repoID, hidden: true)))
        let decoded = try JSONDecoder().decode(StateDelta.self, from: data)
        guard case .repoRegistryRemoteHiddenChanged(let delta) = decoded else {
            Issue.record("decoded \(decoded), not a registry filter delta")
            return
        }
        #expect(delta == RepoRegistryRemoteHiddenDelta(repoID: repoID, hidden: true))
    }
}
