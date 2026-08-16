import Foundation
import TestSupport
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// The filing sync — Task 7 of `docs/plans/2026-08-16-remote-lane-archive.md`,
/// spec §"The filing decision travels back".
///
/// Tier 1: in-memory GRDB, a fake provider invoker, and a real actuation log
/// in a temp directory. No subprocesses, no network, no `TBD_HOME`.
///
/// Every timestamp these tests care about is passed in explicitly. Nothing
/// sleeps: the rule under test is an ordering between two `Date`s, so wall
/// time would only make the assertions slower and flakier.
@Suite("Remote filing sync")
struct RemoteFilingSyncTests {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let dir: URL
    let registryURL: URL
    let logPath: String
    /// One repo for the whole suite: every fixture session reports the same
    /// `meta["repo"]`, and a second registration of the same remote would make
    /// that resolution ambiguous rather than more realistic.
    let repo: Repo

    init() async throws {
        db = try TBDDatabase(inMemory: true)
        subs = StateSubscriptionManager()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-filing-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dir = directory
        registryURL = directory.appendingPathComponent("agent-providers.json")
        try #"[{"name": "fake", "exec": "/nonexistent/fake"}]"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
        logPath = directory.appendingPathComponent("actuations.jsonl").path
        repo = try await db.repos.create(
            path: "/tmp/filing-sync-\(UUID().uuidString)", displayName: "api",
            defaultBranch: "main", remoteURL: "https://github.com/acme/api")
    }

    // MARK: - Fixtures

    private func describeDeclaring(_ capabilities: [String]) -> ProviderResult {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        return providerOK(#"{"contract_versions": [1], "name": "fake", "capabilities": [\#(caps)]}"#)
    }

    /// A manager whose cached `describe` declares `capabilities`, with a real
    /// actuation log wired in — the sync fails closed without one.
    private func manager(
        declaring capabilities: [String], runner: (any RemoteProviderInvoking)? = nil,
        log: ActuationLog? = nil
    ) async -> RemoteProviderManager {
        let invoker = runner ?? FakeProviderInvoker(script: [describeDeclaring(capabilities)])
        let m = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL,
            actuationLog: log ?? ActuationLog(path: logPath))
        await m.loadRegistryAndDescribe()
        return m
    }

    private func session(
        _ id: String, archived: Bool?, state: RemoteProcessState = .running,
        meta: [String: String]? = ["repo": "acme/api"]
    ) -> RemoteSessionPayload {
        RemoteSessionPayload(
            id: id, state: state, agentState: .working, meta: meta, archived: archived)
    }

