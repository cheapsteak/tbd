import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

@Suite struct RateLimitRotationRPCTests {
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

    private func setTerminalParked() async throws {
        try await db.terminals.setHibernated(id: terminalID, sessionID: "test-session", reason: .auto)
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

    // MARK: - Ungated tests (§7.1)

    @Test func ungatedBroadcastsDeltaWithSuggestionWhenEligible() async throws {
        try await db.config.setLimitRotationEnabled(false)

        // Setup: limited profile + one eligible profile
        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauth)
        let eligibleProfileID = try await makeProfile(name: "Eligible", kind: .oauth)
        try await makeSnapshot(for: limitedProfileID, percent: 90)
        try await makeSnapshot(for: eligibleProfileID, percent: 30)

        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())

        // Setup candidate source with the picker
        let response = await detect()
        #expect(response.success)

        // Check that delta was broadcast with suggestion
        let deltas = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(deltas.count > 0)  // Notification was created
    }

    @Test func ungatedOmitsSuggestionWhenNoCandidateEligible() async throws {
        try await db.config.setLimitRotationEnabled(false)

        // Setup: limited profile, no other eligible profile
        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauth)
        try await makeSnapshot(for: limitedProfileID, percent: 90)

        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())

        let response = await detect()
        #expect(response.success)

        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        // Notification should not mention a suggestion
        #expect(notifs[0].message?.contains("has room") == false)
    }

    // MARK: - Gated tests (§7.2)

    @Test func gatedWithFlagOffDoesNotSwap() async throws {
        try await db.config.setLimitRotationEnabled(false)

        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauth)
        let eligibleProfileID = try await makeProfile(name: "Eligible", kind: .oauth)
        try await makeSnapshot(for: limitedProfileID, percent: 90)
        try await makeSnapshot(for: eligibleProfileID, percent: 30)

        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { id in "\(id.uuidString)@example.com" }
        )
        router.profilePoolCandidateSource = source

        let before = try await db.terminals.get(id: terminalID)!
        _ = await detect()
        let after = try await db.terminals.get(id: terminalID)!

        #expect(before.profileID == after.profileID)  // No swap occurred
    }

    @Test func rotationEligibilityFlagOff() {
        let terminal = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: UUID().uuidString, suspendedAt: nil, profileID: UUID(),
            kind: .claude, hibernatedAt: nil, transport: .tmux)

        let verdict = RPCRouter.rotationEligibility(terminal: terminal, flagOn: false, suggested: UUID())
        #expect(verdict == .flagOff)
    }

    @Test func rotationEligibilityAmbientSession() {
        let terminal = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: UUID().uuidString, suspendedAt: nil, profileID: nil,
            kind: .claude, hibernatedAt: nil, transport: .tmux)

        let verdict = RPCRouter.rotationEligibility(terminal: terminal, flagOn: true, suggested: UUID())
        #expect(verdict == .ambient)
    }

    @Test func rotationEligibilityParkedSession() {
        let terminal = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: UUID().uuidString, suspendedAt: nil, profileID: UUID(),
            kind: .claude, hibernatedAt: Date(), transport: .tmux)

        let verdict = RPCRouter.rotationEligibility(terminal: terminal, flagOn: true, suggested: UUID())
        #expect(verdict == .parked)
    }

    @Test func rotationEligibilityHolderTransport() {
        let terminal = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: UUID().uuidString, suspendedAt: nil, profileID: UUID(),
            kind: .claude, hibernatedAt: nil, transport: .holder)

        let verdict = RPCRouter.rotationEligibility(terminal: terminal, flagOn: true, suggested: UUID())
        #expect(verdict == .holderTransport)
    }

    @Test func rotationEligibilityNoSessionID() {
        let terminal = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: nil, suspendedAt: nil, profileID: UUID(),
            kind: .claude, hibernatedAt: nil, transport: .tmux)

        let verdict = RPCRouter.rotationEligibility(terminal: terminal, flagOn: true, suggested: UUID())
        #expect(verdict == .noSession)
    }

    @Test func rotationEligibilityNoCandidate() {
        let terminal = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: UUID().uuidString, suspendedAt: nil, profileID: UUID(),
            kind: .claude, hibernatedAt: nil, transport: .tmux)

        let verdict = RPCRouter.rotationEligibility(terminal: terminal, flagOn: true, suggested: nil)
        #expect(verdict == .noCandidate)
    }

    @Test func rotationEligibilityEligibleForRotation() {
        let suggestedID = UUID()
        let terminal = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: UUID().uuidString, suspendedAt: nil, profileID: UUID(),
            kind: .claude, hibernatedAt: nil, transport: .tmux)

        let verdict = RPCRouter.rotationEligibility(terminal: terminal, flagOn: true, suggested: suggestedID)
        #expect(verdict == .rotate(suggestedID))
    }

    // MARK: - Delta broadcast tests

    @Test func deltaIncludesResetsAtAndLimitType() async throws {
        try await db.config.setLimitRotationEnabled(false)

        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauth)
        try await makeSnapshot(for: limitedProfileID, percent: 90)

        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { id in "\(id.uuidString)@example.com" }
        )
        router.profilePoolCandidateSource = source

        let resetsAt = Date().addingTimeInterval(7200)  // 2 hours
        _ = await detect(limitType: "weekly_all", resetsAt: resetsAt)

        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].type == .limitReached)
    }

    @Test func sameAccountExclusionWorks() async throws {
        try await db.config.setLimitRotationEnabled(false)

        // Two profiles on same account (same organizationID)
        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauth)
        let sameAccountProfileID = try await makeProfile(name: "SameAccount", kind: .oauth)
        let differentAccountProfileID = try await makeProfile(name: "Different", kind: .oauth)

        try await makeSnapshot(for: limitedProfileID, percent: 90, organizationID: "org-123")
        try await makeSnapshot(for: sameAccountProfileID, percent: 30, organizationID: "org-123")
        try await makeSnapshot(for: differentAccountProfileID, percent: 30, organizationID: "org-456")

        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())

        let response = await detect()
        #expect(response.success)

        // The notification should suggest the different-account profile, not the same-account one
        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].message?.contains("Different") == true)
    }

    // MARK: - Seam tests: rotation swap behavior

    @Test func rotationSeamSuccessSchedulesContinueAndBroadcastsDelta() async throws {
        try await db.config.setLimitRotationEnabled(true)
        try await db.config.setAutoResumeOnLimitReset(false)

        // Setup: limited and eligible profiles
        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauth)
        let eligibleProfileID = try await makeProfile(name: "Eligible", kind: .oauth)
        try await makeSnapshot(for: limitedProfileID, percent: 90, organizationID: "org-123")
        try await makeSnapshot(for: eligibleProfileID, percent: 30, organizationID: "org-456")

        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { id in "\(id.uuidString)@example.com" }
        )

        // Construct router with the source
        let testRouter = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            profilePoolCandidateSource: source,
            actuationLog: makeTestActuationLog())

        // Setup scheduler
        testRouter.limitResumeScheduler = LimitResumeScheduler(
            store: db.scheduledResumes, config: db.config,
            actuator: FakeActuator(), clock: clock,
            jitterProvider: { 0 }, onOutcome: { _, _ in })

        // Setup swap seam to return success
        let receivedParams = SwapParamsBox()
        testRouter.rotationSwapPerformer = { paramsData, actor in
            let decoder = JSONDecoder()
            receivedParams.value = try decoder.decode(TerminalSwapProfileParams.self, from: paramsData)
            return .ok()
        }

        let request = try! RPCRequest(
            method: RPCMethod.claudeRateLimitDetected,
            params: RateLimitDetectedParams(
                terminalID: terminalID,
                resetsAt: Date().addingTimeInterval(3600),
                limitType: "session",
                rawMessage: "You've hit your session limit · resets 3pm (UTC)"))
        let response = await testRouter.handle(request)
        #expect(response.success)

        // Verify seam was called with correct params
        #expect(receivedParams.value?.terminalID == terminalID)
        #expect(receivedParams.value?.newProfileID == eligibleProfileID)
        #expect(receivedParams.value?.mode == .inPlace)

        // Check for rotation pending row, no reset-time row
        let pending = try await db.scheduledResumes.pending(terminalID: terminalID)
        #expect(pending != nil)
        #expect(pending?.limitType == "rotation")

        // Check notification says "switched to"
        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].message?.contains("switched to") == true)
        #expect(notifs[0].message?.contains("Eligible") == true)
    }

    /// The swap succeeds but no `continue` can be armed. The reachable shape
    /// of that today is "no scheduler" (the daemon constructs one, mock mode
    /// does not); the other shape — `schedule()` returning nil because a
    /// duplicate report raced in between the handler's latch check and the
    /// swap — cannot be forced deterministically, because the latch at the top
    /// of the handler turns a pre-seeded pending row into an early return
    /// before the swap. Either way the person must not be told the turn will
    /// resume on its own when nothing was armed.
    @Test func rotationSeamSuccessWithoutAnArmedContinueSaysSo() async throws {
        try await db.config.setLimitRotationEnabled(true)
        try await db.config.setAutoResumeOnLimitReset(false)

        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauth)
        let eligibleProfileID = try await makeProfile(name: "Eligible", kind: .oauth)
        try await makeSnapshot(for: limitedProfileID, percent: 90, organizationID: "org-123")
        try await makeSnapshot(for: eligibleProfileID, percent: 30, organizationID: "org-456")
        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { id in "\(id.uuidString)@example.com" }
        )
        let testRouter = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            profilePoolCandidateSource: source,
            actuationLog: makeTestActuationLog())
        // Deliberately no scheduler: the swap can succeed, the continue cannot be armed.
        testRouter.limitResumeScheduler = nil
        let receivedParams = SwapParamsBox()
        testRouter.rotationSwapPerformer = { paramsData, _ in
            receivedParams.value = try JSONDecoder().decode(TerminalSwapProfileParams.self, from: paramsData)
            return .ok()
        }

        let request = try! RPCRequest(
            method: RPCMethod.claudeRateLimitDetected,
            params: RateLimitDetectedParams(
                terminalID: terminalID,
                resetsAt: Date().addingTimeInterval(3600),
                limitType: "session",
                rawMessage: "You've hit your session limit · resets 3pm (UTC)"))
        let response = await testRouter.handle(request)
        #expect(response.success)

        // The swap happened …
        #expect(receivedParams.value?.newProfileID == eligibleProfileID)
        // … nothing was armed …
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) == nil)
        // … and the notification says both things rather than implying a resume.
        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].message?.contains("switched to Eligible") == true, "got: \(notifs[0].message ?? "nil")")
        #expect(notifs[0].message?.contains("not resumed automatically") == true, "got: \(notifs[0].message ?? "nil")")
    }

    @Test func rotationSeamFailureReturnsAuditRowAndSuggestion() async throws {
        try await db.config.setLimitRotationEnabled(true)
        try await db.config.setAutoResumeOnLimitReset(false)

        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauth)
        let eligibleProfileID = try await makeProfile(name: "Eligible", kind: .oauth)
        try await makeSnapshot(for: limitedProfileID, percent: 90, organizationID: "org-123")
        try await makeSnapshot(for: eligibleProfileID, percent: 30, organizationID: "org-456")

        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { id in "\(id.uuidString)@example.com" }
        )

        // Construct router with the source
        let testRouter = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            profilePoolCandidateSource: source,
            actuationLog: makeTestActuationLog())

        // Setup scheduler
        testRouter.limitResumeScheduler = LimitResumeScheduler(
            store: db.scheduledResumes, config: db.config,
            actuator: FakeActuator(), clock: clock,
            jitterProvider: { 0 }, onOutcome: { _, _ in })

        // Setup swap seam to return error
        testRouter.rotationSwapPerformer = { _, _ in
            return try RPCResponse(error: "boom")
        }

        let request = try! RPCRequest(
            method: RPCMethod.claudeRateLimitDetected,
            params: RateLimitDetectedParams(
                terminalID: terminalID,
                resetsAt: Date().addingTimeInterval(3600),
                limitType: "session",
                rawMessage: "You've hit your session limit · resets 3pm (UTC)"))
        let response = await testRouter.handle(request)
        #expect(response.success)

        // Check no rotation pending row, but audit row present
        let pending = try await db.scheduledResumes.pending(terminalID: terminalID)
        #expect(pending == nil)

        let all = try await db.scheduledResumes.all(terminalID: terminalID)
        #expect(all.count == 1)
        #expect(all[0].status == .cancelled)

        // Check notification carries suggestion
        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].message?.contains("has room") == true)
        #expect(notifs[0].message?.contains("Eligible") == true)
    }

    @Test func rotationSeamThrowingFallsThroughToResetTime() async throws {
        try await db.config.setLimitRotationEnabled(true)
        try await db.config.setAutoResumeOnLimitReset(false)

        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauth)
        let eligibleProfileID = try await makeProfile(name: "Eligible", kind: .oauth)
        try await makeSnapshot(for: limitedProfileID, percent: 90, organizationID: "org-123")
        try await makeSnapshot(for: eligibleProfileID, percent: 30, organizationID: "org-456")

        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())

        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { id in "\(id.uuidString)@example.com" }
        )

        // Construct router with the source
        let testRouter = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            profilePoolCandidateSource: source,
            actuationLog: makeTestActuationLog())

        // Setup scheduler
        testRouter.limitResumeScheduler = LimitResumeScheduler(
            store: db.scheduledResumes, config: db.config,
            actuator: FakeActuator(), clock: clock,
            jitterProvider: { 0 }, onOutcome: { _, _ in })

        // Setup swap seam to throw
        testRouter.rotationSwapPerformer = { _, _ in
            throw NSError(domain: "test", code: 1)
        }

        let request = try! RPCRequest(
            method: RPCMethod.claudeRateLimitDetected,
            params: RateLimitDetectedParams(
                terminalID: terminalID,
                resetsAt: Date().addingTimeInterval(3600),
                limitType: "session",
                rawMessage: "You've hit your session limit · resets 3pm (UTC)"))
        let response = await testRouter.handle(request)
        #expect(response.success)

        // Check no rotation pending row, but audit row present (reset-time behavior)
        let pending = try await db.scheduledResumes.pending(terminalID: terminalID)
        #expect(pending == nil)

        let all = try await db.scheduledResumes.all(terminalID: terminalID)
        #expect(all.count == 1)
        #expect(all[0].status == .cancelled)

        // Check notification carries suggestion
        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].message?.contains("has room") == true)
    }

    // MARK: - The rotation continue is governed by the rotation flag

    /// Lets the scheduler's loop observe a clock advance (copied from
    /// `LimitResumeSchedulerTests`; a raw sleep is fine in a test).
    private func pump() async {
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }
    }

    /// Builds a router whose scheduler is STARTED, so a fire actually happens.
    private func makeStartedRotationRouter(actuator: FakeActuator) async throws -> RPCRouter {
        let source = ProfilePoolCandidateSource(
            profiles: db.modelProfiles,
            snapshots: db.oauthUsageSnapshots,
            terminals: db.terminals,
            loginIdentity: { id in "\(id.uuidString)@example.com" }
        )
        let testRouter = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            profilePoolCandidateSource: source,
            actuationLog: makeTestActuationLog())
        let scheduler = LimitResumeScheduler(
            store: db.scheduledResumes, config: db.config,
            actuator: actuator, clock: clock,
            jitterProvider: { 0 }, onOutcome: { _, _ in })
        testRouter.limitResumeScheduler = scheduler
        testRouter.rotationSwapPerformer = { _, _ in .ok() }
        await scheduler.start()
        return testRouter
    }

    private func seedLimitedAndEligible() async throws {
        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauth)
        let eligibleProfileID = try await makeProfile(name: "Eligible", kind: .oauth)
        try await makeSnapshot(for: limitedProfileID, percent: 90, organizationID: "org-123")
        try await makeSnapshot(for: eligibleProfileID, percent: 30, organizationID: "org-456")
        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())
    }

    @Test func rotationContinueFollowsTheRotationFlagNotTheResetTimeToggle() async throws {
        try await db.config.setLimitRotationEnabled(true)
        try await db.config.setAutoResumeOnLimitReset(false)
        var config = try await db.config.get()
        #expect(config.autoResumeEnabled(forLimitType: ScheduledResume.rotationLimitType) == true)
        #expect(config.autoResumeEnabled(forLimitType: "session") == false)

        try await db.config.setLimitRotationEnabled(false)
        try await db.config.setAutoResumeOnLimitReset(true)
        config = try await db.config.get()
        #expect(config.autoResumeEnabled(forLimitType: ScheduledResume.rotationLimitType) == false)
        #expect(config.autoResumeEnabled(forLimitType: "session") == true)
    }

    @Test func rotationContinueFiresWithOnlyTheRotationFlagOn() async throws {
        try await db.config.setLimitRotationEnabled(true)
        try await db.config.setAutoResumeOnLimitReset(false)   // the older toggle stays OFF
        try await seedLimitedAndEligible()
        let actuator = FakeActuator([.sent])
        let testRouter = try await makeStartedRotationRouter(actuator: actuator)

        let response = await testRouter.handle(try! RPCRequest(
            method: RPCMethod.claudeRateLimitDetected,
            params: RateLimitDetectedParams(
                terminalID: terminalID, resetsAt: Date().addingTimeInterval(3600),
                limitType: "session", rawMessage: "You've hit your session limit · resets 3pm (UTC)")))
        #expect(response.success)
        let pending = try await db.scheduledResumes.pending(terminalID: terminalID)
        #expect(pending?.limitType == ScheduledResume.rotationLimitType)

        await pump()
        #expect(actuator.calls.isEmpty, "fires after the slack, not before")
        // The handler stamps `resetsAt` with the wall clock while the scheduler
        // sleeps on the test clock; bring the test clock past the wall-clock
        // fire time before asserting on delivery.
        await clock.advance(by: Date().timeIntervalSince(clock.now()) + LimitResumeScheduler.slack + 5)
        await pump()
        #expect(actuator.calls.count == 1, "the rotation continue must be delivered with only limit_rotation_enabled on")
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) == nil)
        await testRouter.limitResumeScheduler?.stop()
    }

    @Test func turningRotationOffCancelsOnlyRotationContinues() async throws {
        try await db.config.setLimitRotationEnabled(true)
        try await db.config.setAutoResumeOnLimitReset(false)
        try await seedLimitedAndEligible()
        let actuator = FakeActuator([.sent])
        let testRouter = try await makeStartedRotationRouter(actuator: actuator)
        _ = await testRouter.handle(try! RPCRequest(
            method: RPCMethod.claudeRateLimitDetected,
            params: RateLimitDetectedParams(
                terminalID: terminalID, resetsAt: Date().addingTimeInterval(3600),
                limitType: "session", rawMessage: "You've hit your session limit · resets 3pm (UTC)")))
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID)?.limitType == ScheduledResume.rotationLimitType)

        // A reset-time row on another terminal must survive the rotation toggle.
        let other = try await db.terminals.create(worktreeID: worktreeID, tmuxWindowID: "@9", tmuxPaneID: "%9")
        _ = try await db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: other.id, worktreeID: worktreeID,
            resetsAt: clock.now().addingTimeInterval(3600),
            fireAt: clock.now().addingTimeInterval(3660),
            limitType: "session", rawMessage: "m"))

        let off = await testRouter.handle(try! RPCRequest(
            method: RPCMethod.configSetLimitRotationEnabled,
            params: ConfigSetLimitRotationEnabledParams(enabled: false)))
        #expect(off.success)
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) == nil, "rotation row cancelled")
        #expect(try await db.scheduledResumes.pending(terminalID: other.id)?.limitType == "session", "reset-time row untouched")

        // The handler stamps `resetsAt` with the wall clock while the scheduler
        // sleeps on the test clock; bring the test clock past the wall-clock
        // fire time before asserting on delivery.
        await clock.advance(by: Date().timeIntervalSince(clock.now()) + LimitResumeScheduler.slack + 5)
        await pump()
        #expect(actuator.calls.isEmpty, "a cancelled rotation continue is never typed")
        await testRouter.limitResumeScheduler?.stop()
    }

    @Test func resetTimeToggleOffLeavesRotationContinuesAlone() async throws {
        _ = try await db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: terminalID, worktreeID: worktreeID,
            resetsAt: clock.now(), fireAt: clock.now().addingTimeInterval(60),
            limitType: ScheduledResume.rotationLimitType, rawMessage: "m"))
        let cancelled = try await db.scheduledResumes.cancelAllPending(scope: .limitOnly)
        #expect(cancelled == 0)
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID)?.limitType == ScheduledResume.rotationLimitType)
        let cancelledRotation = try await db.scheduledResumes.cancelAllPending(scope: .rotationOnly)
        #expect(cancelledRotation == 1)
        #expect(try await db.scheduledResumes.pending(terminalID: terminalID) == nil)
    }

    // MARK: - Wiring regression

    /// The daemon once built the router without a candidate source, which left
    /// both rotation behaviors unreachable in production while every test —
    /// each wiring its own source — stayed green. The router now defaults the
    /// source from its own stores, so a router constructed without one must
    /// still suggest a profile. A setup-token profile is used because its
    /// credential is read from the snapshot, not from a login file on disk.
    @Test func aRouterConstructedWithoutASourceStillSuggests() async throws {
        try await db.config.setLimitRotationEnabled(false)
        #expect(router.profilePoolCandidateSource != nil,
                "RPCRouter.init must default profilePoolCandidateSource — see Daemon.swift wiring")

        let limitedProfileID = try await makeProfile(name: "Limited", kind: .oauthToken)
        let roomyProfileID = try await makeProfile(name: "Roomy", kind: .oauthToken)
        try await makeSnapshot(for: limitedProfileID, percent: 90, organizationID: "org-limited")
        try await makeSnapshot(for: roomyProfileID, percent: 20, organizationID: "org-roomy")
        try await setTerminalProfile(limitedProfileID)
        try await setTerminalSessionID(UUID())

        let response = await detect()
        #expect(response.success)

        let notifs = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(notifs.count == 1)
        #expect(notifs[0].message?.contains("Roomy has room") == true,
                "got: \(notifs[0].message ?? "nil")")
    }
}

/// Single-writer box so the swap seam (a `@Sendable` closure) can hand the
/// decoded params back to the test without a captured-var mutation.
private final class SwapParamsBox: @unchecked Sendable {
    var value: TerminalSwapProfileParams?
}
