import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1. v75 gives `terminal.activityState` its provenance columns and v76
/// gives `worktree` the outcome of its last PR lookup. Both migrations are
/// nullable-without-default on purpose, so the tests below assert two things
/// that are easy to lose: a pre-existing row survives with NULL provenance, and
/// a row with only *half* a triple reports no fact at all.
@Suite struct MigrationV75StateProvenanceTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    /// Which half of the triple a row carries. Neither combination is a fact.
    enum HalfTriple: Sendable {
        case sourceOnly
        case observedAtOnly
        case neither
    }

    private func makeTerminal(_ db: TBDDatabase) async throws -> Terminal {
        let repo = try await db.repos.create(
            path: "/tmp/v75-repo-\(UUID().uuidString)", displayName: "V75", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v75-wt-\(UUID().uuidString)", tmuxServer: "tbd-v75")
        return try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "s-1", kind: .claude)
    }

    // MARK: - Schema

    @Test func provenanceColumnsExist() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { dbConn in
            let terminalCols = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(terminal)")
                .compactMap { $0["name"] as String? }
            #expect(terminalCols.contains("activityStateSource"))
            #expect(terminalCols.contains("activityStateObservedAt"))
            #expect(terminalCols.contains("awaitingInputReason"))
            #expect(terminalCols.contains("awaitingInputObservedAt"))

            let worktreeCols = try Row.fetchAll(dbConn, sql: "PRAGMA table_info(worktree)")
                .compactMap { $0["name"] as String? }
            #expect(worktreeCols.contains("prObservation"))
        }
    }

    /// Seeds a DB migrated only through v74, inserts real repo/worktree/terminal
    /// rows, then applies v75 and v76: the rows survive, and their new columns
    /// read NULL rather than a manufactured default.
    @Test func forwardMigrationPreservesExistingRows() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "v74_worktree_pending_prompt")

        let repoID = "55555555-5555-5555-5555-555555555555"
        let wtID = "66666666-6666-6666-6666-666666666666"
        let terminalID = "77777777-7777-7777-7777-777777777777"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/v75-pre-repo', 'V75', 'main', ?)
                """, arguments: [repoID, epoch])
            try db.execute(sql: """
                INSERT INTO worktree (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer)
                VALUES (?, ?, 'w', 'w', 'main', '/tmp/v75-pre-wt', 'active', ?, 'tbd-v75')
                """, arguments: [wtID, repoID, epoch])
            try db.execute(sql: """
                INSERT INTO terminal (id, worktreeID, tmuxWindowID, tmuxPaneID, createdAt, activityState)
                VALUES (?, ?, '@9', '%9', ?, 'working')
                """, arguments: [terminalID, wtID, epoch])
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let terminals = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM terminal WHERE id = ?", arguments: [terminalID]) ?? -1
            #expect(terminals == 1, "pre-existing terminal row must survive v75")
            let row = try Row.fetchOne(db, sql: "SELECT * FROM terminal WHERE id = ?",
                                       arguments: [terminalID])
            #expect(row?["activityState"] == "working")
            #expect(row?["activityStateSource"] == nil)
            #expect(row?["activityStateObservedAt"] == nil)
            #expect(row?["awaitingInputReason"] == nil)
            #expect(row?["awaitingInputObservedAt"] == nil)

            let worktrees = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM worktree WHERE id = ?", arguments: [wtID]) ?? -1
            #expect(worktrees == 1, "pre-existing worktree row must survive v76")
            let wtRow = try Row.fetchOne(db, sql: "SELECT * FROM worktree WHERE id = ?",
                                         arguments: [wtID])
            #expect(wtRow?["prObservation"] == nil)
        }
    }

    // MARK: - The triple, through the store

    @Test func setActivityStateStoresTheWholeTriple() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)

        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working,
            source: .hookEvent("UserPromptSubmit"), observedAt: epoch)

        let stored = try #require(try await db.terminals.get(id: terminal.id))
        #expect(stored.activityState == .working)
        #expect(stored.activityStateSource == .hookEvent("UserPromptSubmit"))
        #expect(stored.activityStateObservedAt == epoch)

        let fact = try #require(stored.observedActivity)
        #expect(fact.value == .working)
        #expect(fact.source == .hookEvent("UserPromptSubmit"))
        #expect(fact.observedAt == epoch)
    }

    /// The reason rides with the observation it belongs to, and the next
    /// observation supersedes it — a stale "needs your permission" must not
    /// outlive the wait it described.
    @Test func awaitingInputReasonRidesAndIsSuperseded() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        let reason = AwaitingInputReason(
            message: "Claude needs your permission to use Bash",
            hookEventName: "Notification",
            raw: #"{"hook_event_name":"Notification"}"#)

        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .waitingForUser,
            source: .hookEvent("Notification"), observedAt: epoch,
            awaitingInputReason: reason)

        let waiting = try #require(try await db.terminals.get(id: terminal.id))
        #expect(waiting.awaitingInputReason == reason)
        #expect(waiting.awaitingInputObservedAt == epoch)

        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working,
            source: .hookEvent("UserPromptSubmit"), observedAt: epoch.addingTimeInterval(60))

        let working = try #require(try await db.terminals.get(id: terminal.id))
        #expect(working.awaitingInputReason == nil)
        #expect(working.awaitingInputObservedAt == nil)
    }

    /// Half a triple is not a fact. A row carrying a value but no source (or no
    /// observed-at) must report nil rather than let a bare enumeration
    /// masquerade as an observation.
    @Test(arguments: [HalfTriple.sourceOnly, .observedAtOnly, .neither])
    func observedActivityIsNilWhenEitherHalfIsMissing(half: HalfTriple) async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)

        let sourceJSON = half == .sourceOnly
            ? String(data: try JSONEncoder().encode(FactSource.derived), encoding: .utf8)
            : nil
        let observedAt: Date? = half == .observedAtOnly ? epoch : nil
        try await db.writerForTests.write { dbConn in
            try dbConn.execute(
                sql: """
                    UPDATE terminal
                    SET activityState = 'working',
                        activityStateSource = ?,
                        activityStateObservedAt = ?
                    WHERE id = ?
                    """,
                arguments: [sourceJSON, observedAt, terminal.id.uuidString])
        }

        let stored = try #require(try await db.terminals.get(id: terminal.id))
        #expect(stored.activityState == .working)
        #expect(stored.observedActivity == nil)
    }

    /// A row written by a daemon that predates the columns loads fine and
    /// carries no fact.
    @Test func legacyRowLoadsWithNoProvenance() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v75-legacy-repo-\(UUID().uuidString)", displayName: "V75",
            defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v75-legacy-wt-\(UUID().uuidString)", tmuxServer: "tbd-v75")

        let id = UUID()
        try await db.writerForTests.write { dbConn in
            try dbConn.execute(
                sql: """
                    INSERT INTO terminal (id, worktreeID, tmuxWindowID, tmuxPaneID, createdAt, activityState)
                    VALUES (?, ?, '@9', '%9', ?, 'idle')
                    """,
                arguments: [id.uuidString, wt.id.uuidString, epoch])
        }

        let legacy = try #require(try await db.terminals.get(id: id))
        #expect(legacy.activityState == .idle)
        #expect(legacy.activityStateSource == nil)
        #expect(legacy.observedActivity == nil)
    }

    /// Parking writes an activity state, so it must stamp provenance like every
    /// other writer — and it clears any carried wait reason with it.
    @Test func parkingStampsProvenance() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .waitingForUser,
            source: .hookEvent("Notification"), observedAt: epoch,
            awaitingInputReason: AwaitingInputReason(message: "permission?"))

        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "s-1", reason: .manual, at: epoch.addingTimeInterval(120))

        let parked = try #require(try await db.terminals.get(id: terminal.id))
        #expect(parked.activityState == .idle)
        #expect(parked.activityStateSource == .database)
        #expect(parked.activityStateObservedAt == epoch.addingTimeInterval(120))
        #expect(parked.awaitingInputReason == nil)
        let fact = try #require(parked.observedActivity)
        #expect(fact.value == .idle)
    }

    @Test func recreatingAWindowStampsDerivedProvenance() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working,
            source: .hookEvent("UserPromptSubmit"), observedAt: epoch)
        _ = try await db.terminals.applySessionStart(
            id: terminal.id,
            sessionID: "session-before-recreation",
            transcriptPath: "/tmp/session-before-recreation.jsonl",
            observedAt: epoch.addingTimeInterval(10))

        try await db.terminals.clearRecreated(id: terminal.id, at: epoch.addingTimeInterval(30))

        let recreated = try #require(try await db.terminals.get(id: terminal.id))
        #expect(recreated.sessionOrderObservedAt == nil)
        #expect(recreated.activityState == .unknown)
        #expect(recreated.activityStateSource == .derived)
        #expect(recreated.activityStateObservedAt == epoch.addingTimeInterval(30))
    }

    /// Legacy `Terminal` JSON (an older app or daemon over RPC) still decodes,
    /// with no provenance and therefore no fact.
    @Test func legacyTerminalJSONDecodes() throws {
        let json = """
            {
                "id": "\(UUID().uuidString)",
                "worktreeID": "\(UUID().uuidString)",
                "tmuxWindowID": "@1",
                "tmuxPaneID": "%1",
                "createdAt": 0,
                "activityState": "working"
            }
            """
        let terminal = try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
        #expect(terminal.activityState == .working)
        #expect(terminal.activityStateSource == nil)
        #expect(terminal.activityStateObservedAt == nil)
        #expect(terminal.awaitingInputReason == nil)
        #expect(terminal.observedActivity == nil)
    }

    @Test func terminalProvenanceSurvivesJSONRoundTrip() throws {
        let original = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            activityState: .waitingForUser,
            activityStateSource: .hookEvent("Notification"),
            activityStateObservedAt: epoch,
            awaitingInputReason: AwaitingInputReason(
                message: "permission?", hookEventName: "Notification"),
            awaitingInputObservedAt: epoch)
        let decoded = try JSONDecoder().decode(
            Terminal.self, from: JSONEncoder().encode(original))

        #expect(decoded.activityStateSource == .hookEvent("Notification"))
        #expect(decoded.awaitingInputReason?.message == "permission?")
        let fact = try #require(decoded.observedActivity)
        #expect(fact.summary.contains("hook:Notification"))
    }

    // MARK: - PR observation

    @Test(arguments: [
        PRObservation.Outcome.observed,
        .none,
        .undetermined(cause: "network unreachable")
    ])
    func prObservationRoundTripsThroughTheDB(outcome: PRObservation.Outcome) async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v76-repo-\(UUID().uuidString)", displayName: "V76", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v76-wt-\(UUID().uuidString)", tmuxServer: "tbd-v76")

        let observation = PRObservation(outcome: outcome, observedAt: epoch)
        try await db.worktrees.setPRObservation(id: wt.id, observation: observation)

        let stored = try #require(try await db.worktrees.get(id: wt.id))
        #expect(stored.prObservation == observation)
    }

    /// "The forge answered; no PR" and "we could not find out" must stay
    /// different facts after a trip through the database — the whole reason the
    /// column exists beside `prStatus`.
    @Test func noneAndUndeterminedStayDistinctInTheDB() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v76-distinct-repo-\(UUID().uuidString)", displayName: "V76",
            defaultBranch: "main")
        let answeredWT = try await db.worktrees.create(
            repoID: repo.id, name: "a", branch: "a",
            path: "/tmp/v76-a-\(UUID().uuidString)", tmuxServer: "tbd-v76")
        let failedWT = try await db.worktrees.create(
            repoID: repo.id, name: "b", branch: "b",
            path: "/tmp/v76-b-\(UUID().uuidString)", tmuxServer: "tbd-v76")

        try await db.worktrees.setPRObservation(
            id: answeredWT.id, observation: PRObservation(outcome: .none, observedAt: epoch))
        try await db.worktrees.setPRObservation(
            id: failedWT.id,
            observation: PRObservation(
                outcome: .undetermined(cause: "network unreachable"), observedAt: epoch))

        let answered = try #require(try await db.worktrees.get(id: answeredWT.id))
        let failed = try #require(try await db.worktrees.get(id: failedWT.id))
        #expect(answered.prObservation?.outcome == PRObservation.Outcome.none)
        #expect(failed.prObservation?.outcome == .undetermined(cause: "network unreachable"))
        #expect(answered.prObservation != failed.prObservation)
    }

    /// A worktree with no recorded attempt is a third state again: not `.none`,
    /// not `.undetermined`, but nothing on record.
    @Test func noRecordedAttemptReadsAsNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/v76-none-repo-\(UUID().uuidString)", displayName: "V76",
            defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v76-none-wt-\(UUID().uuidString)", tmuxServer: "tbd-v76")

        let stored = try #require(try await db.worktrees.get(id: wt.id))
        #expect(stored.prObservation == nil)
    }

    /// Legacy `Worktree` JSON still decodes, and `PRStatus` gains its
    /// `observedAt` inside the existing blob — no migration involved.
    @Test func legacyWorktreeJSONDecodesAndPRStatusCarriesObservedAt() throws {
        let json = """
            {
                "id": "\(UUID().uuidString)",
                "name": "w",
                "displayName": "w",
                "branch": "b",
                "path": "/tmp/w",
                "status": "active",
                "createdAt": 0,
                "tmuxServer": "tbd-x",
                "prStatus": {
                    "number": 7,
                    "url": "https://example.test/pr/7",
                    "state": "mergeable"
                }
            }
            """
        let worktree = try JSONDecoder().decode(Worktree.self, from: Data(json.utf8))
        #expect(worktree.prObservation == nil)
        #expect(worktree.prStatus?.number == 7)
        #expect(worktree.prStatus?.observedAt == nil)

        let stamped = PRStatus(
            number: 7, url: "https://example.test/pr/7", state: .mergeable, observedAt: epoch)
        let decoded = try JSONDecoder().decode(PRStatus.self, from: JSONEncoder().encode(stamped))
        #expect(decoded.observedAt == epoch)
    }
}
