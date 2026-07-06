import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("HibernationCoordinator")
struct HibernationCoordinatorTests {

    /// In-memory DB + repo + worktree + an idle Claude terminal.
    private func setup(
        activityState: TerminalActivityState = .idle,
        keepWarm: Bool = false,
        sessionID: String? = "sess-1",
        kind: TerminalKind? = .claude
    ) async throws -> (TBDDatabase, UUID, UUID) {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/hib-repo", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/hib-repo", tmuxServer: "tbd-hib"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: sessionID, kind: kind
        )
        if activityState != .unknown {
            try await db.terminals.setActivityState(id: terminal.id, activityState: activityState)
        }
        if keepWarm {
            try await db.terminals.setKeepWarm(id: terminal.id, keepWarm: true)
        }
        return (db, wt.id, terminal.id)
    }

    private func coordinator(_ db: TBDDatabase) -> HibernationCoordinator {
        HibernationCoordinator(db: db, tmux: TmuxManager(dryRun: true))
    }

    // MARK: - Manual hibernate

    @Test func manualHibernateMarksHibernated() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        let result = await coordinator(db).manualHibernate(terminalID: terminalID)
        #expect(result == .ok)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt != nil)
        #expect(after?.isHibernated == true)
    }

    @Test func manualHibernateRefusesRunningTurn() async throws {
        let (db, _, terminalID) = try await setup(activityState: .working)
        let result = await coordinator(db).manualHibernate(terminalID: terminalID)
        guard case .notEligible = result else {
            Issue.record("expected .notEligible for a running turn, got \(result)")
            return
        }
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    @Test func manualHibernateRefusesPermissionPrompt() async throws {
        let (db, _, terminalID) = try await setup(activityState: .waitingForUser)
        let result = await coordinator(db).manualHibernate(terminalID: terminalID)
        guard case .notEligible = result else {
            Issue.record("expected .notEligible for a permission prompt, got \(result)")
            return
        }
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    @Test func manualHibernateIgnoresKeepWarm() async throws {
        // Manual hibernate BYPASSES keep-warm (the user asked explicitly).
        let (db, _, terminalID) = try await setup(activityState: .idle, keepWarm: true)
        let result = await coordinator(db).manualHibernate(terminalID: terminalID)
        #expect(result == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)
    }

    @Test func manualHibernateRejectsNonClaude() async throws {
        let (db, _, terminalID) = try await setup(sessionID: nil, kind: .shell)
        let result = await coordinator(db).manualHibernate(terminalID: terminalID)
        guard case .notEligible = result else {
            Issue.record("expected .notEligible for a shell terminal, got \(result)")
            return
        }
    }

    @Test func manualHibernateAlreadyHibernatedIsNoOp() async throws {
        let (db, _, terminalID) = try await setup()
        _ = await coordinator(db).manualHibernate(terminalID: terminalID)
        let second = await coordinator(db).manualHibernate(terminalID: terminalID)
        #expect(second == .alreadyHibernated)
    }

    // MARK: - Wake

    @Test func wakeClearsHibernatedAndRespawnsResume() async throws {
        let (db, _, terminalID) = try await setup()
        let recorded = RecordedTmuxCommands()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorded.append($0) })
        let coord = HibernationCoordinator(db: db, tmux: tmux)

        _ = await coord.manualHibernate(terminalID: terminalID)
        #expect(try await db.terminals.get(id: terminalID)?.isHibernated == true)

        let wake = await coord.wake(terminalID: terminalID)
        #expect(wake == .ok)
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)

        // A respawn-window with `claude --resume` must have been issued.
        let joined = recorded.snapshot().map { $0.joined(separator: " ") }
        #expect(joined.contains { $0.contains("respawn-window") && $0.contains("claude --resume sess-1") },
                "expected a respawn-window carrying claude --resume; got: \(joined)")
    }

    @Test func wakeOnNonHibernatedIsIdempotentNoOp() async throws {
        let (db, _, terminalID) = try await setup()
        let result = await coordinator(db).wake(terminalID: terminalID)
        #expect(result == .notHibernated)
    }

    @Test func wakeUnknownTerminalNotFound() async throws {
        let (db, _, _) = try await setup()
        let result = await coordinator(db).wake(terminalID: UUID())
        #expect(result == .notFound)
    }

    // MARK: - Keep-warm

    @Test func setKeepWarmPersists() async throws {
        let (db, _, terminalID) = try await setup()
        let ok = await coordinator(db).setKeepWarm(terminalID: terminalID, keepWarm: true)
        #expect(ok)
        #expect(try await db.terminals.get(id: terminalID)?.keepWarm == true)
        _ = await coordinator(db).setKeepWarm(terminalID: terminalID, keepWarm: false)
        #expect(try await db.terminals.get(id: terminalID)?.keepWarm == false)
    }

    // MARK: - Idle sweep gating

    @Test func sweepDoesNotHibernateWhenFeatureDisabled() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle)
        try await db.config.setAutoHibernate(enabled: false, idleMinutes: 1)
        let coord = coordinator(db)
        // Even after many sweeps, disabled means never hibernated.
        await coord.sweep()
        await coord.sweep()
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    @Test func sweepDoesNotHibernateRunningTurn() async throws {
        let (db, _, terminalID) = try await setup(activityState: .working)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let coord = coordinator(db)
        for _ in 0..<4 { await coord.sweep() }
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil,
                "a running turn must never be auto-hibernated")
    }

    @Test func sweepDoesNotHibernateKeepWarm() async throws {
        let (db, _, terminalID) = try await setup(activityState: .idle, keepWarm: true)
        try await db.config.setAutoHibernate(enabled: true, idleMinutes: 1)
        let coord = coordinator(db)
        for _ in 0..<4 { await coord.sweep() }
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil,
                "a keep-warm session must never be auto-hibernated")
    }
}

/// Thread-safe collector for TmuxManager dryRun recorded args.
private final class RecordedTmuxCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []
    func append(_ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        commands.append(args)
    }
    func snapshot() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return commands
    }
}
