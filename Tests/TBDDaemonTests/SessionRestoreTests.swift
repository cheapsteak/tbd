import Foundation
import GRDB
import Testing
import DaemonTestSupport
import TestSupport
import TBDKernel

@testable import TBDDaemonLib
@testable import TBDShared

/// Answers each start-admission question through a closure and records what it
/// was asked. The closure runs at the moment a production wake asks, so one test
/// can hold one row, stall one wake, or win a race against one.
private final class ScriptedAdmission: StartAdmissionEvaluating, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [StartAdmissionRequest] = []
    private let answer: @Sendable (StartAdmissionRequest) async -> StartAdmissionVerdict

    init(_ answer: @escaping @Sendable (StartAdmissionRequest) async -> StartAdmissionVerdict) {
        self.answer = answer
    }

    var requests: [StartAdmissionRequest] { lock.withLock { asked } }

    func evaluate(_ request: StartAdmissionRequest) async -> StartAdmissionVerdict {
        lock.withLock { asked.append(request) }
        return await answer(request)
    }
}

/// Holds a wake inside its admission check until the test lets it go.
private actor WakeLatch {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// The startup restore pass through the real router: real stores, dry-run tmux,
/// a real actuation log in a temp directory, and every wake through the real
/// `terminal.wake` handler. Each wake outcome comes from the production path
/// that produces it, so nothing here stubs the wake.
///
/// Tier 2: real filesystem, and real git in the tests that run a reconcile.
/// Virtual time drives the gaps, and rows carry fixed dates, so nothing depends
/// on the wall clock outside those reconcile tests.
@Suite("Session restore", .clockDriven)
struct SessionRestoreTests {

    /// The moment the daemon began its startup reconcile.
    private static let thisStartup = Date(timeIntervalSince1970: 1_800_000_000)
    private static let gap = RPCRouter.sessionRestoreBatchGap
    private static let holdReason = "machine is too full"

    private struct Fixture {
        let router: RPCRouter
        let lifecycle: WorktreeLifecycle
        let db: TBDDatabase
        let clock: EventDrivenTestClock
        let logPath: String
        let directory: URL
        let repoID: UUID
        let worktree: Worktree

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture(
        flag: Bool? = true,
        tmux: TmuxManager = TmuxManager(dryRun: true),
        unwritableLog: Bool = false
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-session-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var logDirectory = directory
        if unwritableLog {
            // A file where the log's directory should be: every append throws.
            logDirectory = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: logDirectory)
        }
        let logPath = logDirectory.appendingPathComponent("actuations.jsonl").path

        let db = try TBDDatabase(inMemory: true)
        let clock = EventDrivenTestClock()
        let lifecycle = WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux, startTime: Date(),
            configDirManager: makeIsolatedConfigDirManager(tag: "session-restore"),
            sessionsDir: directory.appendingPathComponent("sessions", isDirectory: true),
            actuationLog: ActuationLog(path: logPath), clock: clock)
        if let flag { try await db.config.setSessionRestore(flag) }

        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await makeWorktree(db: db, repoID: repo.id, directory: directory)
        return Fixture(
            router: router, lifecycle: lifecycle, db: db, clock: clock, logPath: logPath,
            directory: directory, repoID: repo.id, worktree: worktree)
    }

    /// A worktree row with its own directory on disk: its path is unique, and a
    /// wake refuses a directory that is not there.
    private func makeWorktree(db: TBDDatabase, repoID: UUID, directory: URL) async throws -> Worktree {
        let name = "acme-\(UUID().uuidString)"
        let path = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return try await db.worktrees.create(
            repoID: repoID, name: name, branch: name, path: path.path, tmuxServer: "tbd-acme")
    }

    private func makeWorktree(in fixture: Fixture) async throws -> Worktree {
        try await makeWorktree(db: fixture.db, repoID: fixture.repoID, directory: fixture.directory)
    }

    /// A parked row, by default one this startup parked for recovery. Window ids
    /// are unique so one row's wake never reads as a claim on another's window.
    @discardableResult
    private func park(
        in fixture: Fixture,
        worktree: Worktree? = nil,
        kind: TerminalKind = .claude,
        reason: HibernateReason = .recovery,
        parkedAt: Date = SessionRestoreTests.thisStartup,
        transcriptPath: String? = nil
    ) async throws -> UUID {
        let token = UUID().uuidString
        let sessionID = "session-\(token)"
        let terminal = try await fixture.db.terminals.create(
            worktreeID: (worktree ?? fixture.worktree).id,
            tmuxWindowID: "@\(token)", tmuxPaneID: "%\(token)",
            label: TerminalLabel.claudeCode, claudeSessionID: sessionID, kind: kind)
        if let transcriptPath {
            try await fixture.db.terminals.updateSession(
                id: terminal.id, sessionID: sessionID, transcriptPath: transcriptPath)
        }
        try await fixture.db.terminals.setHibernated(
            id: terminal.id, sessionID: sessionID, reason: reason, at: parkedAt)
        return terminal.id
    }

    /// A parked row whose transcript last changed `age` seconds before startup.
    private func parkWithTranscript(in fixture: Fixture, age: Int) async throws -> UUID {
        let url = fixture.directory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try Data("{}\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.thisStartup.addingTimeInterval(Double(-age))],
            ofItemAtPath: url.path)
        return try await park(in: fixture, transcriptPath: url.path)
    }

    /// The user wakes the row and it parks again, stamped after this startup so
    /// the reason is all that sets it apart. Static so a `@Sendable` admission
    /// closure can call it.
    private static func repark(
        _ id: UUID, reason: HibernateReason, in db: TBDDatabase
    ) async throws {
        let row = try #require(try await db.terminals.get(id: id))
        let sessionID = try #require(row.claudeSessionID)
        try await db.terminals.clearHibernated(id: id)
        try await db.terminals.setHibernated(
            id: id, sessionID: sessionID, reason: reason,
            at: thisStartup.addingTimeInterval(30))
    }

    /// `count` parked rows, returned in the order the pass wakes them.
    private func parkRows(_ count: Int, in fixture: Fixture) async throws -> [UUID] {
        var ids: [UUID] = []
        for age in 0..<count {
            ids.append(try await parkWithTranscript(in: fixture, age: age))
        }
        return ids
    }

    /// Runs the pass with the fixture's clock. Captures the router alone: the
    /// fixture does not cross into the task.
    private func startPass(_ fixture: Fixture) -> Task<SessionRestoreSummary, Never> {
        let router = fixture.router
        let parkedSince = Self.thisStartup
        return Task { await router.restoreSessionsAfterStartup(parkedSince: parkedSince) }
    }

    /// The end of a pass that has no gap left to sleep. A gap armed anyway fails
    /// here and is released, so the regression reads as this assertion rather
    /// than a test hung on a sleep nobody advances.
    private func finishWithNoGap(
        _ pass: Task<SessionRestoreSummary, Never>, _ fixture: Fixture
    ) async -> SessionRestoreSummary {
        let armed = await watchForSleeper(on: fixture.clock)
        #expect(!armed, "the pass armed a gap when no further batch was due")
        if armed { await fixture.clock.advance(by: Self.gap) }
        return await pass.value
    }

    private func awake(_ ids: [UUID], in db: TBDDatabase) async throws -> Set<UUID> {
        var result = Set<UUID>()
        for id in ids {
            let row = try #require(try await db.terminals.get(id: id))
            if !row.isParked { result.insert(id) }
        }
        return result
    }

    /// The `terminal.wake` request rows in the actuation log.
    private func wakeRequests(at path: String) throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let rows: [[String: Any]] = try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
        return rows.filter { ($0["method"] as? String) == RPCMethod.terminalWake }
    }

    /// Every window answers dead, as after a reboot.
    private static func rebootedTmux() -> TmuxManager {
        TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true })
    }

    /// A real startup reconcile finding a main worktree's Claude session dead.
    /// - Returns: the parked row, and the moment before the reconcile began.
    private func startupThatParks(
        _ fixture: Fixture, repoDir: URL
    ) async throws -> (terminalID: UUID, parkedSince: Date) {
        let repo = try await fixture.db.repos.create(
            path: repoDir.path, displayName: "acme-repo", defaultBranch: "main")
        let main = try await fixture.db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoDir.path,
            tmuxServer: TmuxManager.serverName(forRepoPath: repoDir.path))
        let terminal = try await fixture.db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-1", kind: .claude)
        let parkedSince = Date()
        try await fixture.lifecycle.reconcile(
            repoID: repo.id, actuationLog: ActuationLog(path: fixture.logPath),
            reapSharedScratchTmuxResources: true)
        let parked = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(parked.isParked)
        #expect(parked.hibernateReason == .recovery)
        return (terminal.id, parkedSince)
    }

    // MARK: - The flag

    @Test("flag off or never chosen: a startup that parks sessions wakes none",
          arguments: [false as Bool?, nil])
    func flagOffWakesNothing(flag: Bool?) async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fixture = try await makeFixture(flag: flag, tmux: Self.rebootedTmux())
        defer { fixture.cleanUp() }
        let startup = try await startupThatParks(fixture, repoDir: repoDir)

        let summary = await fixture.router.restoreSessionsAfterStartup(
            parkedSince: startup.parkedSince)

        #expect(summary == SessionRestoreSummary())
        #expect(try await awake([startup.terminalID], in: fixture.db).isEmpty)
        #expect(try wakeRequests(at: fixture.logPath).isEmpty)
    }

    @Test("flag on: the same startup wakes them")
    func flagOnWakesWhatTheStartupParked() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fixture = try await makeFixture(flag: true, tmux: Self.rebootedTmux())
        defer { fixture.cleanUp() }
        let startup = try await startupThatParks(fixture, repoDir: repoDir)

        let summary = await fixture.router.restoreSessionsAfterStartup(
            parkedSince: startup.parkedSince)

        #expect(summary == SessionRestoreSummary(selected: 1, woken: 1))
        #expect(try await awake([startup.terminalID], in: fixture.db) == [startup.terminalID])
        #expect(try wakeRequests(at: fixture.logPath).count == 1)
    }

    // MARK: - Which sessions

    @Test("a recovery row parked before this startup stays parked")
    func recoveryRowFromAnEarlierStartupIsLeftOut() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let control = try await park(in: fixture)
        let earlier = try await park(
            in: fixture, parkedAt: Self.thisStartup.addingTimeInterval(-1))

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        #expect(summary == SessionRestoreSummary(selected: 1, woken: 1))
        #expect(try await awake([control, earlier], in: fixture.db) == [control])
    }

    /// The store keeps `hibernatedAt` to the millisecond, and `parkedSince` has
    /// finer precision. Without the slack, a park in the same millisecond as the
    /// startup reads back as earlier than it and is left out.
    @Test("a row parked in the startup's own millisecond is selected")
    func parkInTheStartupsMillisecondIsSelected() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let parkedSince = Date(timeIntervalSince1970: 1_800_000_000.0004)
        let row = try await park(in: fixture, parkedAt: parkedSince)

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: parkedSince)

        #expect(summary == SessionRestoreSummary(selected: 1, woken: 1))
        #expect(try await awake([row], in: fixture.db) == [row])
    }

    @Test("a row with any other park reason stays parked",
          arguments: [HibernateReason.manual, .auto, .merged, .exited])
    func otherParkReasonsAreLeftOut(reason: HibernateReason) async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let control = try await park(in: fixture)
        let other = try await park(in: fixture, reason: reason)

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        #expect(summary == SessionRestoreSummary(selected: 1, woken: 1))
        #expect(try await awake([control, other], in: fixture.db) == [control])
        let row = try #require(try await fixture.db.terminals.get(id: other))
        #expect(row.hibernateReason == reason)
    }

    @Test("a row in a worktree that is not active or main stays parked",
          arguments: [WorktreeStatus.archived, .creating, .failed])
    func otherWorktreeStatusesAreLeftOut(status: WorktreeStatus) async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let control = try await park(in: fixture)
        let worktree = try await makeWorktree(in: fixture)
        let other = try await park(in: fixture, worktree: worktree)
        try await fixture.db.worktrees.updateStatus(id: worktree.id, status: status)

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        #expect(summary == SessionRestoreSummary(selected: 1, woken: 1))
        #expect(try await awake([control, other], in: fixture.db) == [control])
    }

    @Test("a row in a main worktree is restored")
    func mainWorktreeIsSelected() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let path = fixture.directory.appendingPathComponent("main", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let main = try await fixture.db.worktrees.createMain(
            repoID: fixture.repoID, name: "main", branch: "main", path: path.path,
            tmuxServer: "tbd-acme")
        let row = try await park(in: fixture, worktree: main)

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        #expect(summary == SessionRestoreSummary(selected: 1, woken: 1))
        #expect(try await awake([row], in: fixture.db) == [row])
    }

    @Test("a tab that is not Claude's stays parked, even carrying a session id",
          arguments: [TerminalKind.shell, .codex])
    func otherTabKindsAreLeftOut(kind: TerminalKind) async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let control = try await park(in: fixture)
        let other = try await park(in: fixture, kind: kind)

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        #expect(summary == SessionRestoreSummary(selected: 1, woken: 1))
        #expect(try await awake([control, other], in: fixture.db) == [control])
    }

    @Test("a row with no session to resume stays parked")
    func rowWithNoSessionIsLeftOut() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let control = try await park(in: fixture)
        let other = try await park(in: fixture)
        let otherID = other.uuidString
        try await fixture.db.writerForTests.write { conn in
            try conn.execute(
                sql: "UPDATE terminal SET claudeSessionID = NULL WHERE id = ?",
                arguments: [otherID])
        }

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        #expect(summary == SessionRestoreSummary(selected: 1, woken: 1))
        #expect(try await awake([control, other], in: fixture.db) == [control])
    }

    @Test("a pass that selects nothing reports nothing")
    func nothingSelected() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try await park(in: fixture, reason: .manual)

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        #expect(summary == SessionRestoreSummary())
        #expect(try wakeRequests(at: fixture.logPath).isEmpty)
    }

    // MARK: - Pacing and order

    @Test("batches are three, and the next starts only when the gap is over")
    func batchesOfThreeWithAGap() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let ids = try await parkRows(7, in: fixture)
        let pass = startPass(fixture)

        try await fixture.clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        #expect(try await awake(ids, in: fixture.db).count == 3)

        await fixture.clock.advance(by: Self.gap - .seconds(1))
        #expect(fixture.clock.hasSleeper, "the first gap ended a second early")
        #expect(try await awake(ids, in: fixture.db).count == 3)

        await fixture.clock.advance(by: .seconds(1))
        try await fixture.clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        #expect(try await awake(ids, in: fixture.db).count == 6)

        await fixture.clock.advance(by: Self.gap)
        let summary = await pass.value
        #expect(summary == SessionRestoreSummary(selected: 7, woken: 7))
        #expect(try await awake(ids, in: fixture.db) == Set(ids))
    }

    @Test("no gap follows the last batch")
    func noGapAfterTheLastBatch() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let ids = try await parkRows(3, in: fixture)

        let summary = await finishWithNoGap(startPass(fixture), fixture)

        #expect(summary == SessionRestoreSummary(selected: 3, woken: 3))
        #expect(try await awake(ids, in: fixture.db) == Set(ids))
    }

    @Test("the gap starts only after all three wakes have returned")
    func gapWaitsForTheWholeBatch() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let ids = try await parkRows(4, in: fixture)
        let stalled = ids[2]
        let latch = WakeLatch()
        let admission = ScriptedAdmission { request in
            if request.terminalID == stalled { await latch.wait() }
            return .admit
        }
        fixture.router.startAdmission = admission
        try await fixture.db.config.setStartAdmissionEnabled(true)
        let pass = startPass(fixture)

        let asked = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            admission.requests.count == 3
        }
        #expect(asked == .satisfied)
        let armedEarly = await watchForSleeper(on: fixture.clock)
        #expect(!armedEarly, "the gap began while a wake of the batch had not returned")

        await latch.release()
        try await fixture.clock.requireAdvanceWhenArmed(
            by: Self.gap, timeout: TestDeadlines.saturatedPass)
        let summary = await pass.value
        #expect(summary == SessionRestoreSummary(selected: 4, woken: 4))
    }

    /// Created so that neither creation order nor its reverse is the wake order,
    /// and with the two unreadable rows first.
    @Test("newest transcript first, and an unreadable one last")
    func orderFollowsTranscriptModificationTime() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let missingFile = fixture.directory.appendingPathComponent("gone.jsonl").path
        let unreadable = try await park(in: fixture, transcriptPath: missingFile)
        let noPath = try await park(in: fixture)
        let third = try await parkWithTranscript(in: fixture, age: 3)
        let sixth = try await parkWithTranscript(in: fixture, age: 6)
        let first = try await parkWithTranscript(in: fixture, age: 1)
        let fourth = try await parkWithTranscript(in: fixture, age: 4)
        let second = try await parkWithTranscript(in: fixture, age: 2)
        let fifth = try await parkWithTranscript(in: fixture, age: 5)
        let ids = [unreadable, noPath, third, sixth, first, fourth, second, fifth]
        let pass = startPass(fixture)

        try await fixture.clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        #expect(try await awake(ids, in: fixture.db) == [first, second, third])

        await fixture.clock.advance(by: Self.gap)
        try await fixture.clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        #expect(try await awake(ids, in: fixture.db) == [first, second, third, fourth, fifth, sixth])

        await fixture.clock.advance(by: Self.gap)
        let summary = await pass.value
        #expect(summary == SessionRestoreSummary(selected: 8, woken: 8))
    }

    // MARK: - Stopping

    @Test("turning the flag off between batches stops the pass")
    func flagOffBetweenBatchesStopsThePass() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let ids = try await parkRows(5, in: fixture)
        let pass = startPass(fixture)

        try await fixture.clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        let off = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.configSetSessionRestore,
            params: ConfigSetSessionRestoreParams(enabled: false)))
        #expect(off.success)
        await fixture.clock.advance(by: Self.gap)

        let summary = await pass.value
        #expect(summary == SessionRestoreSummary(selected: 5, woken: 3))
        #expect(try await awake(ids, in: fixture.db) == Set(ids.prefix(3)))
    }

    /// Proves the outcome and not which line produces it. The pass stops here
    /// through its `Task.isCancelled` check or through the flag read beside it,
    /// because that read fails on a cancelled task too, and either stop passes
    /// this test. The explicit check stays so the stop does not rest on how the
    /// database treats cancellation.
    @Test("cancelling the pass during a gap starts no further batch")
    func cancellationDuringAGapStopsThePass() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let ids = try await parkRows(4, in: fixture)
        let pass = startPass(fixture)

        try await fixture.clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        pass.cancel()

        let summary = await pass.value
        #expect(summary == SessionRestoreSummary(selected: 4, woken: 3))
        #expect(try await awake(ids, in: fixture.db) == Set(ids.prefix(3)))
    }

    /// The cancellation lands while one wake is held inside its admission check.
    /// A wake that inherited it would fail its next database read, so the row
    /// would read as not found and stay parked.
    @Test("cancelling the pass mid-batch lets the batch finish and starts no further batch")
    func cancellationDuringABatchFinishesTheBatch() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let ids = try await parkRows(4, in: fixture)
        let stalled = ids[2]
        let latch = WakeLatch()
        let admission = ScriptedAdmission { request in
            if request.terminalID == stalled { await latch.wait() }
            return .admit
        }
        fixture.router.startAdmission = admission
        try await fixture.db.config.setStartAdmissionEnabled(true)
        let pass = startPass(fixture)

        let asked = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            admission.requests.count == 3
        }
        #expect(asked == .satisfied)
        pass.cancel()
        await latch.release()

        let summary = await pass.value
        #expect(summary == SessionRestoreSummary(selected: 4, woken: 3))
        #expect(admission.requests.count == 3, "a later batch ran the command")
        #expect(try await awake(ids, in: fixture.db) == Set(ids.prefix(3)))
    }

    // MARK: - Failure

    @Test("a wake into a missing worktree leaves its row parked and the pass goes on")
    func failedWakeLeavesTheRowParkedAndThePassContinues() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let gone = try await makeWorktree(in: fixture)
        let url = fixture.directory.appendingPathComponent("newest.jsonl")
        try Data("{}\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.thisStartup.addingTimeInterval(1)], ofItemAtPath: url.path)
        let failing = try await park(in: fixture, worktree: gone, transcriptPath: url.path)
        let others = try await parkRows(3, in: fixture)
        try FileManager.default.removeItem(atPath: gone.localPath)
        let pass = startPass(fixture)

        try await fixture.clock.requireAdvanceWhenArmed(
            by: Self.gap, timeout: TestDeadlines.saturatedPass)

        let summary = await pass.value
        #expect(summary == SessionRestoreSummary(selected: 4, woken: 3, failed: 1))
        #expect(try await awake(others, in: fixture.db) == Set(others))
        let row = try #require(try await fixture.db.terminals.get(id: failing))
        #expect(row.isParked)
        #expect(row.hibernateReason == .recovery)
    }

    @Test("a spawn tmux refuses leaves the row parked and the pass goes on")
    func failedSpawnLeavesTheRowParkedAndThePassContinues() async throws {
        let fixture = try await makeFixture(tmux: TmuxManager(
            dryRun: true,
            dryRunRespawnWindowError: { _ in TmuxError.unexpectedOutput("no such window") }))
        defer { fixture.cleanUp() }
        let ids = try await parkRows(4, in: fixture)
        let pass = startPass(fixture)

        try await fixture.clock.requireAdvanceWhenArmed(
            by: Self.gap, timeout: TestDeadlines.saturatedPass)

        let summary = await pass.value
        #expect(summary == SessionRestoreSummary(selected: 4, failed: 4))
        #expect(try await awake(ids, in: fixture.db).isEmpty)
        for id in ids {
            let row = try #require(try await fixture.db.terminals.get(id: id))
            #expect(row.hibernateReason == .recovery)
        }
    }

    @Test("a missing account profile fails the wake, with no fallback to the default")
    func missingProfileFailsWithNoFallback() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let row = try await park(in: fixture)
        let bogusProfile = UUID()
        try await fixture.db.terminals.setProfileID(id: row, profileID: bogusProfile)

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        #expect(summary == SessionRestoreSummary(selected: 1, failed: 1))
        let after = try #require(try await fixture.db.terminals.get(id: row))
        #expect(after.isParked)
        #expect(after.profileID == bogusProfile)
    }

    /// An unwritable actuation record makes `handleTerminalWake` throw, so every
    /// wake throws, and both batches still run.
    @Test("a wake that throws counts as failed and does not abort the pass")
    func thrownWakeCountsAsFailed() async throws {
        let fixture = try await makeFixture(unwritableLog: true)
        defer { fixture.cleanUp() }
        let ids = try await parkRows(4, in: fixture)
        let pass = startPass(fixture)

        try await fixture.clock.requireAdvanceWhenArmed(
            by: Self.gap, timeout: TestDeadlines.saturatedPass)

        let summary = await pass.value
        #expect(summary == SessionRestoreSummary(selected: 4, failed: 4))
        #expect(try await awake(ids, in: fixture.db).isEmpty)
    }

    // MARK: - Start admission

    @Test("a hold records its reason, ends the pass after its batch, and no later batch asks")
    func holdEndsThePassAfterItsBatch() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let ids = try await parkRows(5, in: fixture)
        let held = ids[1]
        let reason = Self.holdReason
        let admission = ScriptedAdmission { request in
            request.terminalID == held ? .hold(reason: reason) : .admit
        }
        fixture.router.startAdmission = admission
        try await fixture.db.config.setStartAdmissionEnabled(true)

        let summary = await finishWithNoGap(startPass(fixture), fixture)

        #expect(summary == SessionRestoreSummary(selected: 5, woken: 2, held: 1))
        #expect(admission.requests.count == 3, "a later batch ran the command")
        #expect(admission.requests.allSatisfy { $0.actorKind == ActuationActor.Kind.daemon })
        #expect(try await awake(ids, in: fixture.db) == [ids[0], ids[2]])
        let heldRow = try #require(try await fixture.db.terminals.get(id: held))
        #expect(heldRow.isParked)
        #expect(heldRow.startHeldReason == reason)
        for later in ids.suffix(2) {
            let row = try #require(try await fixture.db.terminals.get(id: later))
            #expect(row.isParked)
            #expect(row.startHeldReason == nil)
        }
    }

    @Test("with the admission flag off, the check does nothing")
    func admissionFlagOffChecksNothing() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let row = try await park(in: fixture)
        let reason = Self.holdReason
        let admission = ScriptedAdmission { _ in .hold(reason: reason) }
        fixture.router.startAdmission = admission

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        #expect(summary == SessionRestoreSummary(selected: 1, woken: 1))
        #expect(admission.requests.isEmpty)
        #expect(try await awake([row], in: fixture.db) == [row])
    }

    // MARK: - Skipped

    /// An in-place profile swap holds the row, which is one of the claims a wake
    /// answers `.inFlight` to.
    @Test("a wake that finds another transition in flight counts as skipped")
    func inFlightWakeIsSkipped() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let control = try await park(in: fixture)
        let claimed = try await park(in: fixture)
        let coordinator = fixture.router.hibernationCoordinator
        let claim = await coordinator.claimSwap(terminalID: claimed)
        #expect(claim)

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)
        await coordinator.releaseSwap(terminalID: claimed)

        #expect(summary == SessionRestoreSummary(selected: 2, woken: 1, skipped: 1))
        #expect(try await awake([control, claimed], in: fixture.db) == [control])
    }

    /// The admission check is the one suspension between the pass's selection
    /// and the wake's read of the row, so the race lands there.
    @Test("a row the user woke first counts as skipped")
    func alreadyAwakeRowIsSkipped() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let control = try await park(in: fixture)
        let raced = try await park(in: fixture)
        let db = fixture.db
        fixture.router.startAdmission = ScriptedAdmission { request in
            if request.terminalID == raced { try? await db.terminals.clearHibernated(id: raced) }
            return .admit
        }
        try await fixture.db.config.setStartAdmissionEnabled(true)

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        #expect(summary == SessionRestoreSummary(selected: 2, woken: 1, skipped: 1))
        #expect(try await awake([control, raced], in: fixture.db) == [control, raced])
    }

    // MARK: - A row that stopped qualifying after selection

    /// Landing in the admission check puts the change after anything the pass
    /// could ask before it calls the handler, so only the wake's own read of the
    /// row can see it.
    @Test("a row parked again during its wake's admission check stays parked",
          arguments: [HibernateReason.manual, .exited])
    func rowReparkedDuringAdmissionIsSkipped(reason: HibernateReason) async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let control = try await park(in: fixture)
        let raced = try await park(in: fixture)
        let db = fixture.db
        fixture.router.startAdmission = ScriptedAdmission { request in
            if request.terminalID == raced { try? await Self.repark(raced, reason: reason, in: db) }
            return .admit
        }
        try await fixture.db.config.setStartAdmissionEnabled(true)

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        #expect(summary == SessionRestoreSummary(selected: 2, woken: 1, skipped: 1))
        #expect(try await awake([control, raced], in: fixture.db) == [control])
        let row = try #require(try await fixture.db.terminals.get(id: raced))
        #expect(row.hibernateReason == reason)
    }

    @Test("a row parked again during a gap stays parked, with the reason it was given",
          arguments: [HibernateReason.manual, .exited, .merged, .auto])
    func rowReparkedDuringAGapIsSkipped(reason: HibernateReason) async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let ids = try await parkRows(4, in: fixture)
        let pass = startPass(fixture)

        try await fixture.clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        try await Self.repark(ids[3], reason: reason, in: fixture.db)
        await fixture.clock.advance(by: Self.gap)

        let summary = await pass.value
        #expect(summary == SessionRestoreSummary(selected: 4, woken: 3, skipped: 1))
        #expect(try await awake(ids, in: fixture.db) == Set(ids.prefix(3)))
        let row = try #require(try await fixture.db.terminals.get(id: ids[3]))
        #expect(row.hibernateReason == reason)
    }

    /// An archive flips the worktree's status well before it deletes the
    /// worktree's rows, so the wake finds a parked row in an archived worktree.
    /// The row with no transcript is the last one the pass reaches.
    @Test("a row whose worktree is archived during a gap stays parked")
    func worktreeArchivedDuringAGapIsSkipped() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let ids = try await parkRows(3, in: fixture)
        let worktree = try await makeWorktree(in: fixture)
        let row = try await park(in: fixture, worktree: worktree)
        let pass = startPass(fixture)

        try await fixture.clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        try await fixture.db.worktrees.archive(id: worktree.id)
        await fixture.clock.advance(by: Self.gap)

        let summary = await pass.value
        #expect(summary == SessionRestoreSummary(selected: 4, woken: 3, skipped: 1))
        #expect(try await awake(ids + [row], in: fixture.db) == Set(ids))
    }

    @Test("a wake whose condition is not met starts nothing and changes nothing")
    func unmetConditionTouchesNothing() async throws {
        let recorded = RecordedTmuxArgs()
        let fixture = try await makeFixture(tmux: TmuxManager(
            dryRun: true, dryRunRecorder: { recorded.append($0) }))
        defer { fixture.cleanUp() }
        let row = try await park(in: fixture, reason: .manual)
        let before = try #require(try await fixture.db.terminals.get(id: row))

        let result = await fixture.router.hibernationCoordinator.wake(
            terminalID: row, condition: SessionRestoreCondition(parkedSince: Self.thisStartup))

        #expect(result == .conditionNotMet)
        #expect(recorded.snapshot().isEmpty, "the wake reached tmux: \(recorded.snapshot())")
        let after = try #require(try await fixture.db.terminals.get(id: row))
        #expect(after == before)
    }

    @Test("a wake naming no condition still wakes a row the pass would leave alone")
    func wakeWithNoConditionIsUnchanged() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let row = try await park(in: fixture, reason: .manual)

        let result = await fixture.router.hibernationCoordinator.wake(terminalID: row)

        #expect(result.isOk)
        #expect(try await awake([row], in: fixture.db) == [row])
    }

    // MARK: - Each wake is an ordinary wake

    @Test("each wake's actuation row names the session-restore rail and carries no prompt")
    func actuationRowsNameTheRail() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try await park(in: fixture)
        try await park(in: fixture)

        await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        let requests = try wakeRequests(at: fixture.logPath)
        #expect(requests.count == 2)
        for request in requests {
            let actor = try #require(request["actor"] as? [String: Any])
            #expect((actor["kind"] as? String) == ActuationActor.Kind.daemon)
            #expect((actor["rail"] as? String) == ActuationRail.sessionRestore)
            #expect((request["prompt"] as? String) == nil)
        }
    }

    /// A dry run records a size only where a wake recreates its window, so that
    /// is where a size the pass sent would show.
    @Test("a wake names no size, so a window it recreates takes the default")
    func wakeNamesNoSize() async throws {
        let recorded = RecordedTmuxArgs()
        let fixture = try await makeFixture(tmux: TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunWindowIsDead: { _ in true }))
        defer { fixture.cleanUp() }
        try await park(in: fixture)

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        #expect(summary == SessionRestoreSummary(selected: 1, woken: 1))
        let newSession = recorded.snapshot().first { $0.contains("new-session") }
        let args = try #require(newSession)
        let width = try #require(args.firstIndex(of: "-x"))
        let height = try #require(args.firstIndex(of: "-y"))
        #expect(args[width + 1] == String(TmuxManager.defaultCols))
        #expect(args[height + 1] == String(TmuxManager.defaultRows))
    }

    /// A fast-pass test cannot start a real holder. This registry has no spawner,
    /// so the wake gets as far as the fixture can state: the row was selected and
    /// its wake took the holder path to the spawn it then refused, reaching no
    /// tmux on the way.
    @Test("a holder row is selected and wakes on the holder path")
    func holderRowWakesOnTheHolderPath() async throws {
        let recorded = RecordedTmuxArgs()
        let fixture = try await makeFixture(tmux: TmuxManager(
            dryRun: true, dryRunRecorder: { recorded.append($0) }))
        defer { fixture.cleanUp() }
        let sessionID = "session-holder"
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: sessionID, kind: .claude,
            transport: .holder)
        try await fixture.db.terminals.setHibernated(
            id: terminal.id, sessionID: sessionID, reason: .recovery, at: Self.thisStartup)
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-sr-\(UUID().uuidString.prefix(8))"],
            listTerminals: { [terminal] })
        #expect(registry.canSpawn == false)
        await fixture.router.hibernationCoordinator.setHolderRegistry(registry)

        let summary = await fixture.router.restoreSessionsAfterStartup(parkedSince: Self.thisStartup)

        #expect(summary == SessionRestoreSummary(selected: 1, failed: 1))
        #expect(recorded.snapshot().isEmpty, "the holder wake reached tmux: \(recorded.snapshot())")
        let row = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(row.isParked)
        #expect(row.hibernateReason == .recovery)
    }

    @Test("a wake response classifies as woken, skipped, failed or held")
    func wakeResponseClassification() throws {
        let woken = try RPCResponse(result: TerminalWakeResult(woken: true))
        let noOp = try RPCResponse(result: TerminalWakeResult(woken: false))
        let held = RPCResponse(error: "held", code: RPCErrorCode.startHeld.rawValue)
        let failed = RPCResponse(error: "no worktree")
        let otherCode = RPCResponse(error: "gone", code: RPCErrorCode.profileMissing.rawValue)
        let noResult = RPCResponse.ok()

        #expect(RPCRouter.sessionRestoreOutcome(of: woken) == .woken)
        #expect(RPCRouter.sessionRestoreOutcome(of: noOp) == .skipped)
        #expect(RPCRouter.sessionRestoreOutcome(of: held) == .held)
        #expect(RPCRouter.sessionRestoreOutcome(of: failed) == .failed)
        #expect(RPCRouter.sessionRestoreOutcome(of: otherCode) == .failed)
        #expect(RPCRouter.sessionRestoreOutcome(of: noResult) == .failed)
    }

    // MARK: - The daemon's startup step

    @Test("the startup step runs the pass outside mock mode")
    func startupStepRunsThePass() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let row = try await park(in: fixture)

        let task = try #require(Daemon.startSessionRestore(
            mockMode: nil, router: fixture.router, parkedSince: Self.thisStartup))
        await task.value

        #expect(try await awake([row], in: fixture.db) == [row])
    }

    @Test("the startup step starts nothing in mock mode")
    func startupStepSkipsMockMode() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let row = try await park(in: fixture)

        let task = Daemon.startSessionRestore(
            mockMode: .enabled(fixturePath: "/tmp/does-not-exist.json"),
            router: fixture.router, parkedSince: Self.thisStartup)

        #expect(task == nil)
        #expect(try await awake([row], in: fixture.db).isEmpty)
    }
}