    /// Adopts one session into a worktree row and returns it, using a payload
    /// that makes no `archived` claim so the adoption itself never files
    /// anything.
    private func adoptedRow(
        _ m: RemoteProviderManager, sessionID: String = "a"
    ) async throws -> Worktree {
        try await m.apply(snapshot: [session(sessionID, archived: nil)], provider: "fake")
        return try #require(
            try await db.worktrees.findRemote(provider: "fake", sessionID: sessionID))
    }

    private func status(_ id: UUID) async throws -> WorktreeStatus? {
        try await db.worktrees.get(id: id)?.status
    }

    private func mirrorState(_ sessionID: String) async throws -> String? {
        try await db.remoteSessions.list().first { $0.sessionID == sessionID }?.state
    }

    private func actuationRows() throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    // MARK: - Both directions flip, and neither touches `state`

    @Test("a provider reporting archived: true files the bound row, leaving state alone")
    func archivedTrueFilesTheRow() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let row = try await adoptedRow(m)
        #expect(try await status(row.id) == .active)

        try await m.apply(snapshot: [session("a", archived: true)], provider: "fake")

        #expect(try await status(row.id) == .archived)
        // Filing and liveness are separate axes: the mirror still reports the
        // session running, because the sync never writes `state`.
        #expect(try await mirrorState("a") == RemoteProcessState.running.rawValue)
    }

    @Test("a provider reporting archived: false returns the row, leaving state alone")
    func archivedFalseReturnsTheRow() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let row = try await adoptedRow(m)
        try await db.worktrees.archive(id: row.id)
        #expect(try await status(row.id) == .archived)

        try await m.apply(snapshot: [session("a", archived: false)], provider: "fake")

        #expect(try await status(row.id) == .active)
        #expect(try await mirrorState("a") == RemoteProcessState.running.rawValue)
    }

    // MARK: - Gate 1: the provider must declare `archive`

    /// Without this gate every provider with no archiving concept would carry
    /// an implicit "not archived" on each snapshot (the contract reads an
    /// absent field as `false`) and drag archived rows back into the active
    /// list about once a minute, forever. Both directions are exercised, so a
    /// sync that only ignored one of them still fails.
    @Test("a provider that does not declare archive moves no row, whatever it reports")
    func undeclaredArchiveCapabilityMovesNothing() async throws {
        let m = await manager(declaring: ["stop", "unarchive"])
        let active = try await adoptedRow(m, sessionID: "active-one")
        let filed = try await adoptedRow(m, sessionID: "filed-one")
        try await db.worktrees.archive(id: filed.id)

        try await m.apply(
            snapshot: [
                session("active-one", archived: true),
                session("filed-one", archived: false),
            ],
            provider: "fake")

        #expect(try await status(active.id) == .active)
        #expect(try await status(filed.id) == .archived)
        #expect(try actuationRows().isEmpty)
    }

    // MARK: - Gate 2: the field must be present

    /// Absent means no claim was made; explicit `false` is a claim. Display
    /// still reads absent as `false` — only the sync abstains.
    @Test("an absent archived field moves no row, while isArchived still reads false")
    func absentArchivedMovesNothingButStillDisplaysAsNotArchived() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let active = try await adoptedRow(m, sessionID: "active-one")
        let filed = try await adoptedRow(m, sessionID: "filed-one")
        try await db.worktrees.archive(id: filed.id)

        try await m.apply(
            snapshot: [
                session("active-one", archived: nil),
                session("filed-one", archived: nil),
            ],
            provider: "fake")

        #expect(try await status(active.id) == .active)
        #expect(try await status(filed.id) == .archived)
        #expect(try actuationRows().isEmpty)

        let mirrored = try await db.remoteSessions.list()
        #expect(mirrored.count == 2)
        for row in mirrored {
            let payload = try #require(row.decodedPayload)
            #expect(payload.archived == nil)
            #expect(payload.isArchived == false)
        }
    }

    // MARK: - A local row takes its status from TBD alone

    @Test("a local worktree is never moved by any provider report")
    func aLocalWorktreeIsNeverMoved() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let local = try await db.worktrees.create(
            repoID: repo.id, name: "local-lane", branch: "local-branch",
            path: "/tmp/local-lane-\(UUID().uuidString)", tmuxServer: "tbd-test")

        // The provider names the local row outright, echoing its id back the
        // way a TBD-created session does, and claims it is archived.
        try await m.apply(
            snapshot: [
                session(
                    "a", archived: true,
                    meta: ["repo": "acme/api", "tbd_worktree_id": local.id.uuidString])
            ],
            provider: "fake")

        #expect(try await status(local.id) == .active)
        // …and the run did move something, so a sync that moved nothing at
        // all cannot pass this by doing nothing.
        let adopted = try #require(try await db.worktrees.findRemote(provider: "fake", sessionID: "a"))
        #expect(adopted.id != local.id)
        #expect(try await status(adopted.id) == .archived)
    }

    // MARK: - The stale-snapshot watermark, both directions

    @Test("a response whose request began before a local archive does not reverse it")
    func staleResponseDoesNotUndoALocalArchive() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let row = try await adoptedRow(m)
        let requestStartedAt = Date(timeIntervalSince1970: 1_000)
        // The user archives while that `list` is still in flight.
        try await db.worktrees.archive(id: row.id)
        await m.noteFilingDecision(worktreeID: row.id, at: Date(timeIntervalSince1970: 1_001))

        try await m.apply(
            snapshot: [session("a", archived: false)], provider: "fake",
            now: Date(timeIntervalSince1970: 1_002), requestStartedAt: requestStartedAt)

        #expect(try await status(row.id) == .archived)
    }

    @Test("a response whose request began before a local revive does not re-file it")
    func staleResponseDoesNotUndoALocalRevive() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let row = try await adoptedRow(m)
        let requestStartedAt = Date(timeIntervalSince1970: 1_000)
        // The row is active because the user just revived it, mid-flight.
        await m.noteFilingDecision(worktreeID: row.id, at: Date(timeIntervalSince1970: 1_001))

        try await m.apply(
            snapshot: [session("a", archived: true)], provider: "fake",
            now: Date(timeIntervalSince1970: 1_002), requestStartedAt: requestStartedAt)

        #expect(try await status(row.id) == .active)
    }

    @Test("a response whose request began after the local decision does apply, both directions")
    func freshResponseAppliesInBothDirections() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let toFile = try await adoptedRow(m, sessionID: "to-file")
        let toReturn = try await adoptedRow(m, sessionID: "to-return")
        try await db.worktrees.archive(id: toReturn.id)
        await m.noteFilingDecision(worktreeID: toFile.id, at: Date(timeIntervalSince1970: 1_000))
        await m.noteFilingDecision(worktreeID: toReturn.id, at: Date(timeIntervalSince1970: 1_000))

        try await m.apply(
            snapshot: [
                session("to-file", archived: true),
                session("to-return", archived: false),
            ],
            provider: "fake",
            now: Date(timeIntervalSince1970: 1_002),
            requestStartedAt: Date(timeIntervalSince1970: 1_001))

        #expect(try await status(toFile.id) == .archived)
        #expect(try await status(toReturn.id) == .active)
    }

    /// `pollOnce` must stamp the request start BEFORE it asks the provider
    /// anything. The invoker files the row locally while its `list` call is
    /// still outstanding, so a manager that stamped arrival time instead
    /// would treat the decision as older than the response and hand the row
    /// straight back to the active list.
    @Test("pollOnce stamps the request start before invoking the provider")
    func pollOnceStampsRequestStartBeforeTheCall() async throws {
        let row = try await db.worktrees.createRemote(
            repoID: repo.id, name: "remote-a", branch: "b", provider: "fake", sessionID: "a")
        let invoker = MidCallFilingInvoker(
            script: [
                describeDeclaring(["archive", "unarchive"]),
                providerOK(#"{"sessions": [{"id": "a", "state": "running", "archived": false}]}"#),
            ])
        let m = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL,
            actuationLog: ActuationLog(path: logPath))
        await m.loadRegistryAndDescribe()
        invoker.onListCall = { [db] in
            try? await db.worktrees.archive(id: row.id)
            await m.noteFilingDecision(worktreeID: row.id, at: Date())
        }

        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))

        #expect(try await status(row.id) == .archived)
    }

    /// The rule is "no later than the request start", so the boundary belongs
    /// to the response: a decision taken at the very instant the request began
    /// is one that request could have accounted for. Both directions are here
    /// because the comparison is one line and a suite that only pinned the
    /// strict cases would survive swapping `>` for `>=`.
    @Test("a decision taken exactly at the request start does not suppress the flip")
    func watermarkBoundaryIsExclusiveAtEquality() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let toFile = try await adoptedRow(m, sessionID: "to-file")
        let toReturn = try await adoptedRow(m, sessionID: "to-return")
        try await db.worktrees.archive(id: toReturn.id)
        let boundary = Date(timeIntervalSince1970: 1_000)
        await m.noteFilingDecision(worktreeID: toFile.id, at: boundary)
        await m.noteFilingDecision(worktreeID: toReturn.id, at: boundary)

        try await m.apply(
            snapshot: [
                session("to-file", archived: true),
                session("to-return", archived: false),
            ],
            provider: "fake",
            now: Date(timeIntervalSince1970: 1_002), requestStartedAt: boundary)

        #expect(try await status(toFile.id) == .archived)
        #expect(try await status(toReturn.id) == .active)
    }

    /// One second the other side of the same boundary, so the pair pins the
    /// comparison rather than one of its arms.
    @Test("a decision taken one instant after the request start does suppress the flip")
    func watermarkBoundaryIsInclusiveOneInstantLater() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let row = try await adoptedRow(m)
        let boundary = Date(timeIntervalSince1970: 1_000)
        await m.noteFilingDecision(worktreeID: row.id, at: boundary.addingTimeInterval(0.001))

        try await m.apply(
            snapshot: [session("a", archived: true)], provider: "fake",
            now: Date(timeIntervalSince1970: 1_002), requestStartedAt: boundary)

        #expect(try await status(row.id) == .active)
    }

    // MARK: - Every write to a remote row's status is watermarked

    /// Not only the verb paths. A row filed by the sync itself — which is how
    /// a Provider-Desk `remote.archive` reaches the worktree row, since that
    /// handler never touches the row — must leave a watermark too, or a poll
    /// already in flight carrying the pre-archive `archived: false` un-files it
    /// moments later.
    @Test("a sync-driven archive is watermarked, and an in-flight poll cannot undo it")
    func syncDrivenArchiveIsWatermarked() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let row = try await adoptedRow(m)

        try await m.apply(
            snapshot: [session("a", archived: true)], provider: "fake",
            now: Date(timeIntervalSince1970: 2_000),
            requestStartedAt: Date(timeIntervalSince1970: 2_000))
        #expect(try await status(row.id) == .archived)
        #expect(await m.filingDecision(for: row.id) != nil, "the sync left no watermark")

        // A `list` launched before that decision lands afterwards, still
        // carrying the provider's pre-archive word.
        try await m.apply(
            snapshot: [session("a", archived: false)], provider: "fake",
            now: Date(timeIntervalSince1970: 2_002),
            requestStartedAt: Date(timeIntervalSince1970: 1_999))

        #expect(try await status(row.id) == .archived)
    }

    @Test("a sync-driven return to active is watermarked, and an in-flight poll cannot undo it")
    func syncDrivenReturnIsWatermarked() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let row = try await adoptedRow(m)
        try await db.worktrees.archive(id: row.id)

        try await m.apply(
            snapshot: [session("a", archived: false)], provider: "fake",
            now: Date(timeIntervalSince1970: 2_000),
            requestStartedAt: Date(timeIntervalSince1970: 2_000))
        #expect(try await status(row.id) == .active)
        #expect(await m.filingDecision(for: row.id) != nil, "the sync left no watermark")

        try await m.apply(
            snapshot: [session("a", archived: true)], provider: "fake",
            now: Date(timeIntervalSince1970: 2_002),
            requestStartedAt: Date(timeIntervalSince1970: 1_999))

        #expect(try await status(row.id) == .active)
    }

    // MARK: - Check-then-act across the suspensions

    /// The row and the watermark are read once, and then two awaits follow —
    /// the record append and the status write. A gesture landing in that
    /// window makes the decision stale before it is carried out, so the sync
    /// re-reads both and abandons rather than restating an act somebody else
    /// already performed.
    ///
    /// The interleave is exact rather than raced: the actuation log's own
    /// `write` syscall is the seam. It hands control to the racing gesture and
    /// blocks until that gesture has finished, so the sync always resumes into
    /// a world it has not looked at since it decided.
    @Test("a gesture landing mid-sync abandons the flip instead of restating it")
    func aGestureLandingMidSyncAbandonsTheFlip() async throws {
        let handshake = MidAppendHandshake()
        let log = ActuationLog(
            path: logPath, now: { Date() },
            syscalls: ActuationLogSyscalls(
                write: { descriptor, buffer, count in
                    handshake.pauseOnFirstWrite()
                    return Foundation.write(descriptor, buffer, count)
                },
                fsync: { Foundation.fsync($0) }))
        let m = await manager(declaring: ["archive", "unarchive"], log: log)
        let row = try await adoptedRow(m)

        // The user's own archive, waiting for the sync to reach its record.
        let gesture = Task { [db] in
            await handshake.awaitSyncAtRecord()
            try? await db.worktrees.archive(id: row.id)
            await m.noteFilingDecision(worktreeID: row.id, at: Date(timeIntervalSince1970: 3_000))
            handshake.releaseSync()
        }

        try await m.apply(
            snapshot: [session("a", archived: true)], provider: "fake",
            now: Date(timeIntervalSince1970: 2_001),
            requestStartedAt: Date(timeIntervalSince1970: 2_000))
        await gesture.value

        #expect(try await status(row.id) == .archived, "the user's own archive stands")
        // The gesture is the author of this filing, so nothing may say the
        // provider retired the session.
        #expect(try await db.notifications.unread(worktreeID: row.id).isEmpty)
        let rows = try actuationRows()
        let request = try #require(rows.first { $0["kind"] as? String == "dispose" })
        let requestID = try #require(request["id"] as? String)
        let outcome = try #require(rows.first { $0["confirms"] as? String == requestID })
        #expect(
            outcome["result"] as? String == "refused",
            "the sync carried out a decision that had gone stale: \(outcome)")
    }

    // MARK: - The two events paths

    /// A pushed `session` line is fresh by construction — the provider wrote it
    /// because something changed just now — so the sync takes its arrival as
    /// the request start and files the row.
    @Test("a pushed session line reporting archived: true files its row")
    func eventsPushedSessionFilesTheRow() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let row = try await adoptedRow(m)

        await m.applyUpsert(
            session("a", archived: true), provider: "fake",
            date: Date(timeIntervalSince1970: 5_000))

        #expect(try await status(row.id) == .archived)
        #expect(try await mirrorState("a") == RemoteProcessState.running.rawValue)
    }

    /// "Fresh by construction" is a claim about the line, not a licence to
    /// overwrite a decision taken after it arrived. The injected arrival date
    /// is what the watermark is compared against, so a decision stamped later
    /// than the line still wins — and the seam is what makes that assertable
    /// without wall time.
    @Test("a pushed session line does not reverse a decision taken after it arrived")
    func eventsPushedSessionRespectsALaterDecision() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let row = try await adoptedRow(m)
        try await db.worktrees.archive(id: row.id)
        await m.noteFilingDecision(worktreeID: row.id, at: Date(timeIntervalSince1970: 5_001))

        await m.applyUpsert(
            session("a", archived: false), provider: "fake",
            date: Date(timeIntervalSince1970: 5_000))

        #expect(try await status(row.id) == .archived)
    }

    /// The reconnect snapshot arm. The supervisor supplies the moment it opened
    /// the connection as the request start, because the provider composes that
    /// snapshot from what it knew when TBD asked — so a snapshot on a
    /// connection opened before a local decision cannot account for it, and one
    /// on a connection opened after it can.
    @Test("an events snapshot is judged by when its connection opened")
    func eventsSnapshotIsJudgedByConnectionOpenTime() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let stale = try await adoptedRow(m, sessionID: "stale-connection")
        let fresh = try await adoptedRow(m, sessionID: "fresh-connection")
        try await db.worktrees.archive(id: stale.id)
        try await db.worktrees.archive(id: fresh.id)
        await m.noteFilingDecision(worktreeID: stale.id, at: Date(timeIntervalSince1970: 6_000))
        await m.noteFilingDecision(worktreeID: fresh.id, at: Date(timeIntervalSince1970: 6_000))

        // One connection opened before both decisions, one after.
        try await m.apply(
            snapshot: [session("stale-connection", archived: false)], provider: "fake",
            now: Date(timeIntervalSince1970: 6_002),
            requestStartedAt: Date(timeIntervalSince1970: 5_999))
        try await m.apply(
            snapshot: [session("fresh-connection", archived: false)], provider: "fake",
            now: Date(timeIntervalSince1970: 6_003),
            requestStartedAt: Date(timeIntervalSince1970: 6_001))

        #expect(try await status(stale.id) == .archived)
        #expect(try await status(fresh.id) == .active)
    }

    /// The supervisor stamps that connection-open time through an injected date
    /// seam rather than a bare `Date()`, because the value is **compared**
    /// (Tests/CLAUDE.md, "Clock and date seams": `Duration` is behavior,
    /// `Date` is data).
    @Test("the events supervisor stamps its connection-open time through the date seam")
    func eventsSupervisorTakesADateSeam() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let fixed = Date(timeIntervalSince1970: 7_000)
        let supervisor = ProviderEventsSupervisor(
            config: RemoteProviderConfig(name: "fake", exec: "/nonexistent"), manager: m,
            now: { fixed })

        #expect(await supervisor.connectionOpenedAt == fixed)
    }

    // MARK: - The sweep

    @Test("the sweep drops watermarks older than two poll intervals")
    func sweepDropsStaleWatermarks() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let now = Date(timeIntervalSince1970: 10_000)
        let fresh = UUID()
        let stale = UUID()
        await m.noteFilingDecision(
            worktreeID: fresh, at: now.addingTimeInterval(-2 * RemoteProviderManager.pollInterval + 1))
        await m.noteFilingDecision(
            worktreeID: stale, at: now.addingTimeInterval(-2 * RemoteProviderManager.pollInterval - 1))

        try await m.apply(snapshot: [], provider: "fake", now: now, requestStartedAt: now)

        #expect(await m.filingDecision(for: fresh) != nil)
        #expect(await m.filingDecision(for: stale) == nil)
    }

    /// The cutoff itself is kept. A watermark exactly two poll intervals old is
    /// still older than nothing in flight, and pinning the boundary is what
    /// stops the comparison drifting between `>` and `>=` unnoticed.
    @Test("a watermark exactly at the sweep cutoff survives")
    func sweepKeepsTheWatermarkOnTheCutoff() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let now = Date(timeIntervalSince1970: 10_000)
        let onTheCutoff = UUID()
        await m.noteFilingDecision(
            worktreeID: onTheCutoff,
            at: now.addingTimeInterval(-2 * RemoteProviderManager.pollInterval))

        try await m.apply(snapshot: [], provider: "fake", now: now, requestStartedAt: now)

        #expect(await m.filingDecision(for: onTheCutoff) != nil)
    }

    // MARK: - Never silent

    @Test("a sync-driven archive writes a notification record and an actuation row")
    func syncDrivenArchiveIsNeverSilent() async throws {
        let m = await manager(declaring: ["archive", "unarchive"])
        let row = try await adoptedRow(m)

        try await m.apply(snapshot: [session("a", archived: true)], provider: "fake")

        let notifications = try await db.notifications.unread(worktreeID: row.id)
        #expect(notifications.count == 1)
        #expect(notifications.first?.message?.contains("Archived") == true)

        let rows = try actuationRows()
        let request = try #require(rows.first { $0["kind"] as? String == "dispose" })
        #expect((request["actor"] as? [String: Any])?["rail"] as? String == "remote-filing-sync")
        #expect((request["target"] as? [String: Any])?["worktree"] as? String == row.id.uuidString)
        #expect(request["method"] == nil)
        let requestID = try #require(request["id"] as? String)
        let outcome = try #require(rows.first { $0["confirms"] as? String == requestID })
        #expect(outcome["result"] as? String == "dispatched")
    }
}

