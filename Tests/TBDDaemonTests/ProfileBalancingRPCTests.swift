import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The RPC surface and data model for account load balancing (design 2026-09-05):
/// - Profile balancing flag (spread new sessions across available accounts)
/// - Limit rotation flag (resume on another account when hitting a limit)
/// - Pool opt-out per profile (exclude from automatic balancing)
/// - Live session counts per profile (the load signal for the policy)
@Suite("Profile balancing RPC")
struct ProfileBalancingRPCTests {

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

    private func setProfileBalancing(_ router: RPCRouter, enabled: Bool) async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetProfileBalancingEnabled,
            params: ConfigSetProfileBalancingEnabledParams(enabled: enabled))
        let response = await router.handle(request)
        #expect(response.success, "\(String(describing: response.error))")
    }

    private func setLimitRotation(_ router: RPCRouter, enabled: Bool) async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetLimitRotationEnabled,
            params: ConfigSetLimitRotationEnabledParams(enabled: enabled))
        let response = await router.handle(request)
        #expect(response.success, "\(String(describing: response.error))")
    }

    private func setPoolOptOut(_ router: RPCRouter, profileID: UUID, optOut: Bool) async throws {
        let request = try RPCRequest(
            method: RPCMethod.modelProfileSetPoolOptOut,
            params: ModelProfileSetPoolOptOutParams(id: profileID, optOut: optOut))
        let response = await router.handle(request)
        #expect(response.success, "\(String(describing: response.error))")
    }

    // MARK: - Wire names

    @Test("config.setProfileBalancingEnabled method name")
    func profileBalancingMethodName() {
        #expect(RPCMethod.configSetProfileBalancingEnabled == "config.setProfileBalancingEnabled")
    }

    @Test("config.setLimitRotationEnabled method name")
    func limitRotationMethodName() {
        #expect(RPCMethod.configSetLimitRotationEnabled == "config.setLimitRotationEnabled")
    }

    @Test("modelProfile.setPoolOptOut method name")
    func poolOptOutMethodName() {
        #expect(RPCMethod.modelProfileSetPoolOptOut == "modelProfile.setPoolOptOut")
    }

    // MARK: - Initial state

    @Test("profile balancing is off before any call")
    func profileBalancingOffBeforeAnyCall() async throws {
        let (_, db) = try makeRouterAndDB()
        #expect(try await db.config.get().profileBalancingEnabled == false)
    }

    @Test("limit rotation is off before any call")
    func limitRotationOffBeforeAnyCall() async throws {
        let (_, db) = try makeRouterAndDB()
        #expect(try await db.config.get().limitRotationEnabled == false)
    }

    // MARK: - Round trip: flags

    @Test("profile balancing round-trips")
    func profileBalancingRoundTrip() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setProfileBalancing(router, enabled: true)
        #expect(try await db.config.get().profileBalancingEnabled == true)
        try await setProfileBalancing(router, enabled: false)
        #expect(try await db.config.get().profileBalancingEnabled == false)
    }

    @Test("limit rotation round-trips")
    func limitRotationRoundTrip() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setLimitRotation(router, enabled: true)
        #expect(try await db.config.get().limitRotationEnabled == true)
        try await setLimitRotation(router, enabled: false)
        #expect(try await db.config.get().limitRotationEnabled == false)
    }

    // MARK: - Explicit 0 vs NULL

    @Test("profile balancing stores explicit false, not NULL")
    func profileBalancingExplicitFalse() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setProfileBalancing(router, enabled: false)
        let stored = try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)?
                .profile_balancing_enabled
        }
        #expect(stored == false)
    }

    @Test("limit rotation stores explicit false, not NULL")
    func limitRotationExplicitFalse() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setLimitRotation(router, enabled: false)
        let stored = try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)?
                .limit_rotation_enabled
        }
        #expect(stored == false)
    }

    @Test("pool opt-out stores explicit 0 when clearing")
    func poolOptOutExplicitFalse() async throws {
        let (router, db) = try makeRouterAndDB()
        let profile = try await db.modelProfiles.create(name: "test", kind: .oauth)
        try await setPoolOptOut(router, profileID: profile.id, optOut: false)
        let stored = try await db.writerForTests.read { conn in
            try ModelProfileRecord.fetchOne(conn, key: profile.id.uuidString)?
                .pool_opt_out
        }
        #expect(stored == false)
    }

    // MARK: - Pool opt-out

    @Test("pool opt-out round-trips include/exclude")
    func poolOptOutRoundTrip() async throws {
        let (router, db) = try makeRouterAndDB()
        let profile = try await db.modelProfiles.create(name: "test", kind: .oauth)
        try await setPoolOptOut(router, profileID: profile.id, optOut: true)
        let excluded = try await db.modelProfiles.get(id: profile.id)
        #expect(excluded?.poolOptOut == true)
        try await setPoolOptOut(router, profileID: profile.id, optOut: false)
        let included = try await db.modelProfiles.get(id: profile.id)
        #expect(included?.poolOptOut == false)
    }

    // MARK: - Live session counts

    @Test("liveSessionCountsByProfile returns counts by profile")
    func liveSessionCounts() async throws {
        let (router, db) = try makeRouterAndDB()
        let profileA = try await db.modelProfiles.create(name: "profileA", kind: .oauth)
        let profileB = try await db.modelProfiles.create(name: "profileB", kind: .oauth)

        let worktree = try await db.worktrees.createScratch(
            name: "test",
            displayName: "test",
            path: "/tmp/worktree",
            tmuxServer: "@test"
        )

        // Two live Claude sessions on profile A
        let terminalA1 = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            profileID: profileA.id,
            kind: .claude
        )
        let terminalA2 = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@2",
            tmuxPaneID: "%2",
            profileID: profileA.id,
            kind: .claude
        )

        // One live Claude session on profile B
        let terminalB = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@3",
            tmuxPaneID: "%3",
            profileID: profileB.id,
            kind: .claude
        )

        // One hibernated session on A (should not count as live)
        let terminalA3 = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@4",
            tmuxPaneID: "%4",
            profileID: profileA.id,
            kind: .claude
        )
        try await db.terminals.setHibernated(
            id: terminalA3.id, sessionID: "session-4", reason: .auto)

        // One non-Claude kind on A (should not count)
        _ = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@5",
            tmuxPaneID: "%5",
            profileID: profileA.id,
            kind: .shell
        )

        let counts = try await db.terminals.liveSessionCountsByProfile()
        #expect(counts[profileA.id] == 2, "profile A should have 2 live Claude sessions")
        #expect(counts[profileB.id] == 1, "profile B should have 1 live Claude session")
    }

    // MARK: - List and capabilities

    @Test("modelProfile.list includes liveSessions and balancing flags")
    func modelProfileListIncludesLiveSessionsAndFlags() async throws {
        let (router, db) = try makeRouterAndDB()
        let profileA = try await db.modelProfiles.create(name: "profileA", kind: .oauth)
        let worktree = try await db.worktrees.createScratch(
            name: "test",
            displayName: "test",
            path: "/tmp/worktree",
            tmuxServer: "@test"
        )
        _ = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            profileID: profileA.id,
            kind: .claude
        )

        try await setProfileBalancing(router, enabled: true)
        try await setLimitRotation(router, enabled: true)

        let request = try RPCRequest(method: RPCMethod.modelProfileList)
        let response = await router.handle(request)
        let result = try #require(
            response.result.flatMap { try JSONDecoder().decode(
                ModelProfileListResult.self, from: Data($0.utf8)) }
        )

        #expect(result.profileBalancingEnabled == true)
        #expect(result.limitRotationEnabled == true)
        let profile = try #require(result.profiles.first)
        #expect(profile.liveSessions == 1)
    }

    @Test("daemon.capabilities includes balancing and rotation flags")
    func daemonCapabilitiesIncludesFlags() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setProfileBalancing(router, enabled: true)

        let request = try RPCRequest(method: RPCMethod.daemonCapabilities)
        let response = await router.handle(request)
        let capabilities = try #require(
            response.result.flatMap { try JSONDecoder().decode(
                DaemonCapabilitiesResult.self, from: Data($0.utf8)) }
        )

        #expect(capabilities.profileBalancingEnabled == true)
        #expect(capabilities.limitRotationEnabled == false)
    }
}
