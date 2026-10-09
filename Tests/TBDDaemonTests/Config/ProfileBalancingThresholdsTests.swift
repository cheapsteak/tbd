import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Schema, resolution and RPC guards for balancing's two thresholds,
/// `config.profile_balancing_usage_ceiling_percent` and
/// `config.profile_balancing_max_reading_age_seconds` (design 2026-09-05 §5).
///
/// Both columns are added with **no SQL default**: NULL means "never set" and
/// resolves through `ProfilePoolPolicy`, so the shipped thresholds live in one
/// place and a later change to them reaches every install that never chose.
@Suite("ProfileBalancingThresholds")
struct ProfileBalancingThresholdsTests {

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

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

    private func call<P: Encodable>(_ router: RPCRouter, _ method: String, _ params: P) async throws -> RPCResponse {
        await router.handle(try RPCRequest(method: method, params: params))
    }

    // MARK: - Storage and resolution

    @Test func bothColumnsAreNullBeforeAnyGestureAndResolveToTheShippedPolicy() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.profile_balancing_usage_ceiling_percent == nil,
                "profile_balancing_usage_ceiling_percent grew a DEFAULT clause; remove it.")
        #expect(record.profile_balancing_max_reading_age_seconds == nil,
                "profile_balancing_max_reading_age_seconds grew a DEFAULT clause; remove it.")
        #expect(try await db.config.get().profileBalancingPolicy == .standard)
    }

    @Test func settersRoundTripAndNilRestoresNull() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setProfileBalancingUsageCeilingPercent(90)
        try await db.config.setProfileBalancingMaxReadingAgeSeconds(1800)
        #expect(try await db.config.get().profileBalancingPolicy
            == ProfilePoolPolicy(usageCeilingPercent: 90, maxReadingAgeSeconds: 1800))

        try await db.config.setProfileBalancingUsageCeilingPercent(nil)
        try await db.config.setProfileBalancingMaxReadingAgeSeconds(nil)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(record.profile_balancing_usage_ceiling_percent == nil)
        #expect(record.profile_balancing_max_reading_age_seconds == nil)
        #expect(try await db.config.get().profileBalancingPolicy == .standard)
    }

    /// A hand-edited row can hold what the setters refuse; it must not become
    /// a ceiling of 0% (everything full) or a reading age of zero (everything
    /// stale).
    @Test func outOfRangeStoredValuesResolveToTheShippedPolicy() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: """
                    UPDATE config SET profile_balancing_usage_ceiling_percent = 0,
                                      profile_balancing_max_reading_age_seconds = 5
                    WHERE id = ?
                    """,
                arguments: [ConfigStore.singletonID])
        }
        #expect(try await db.config.get().profileBalancingPolicy == .standard)
    }

    @Test func configJSONCarriesTheStoredValuesAndOmitsUnsetOnes() throws {
        var config = Config()
        config.profileBalancingUsageCeilingPercent = 70
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.profileBalancingUsageCeilingPercent == 70)
        #expect(decoded.profileBalancingMaxReadingAgeSeconds == nil)
        #expect(decoded.profileBalancingPolicy.usageCeilingPercent == 70)
    }

    // MARK: - RPC

    @Test func wireNames() {
        #expect(RPCMethod.configSetProfileBalancingUsageCeiling == "config.setProfileBalancingUsageCeiling")
        #expect(RPCMethod.configSetProfileBalancingMaxReadingAge == "config.setProfileBalancingMaxReadingAge")
    }

    @Test func rpcSetsAndResetsBothThresholds() async throws {
        let (router, db) = try makeRouterAndDB()

        #expect(try await call(router, RPCMethod.configSetProfileBalancingUsageCeiling,
                               ConfigSetBalancingUsageCeilingParams(percent: 92)).success)
        #expect(try await call(router, RPCMethod.configSetProfileBalancingMaxReadingAge,
                               ConfigSetBalancingMaxReadingAgeParams(seconds: 600)).success)
        #expect(try await db.config.get().profileBalancingPolicy
            == ProfilePoolPolicy(usageCeilingPercent: 92, maxReadingAgeSeconds: 600))

        #expect(try await call(router, RPCMethod.configSetProfileBalancingUsageCeiling,
                               ConfigSetBalancingUsageCeilingParams(percent: nil)).success)
        #expect(try await call(router, RPCMethod.configSetProfileBalancingMaxReadingAge,
                               ConfigSetBalancingMaxReadingAgeParams(seconds: nil)).success)
        #expect(try await db.config.get().profileBalancingPolicy == .standard)
    }

    /// Refused, not clamped: a typo should say so rather than quietly become
    /// some other threshold. Nothing is written.
    @Test(arguments: [0, 101, -5])
    func rpcRefusesAnOutOfRangeCeiling(percent: Int) async throws {
        let (router, db) = try makeRouterAndDB()
        let response = try await call(router, RPCMethod.configSetProfileBalancingUsageCeiling,
                                      ConfigSetBalancingUsageCeilingParams(percent: percent))
        #expect(!response.success)
        #expect(response.error?.contains("between 1 and 100") == true)
        #expect(try #require(try await fetchConfigRecord(db)).profile_balancing_usage_ceiling_percent == nil)
    }

    @Test(arguments: [0, 59, 86_401])
    func rpcRefusesAnOutOfRangeReadingAge(seconds: Int) async throws {
        let (router, db) = try makeRouterAndDB()
        let response = try await call(router, RPCMethod.configSetProfileBalancingMaxReadingAge,
                                      ConfigSetBalancingMaxReadingAgeParams(seconds: seconds))
        #expect(!response.success)
        #expect(try #require(try await fetchConfigRecord(db)).profile_balancing_max_reading_age_seconds == nil)
    }

    @Test func capabilitiesAndTheProfileListCarryTheThresholds() async throws {
        let (router, db) = try makeRouterAndDB()
        try await db.config.setProfileBalancingUsageCeilingPercent(75)
        try await db.config.setProfileBalancingMaxReadingAgeSeconds(1200)

        let capabilitiesResponse = await router.handle(try RPCRequest(method: RPCMethod.daemonCapabilities))
        let capabilities = try #require(capabilitiesResponse.result.flatMap {
            try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: Data($0.utf8))
        })
        #expect(capabilities.profileBalancingPolicy
            == ProfilePoolPolicy(usageCeilingPercent: 75, maxReadingAgeSeconds: 1200))

        let listResponse = await router.handle(try RPCRequest(method: RPCMethod.modelProfileList))
        let list = try #require(listResponse.result.flatMap {
            try JSONDecoder().decode(ModelProfileListResult.self, from: Data($0.utf8))
        })
        #expect(list.profileBalancingPolicy
            == ProfilePoolPolicy(usageCeilingPercent: 75, maxReadingAgeSeconds: 1200))
    }

    /// An older daemon sends neither field; the app and CLI then apply the
    /// shipped thresholds rather than something stricter or looser.
    @Test func resultsFromAnOlderDaemonResolveToTheShippedPolicy() throws {
        let capabilities = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(#"{"controlModeEnabled":false}"#.utf8))
        #expect(capabilities.profileBalancingPolicy == .standard)
        let list = try JSONDecoder().decode(
            ModelProfileListResult.self, from: Data(#"{"profiles":[]}"#.utf8))
        #expect(list.profileBalancingPolicy == .standard)
    }
}