/// Rendezvous between the filing sync — paused inside the actuation log's
/// first `write` syscall — and a gesture racing it. Two semaphores rather than
/// one: the gesture must not start before the sync has committed to its
/// decision, and the sync must not resume before the gesture has landed.
///
/// The blocking `wait` on the sync's side parks the actuation log's executor
/// thread, which is exactly the point; the gesture's side never blocks a
/// cooperative thread, since it waits on a global dispatch queue and resumes
/// through a continuation.
private final class MidAppendHandshake: @unchecked Sendable {
    private let syncReachedRecord = DispatchSemaphore(value: 0)
    private let gestureLanded = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var paused = false

    /// Called from the log's `write` syscall. Only the first append pauses:
    /// the outcome row is written after the decision has been re-confirmed and
    /// has nothing left to race.
    func pauseOnFirstWrite() {
        lock.lock()
        let alreadyPaused = paused
        paused = true
        lock.unlock()
        guard !alreadyPaused else { return }
        syncReachedRecord.signal()
        gestureLanded.wait()
    }

    func awaitSyncAtRecord() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { [syncReachedRecord] in
                syncReachedRecord.wait()
                continuation.resume()
            }
        }
    }

    func releaseSync() {
        gestureLanded.signal()
    }
}

/// A provider invoker that runs a caller-supplied action in the middle of its
/// `list` call — the only way to construct "a local filing decision made while
/// this request was outstanding" without sleeping.
private final class MidCallFilingInvoker: RemoteProviderInvoking, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [ProviderResult]
    /// Runs after `list` is asked for and before its result is returned.
    var onListCall: (@Sendable () async -> Void)?

    init(script: [ProviderResult]) {
        self.script = script
    }

    func run(
        _ config: RemoteProviderConfig, verb: [String], stdin: Data?, timeout: TimeInterval
    ) async throws -> ProviderResult {
        if verb.first == "list", let onListCall {
            await onListCall()
        }
        return pop()
    }

    private func pop() -> ProviderResult {
        lock.lock()
        defer { lock.unlock() }
        precondition(!script.isEmpty, "MidCallFilingInvoker script exhausted")
        return script.removeFirst()
    }
}
