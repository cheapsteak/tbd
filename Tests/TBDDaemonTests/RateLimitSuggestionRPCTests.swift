import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The hard-limit handler's profile suggestion (account load balancing §7.1):
/// the notification names a profile with room and the `terminalLimitHit`
/// delta carries it for the app's one-click switch. The handler never swaps
/// the session or arms a `continue` on its own.
@Suite struct RateLimitSuggestionRPCTests {
    let db: TBDDatabase
    let router: RPCRouter
    let clock = TestPollerClock()
    let terminalID: UUID
    let worktreeID: UUID

    init() async throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        let candidateSource = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { id in "\(id.uuidString)@example.com" }
        )
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            profilePoolCandidateSource: candidateSource,
            actuationLog: makeTestActuationLog())
        let repo = try await db.repos.create(
            path: "/tmp/lrr-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/lrr-wt-\(UUID().uuidString)", tmuxServer: "tbd-lrr")
        worktreeID = wt.id
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1")
        terminalID = terminal.id
        // Router-held scheduler, not started (schedule() works without loop).
        router.limitResumeScheduler = LimitResumeScheduler(
            store: db.scheduledResumes, config: db.config,
            actuator: FakeActuator(), clock: clock,
            jitterProvider: { 0 }, onOutcome: { _, _ in })
    }

    // MARK: - Fixture helpers

    private func makeProfile(
        name: String = "Test",
        kind: CredentialKind = .oauth
    ) async throws -> UUID {
        let profile = try await db.modelProfiles.create(
            name: name, kind: kind
        )
        return profile.id
    }

    private func makeSnapshot(
        for profileID: UUID,
        percent: Double = 30.0,
        organizationID: String? = nil
    ) async throws {
        let snapshot = ProfileUsageSnapshot(
            buckets: [
                .init(kind: "session", percent: percent, severity: nil, resetsAt: Date().addingTimeInterval(3600)),
                .init(kind: "weekly_all", percent: percent, severity: nil, resetsAt: Date().addingTimeInterval(86400 * 7)),
            ],
            fetchedAt: Date(),
            lastAttemptAt: Date(),
            status: "ok",
            statusKind: .ok,
            organizationID: organizationID
        )
        try await db.oauthUsageSnapshots.upsert(profileID: profileID, snapshot: snapshot)
    }

    private func setTerminalProfile(_ profileID: UUID?) async throws {
        try await db.terminals.setProfileID(id: terminalID, profileID: profileID)
    }

    private func setTerminalSessionID(_ sessionID: UUID?) async throws {
        if let sessionID = sessionID {
            try await db.terminals.updateSessionID(id: terminalID, sessionID: sessionID.uuidString)
        }
    }

    private func detect(
        limitType: String = "session",
        resetsAt: Date = Date().addingTimeInterval(3600)
    ) async -> RPCResponse {
        let request = try! RPCRequest(
            method: RPCMethod.claudeRateLimitDetected,
            params: RateLimitDetectedParams(
                terminalID: terminalID,
                resetsAt: resetsAt,
                limitType: limitType,
                rawMessage: "You've hit your \(limitType) limit · resets 3pm (UTC)"))
        return await router.handle(request)
    }

    private func seedLimitedAndEligible() async throws -> (limited: UUID, eligible: UUID) {
        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauth)
        let eligibleProfileID = try await makeProfile(name: "Eligible", kind: .oauth)
        try await makeSnapshot(for: limitedProfileID, percent: 90, organizationID: "org-123")
        try await makeSnapshot(for: eligibleProfileID, percent: 30, organizationID: "org-456")
        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())
        return (limitedProfileID, eligibleProfileID)
    }

    /// The `terminalLimitHit` deltas the router broadcast. Broadcast is
    /// synchronous, so everything is recorded by the time `handle` returns.
    private final class LimitHitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [TerminalLimitHitDelta] = []

        init(router: RPCRouter) {
            router.subscriptions.addSubscriber { [weak self] data in
                guard let self else { return false }
                if case .terminalLimitHit(let delta)? = try? JSONDecoder().decode(StateDelta.self, from: data) {
                    self.lock.withLock { self.values.append(delta) }
                }
                return true
            }
        }

        var deltas: [TerminalLimitHitDelta] { lock.withLock { values } }
    }

    // MARK: - The suggestion

    @Test func suggestionIsNamedInTheNotificationAndCarriedByTheDelta() async throws {
        let (limited, eligible) = try await seedLimitedAndEligible()
        let recorder = LimitHitRecorder(router: router)

        let response = await detect()
        #expect(response.success)

        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].message?.contains("Session limit hit on Limited") == true, "got: \(notifs[0].message ?? "nil")")
        #expect(notifs[0].message?.contains("Eligible has room (5h 30%") == true, "got: \(notifs[0].message ?? "nil")")

        let deltas = recorder.deltas
        #expect(deltas.count == 1)
        #expect(deltas.first?.terminalID == terminalID)
        #expect(deltas.first?.profileID == limited)
        #expect(deltas.first?.suggestedProfileID == eligible)
    }

    @Test func suggestionIsOmittedWhenNoCandidateIsEligible() async throws {
        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauth)
        try await makeSnapshot(for: limitedProfileID, percent: 90)
        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())
        let recorder = LimitHitRecorder(router: router)

        let response = await detect()
        #expect(response.success)

        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].message?.contains("has room") == false, "got: \(notifs[0].message ?? "nil")")
        #expect(recorder.deltas.count == 1)
        #expect(recorder.deltas.first?.suggestedProfileID == nil)
    }

    /// An ambient terminal has no profile, so no account is excluded: the
    /// suggestion is the pool's best profile.
    @Test func ambientTerminalGetsASuggestionWithNothingExcluded() async throws {
        let first = try await makeProfile(name: "First", kind: .oauth)
        let second = try await makeProfile(name: "Second", kind: .oauth)
        try await makeSnapshot(for: first, percent: 60, organizationID: "org-1")
        try await makeSnapshot(for: second, percent: 10, organizationID: "org-2")
        try await setTerminalSessionID(UUID())
        let recorder = LimitHitRecorder(router: router)

        _ = await detect()

        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].message?.hasPrefix("Session limit hit — resets") == true, "got: \(notifs[0].message ?? "nil")")
        #expect(notifs[0].message?.contains("Second has room") == true, "got: \(notifs[0].message ?? "nil")")
        #expect(recorder.deltas.first?.profileID == nil)
        #expect(recorder.deltas.first?.suggestedProfileID == second)
    }

    @Test func sameAccountProfilesAreNeverSuggested() async throws {
        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauth)
        let sameAccountProfileID = try await makeProfile(name: "SameAccount", kind: .oauth)
        let differentAccountProfileID = try await makeProfile(name: "Different", kind: .oauth)
        try await makeSnapshot(for: limitedProfileID, percent: 90, organizationID: "org-123")
        try await makeSnapshot(for: sameAccountProfileID, percent: 10, organizationID: "org-123")
        try await makeSnapshot(for: differentAccountProfileID, percent: 30, organizationID: "org-456")
        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())
        let recorder = LimitHitRecorder(router: router)

        _ = await detect()

        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].message?.contains("Different has room") == true, "got: \(notifs[0].message ?? "nil")")
        #expect(recorder.deltas.first?.suggestedProfileID == differentAccountProfileID)
    }

    @Test func deltaCarriesResetsAtAndLimitType() async throws {
        _ = try await seedLimitedAndEligible()
        let recorder = LimitHitRecorder(router: router)
        let resetsAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 7200).rounded())

        _ = await detect(limitType: "weekly_all", resetsAt: resetsAt)

        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].type == .limitReached)
        #expect(recorder.deltas.first?.limitType == "weekly_all")
        #expect(recorder.deltas.first?.resetsAt == resetsAt)
    }

    // MARK: - Nothing switches automatically

    /// Even with balancing on, a hard limit only suggests: the session keeps
    /// its profile, nothing is scheduled, and the notification says the limit
    /// resets rather than that anything switched.
    @Test func aHardLimitNeverSwitchesTheSessionEvenWithBalancingOn() async throws {
        try await db.config.setProfileBalancingEnabled(true)
        try await db.config.setAutoResumeOnLimitReset(false)
        let (limited, eligible) = try await seedLimitedAndEligible()
        let recorder = LimitHitRecorder(router: router)

        let response = await detect()
        #expect(response.success)

        #expect(try await db.terminals.get(id: terminalID)?.profileID == limited)
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) == nil)
        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].message?.contains("switched") == false, "got: \(notifs[0].message ?? "nil")")
        #expect(notifs[0].message?.contains("resets") == true, "got: \(notifs[0].message ?? "nil")")
        #expect(recorder.deltas.first?.suggestedProfileID == eligible)
    }

    // MARK: - The reset-time path is unchanged

    @Test func resetTimePathSchedulesTheResumeAndStillSuggests() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        let (limited, eligible) = try await seedLimitedAndEligible()
        let recorder = LimitHitRecorder(router: router)

        let response = await detect(limitType: "session")
        #expect(response.success)

        let pending = try await db.scheduledResumes.pending(terminalID: terminalID)
        #expect(pending?.limitType == "session")
        #expect(try await db.terminals.get(id: terminalID)?.profileID == limited)
        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].message?.contains("auto-resume scheduled for") == true, "got: \(notifs[0].message ?? "nil")")
        #expect(notifs[0].message?.contains("Eligible has room") == true, "got: \(notifs[0].message ?? "nil")")
        #expect(recorder.deltas.first?.suggestedProfileID == eligible)
    }

    /// A repeat report while a reset-time resume is pending is latched by
    /// `schedule`: no second notification and no second delta.
    @Test func aRepeatReportWithAPendingResetTimeResumeIsLatched() async throws {
        try await db.config.setAutoResumeOnLimitReset(true)
        _ = try await seedLimitedAndEligible()
        _ = await detect()
        let recorder = LimitHitRecorder(router: router)

        let response = await detect()
        #expect(response.success)
        #expect(try await db.notifications.unread(worktreeID: worktreeID).count == 1)
        #expect(recorder.deltas.isEmpty)
    }

    /// A pending transient-error auto-continue belongs to a different feature
    /// and must not swallow a hard-limit report: the notification and the
    /// suggestion still happen, and the api_error row is untouched.
    @Test func aPendingApiErrorRowDoesNotSwallowAHardLimitReport() async throws {
        try await db.config.setAutoResumeOnLimitReset(false)
        _ = try await seedLimitedAndEligible()
        _ = try await db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: terminalID, worktreeID: worktreeID,
            resetsAt: clock.now(), fireAt: clock.now().addingTimeInterval(60),
            limitType: ScheduledResume.apiErrorLimitType, rawMessage: "api error"))

        let response = await detect()
        #expect(response.success)
        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1, "the hard limit must still be reported")
        #expect(notifs[0].message?.contains("Eligible has room") == true, "got: \(notifs[0].message ?? "nil")")
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID)?.limitType == ScheduledResume.apiErrorLimitType)
    }

    // MARK: - Wiring regression

    /// The daemon once built the router without a candidate source, which left
    /// the suggestion unreachable in production while every test — each
    /// wiring its own source — stayed green. The router now defaults the
    /// source from its own stores, so a router constructed without one must
    /// still suggest a profile. A setup-token profile is used because its
    /// credential is read from the snapshot, not from a login file on disk.
    @Test func aRouterConstructedWithoutASourceStillSuggests() async throws {
        let bareRouter = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        #expect(bareRouter.profilePoolCandidateSource != nil,
                "RPCRouter.init must default profilePoolCandidateSource — see Daemon.swift wiring")

        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauthToken)
        let roomyProfileID = try await makeProfile(name: "Roomy", kind: .oauthToken)
        try await makeSnapshot(for: limitedProfileID, percent: 90, organizationID: "org-limited")
        try await makeSnapshot(for: roomyProfileID, percent: 20, organizationID: "org-roomy")
        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())

        let response = await bareRouter.handle(try RPCRequest(
            method: RPCMethod.claudeRateLimitDetected,
            params: RateLimitDetectedParams(
                terminalID: terminalID,
                resetsAt: Date().addingTimeInterval(3600),
                limitType: "session",
                rawMessage: "You've hit your session limit · resets 3pm (UTC)")))
        #expect(response.success)

        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].message?.contains("Roomy has room") == true,
                "got: \(notifs[0].message ?? "nil")")
    }
}
