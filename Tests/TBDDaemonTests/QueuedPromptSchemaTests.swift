import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

/// Schema-level guards for the queued-prompt feature
/// (`docs/specs/2026-08-10-queued-prompt-on-create-design.md`).
///
/// The whole reason this suite exists is the tri-state on
/// `config.queued_prompt_enabled`: unlike every boolean flag before it, that
/// column is added with **no SQL default**, so "never chose" (NULL) stays
/// distinguishable from "explicitly off" (0). If someone re-adds
/// `defaults: false` to `v73_config_queued_prompt`, `queuedPromptEnabledIsNullBeforeAnyGesture`
/// goes red — that is its only job.
@Suite("QueuedPromptSchema")
struct QueuedPromptSchemaTests {

    private func fetchConfigRecord(_ db: TBDDatabase) async throws -> ConfigRecord? {
        try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)
        }
    }

    // MARK: - v73: the flag is genuinely NULL until somebody touches the toggle

    /// **The load-bearing test.** The `config` singleton row is inserted by v1,
    /// so every install — fresh or years old — has a row that predates v73.
    /// After v73 that row's `queued_prompt_enabled` must read NULL, not `0`.
    /// A SQL default would backfill it to `0` and make "never chose"
    /// indistinguishable from a deliberate opt-out, which is exactly what the
    /// no-default convention exists to prevent.
    @Test func queuedPromptEnabledIsNullBeforeAnyGesture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let record = try #require(try await fetchConfigRecord(db))
        #expect(
            record.queued_prompt_enabled == nil,
            """
            config.queued_prompt_enabled must be NULL until the toggle is \
            touched — read back \(String(describing: record.queued_prompt_enabled)). \
            A non-nil value here means v73_config_queued_prompt grew a \
            `defaults:` argument; remove it.
            """
        )
    }

    /// The same guard against a row written by a real pre-v73 daemon: migrate
    /// only through v69, write to the config row, then finish migrating.
    @Test func rowWrittenBeforeV70StillReadsNull() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "v69_config_delivery_verification")

        // A pre-v73 daemon touching config: the row exists and has been
        // written to, but knows nothing about the new column.
        try queue.write { db in
            try db.execute(
                sql: "UPDATE config SET delivery_verification_enabled = 1 WHERE id = ?",
                arguments: [ConfigStore.singletonID]
            )
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM config WHERE id = ?",
                arguments: [ConfigStore.singletonID]))
            let raw: DatabaseValue = row["queued_prompt_enabled"]
            #expect(
                raw.isNull,
                "a config row written before v73 must read NULL, not \(raw)"
            )
            // The pre-existing write survived — v73 is purely additive.
            #expect(row["delivery_verification_enabled"] == true)
        }
    }

    // MARK: - The three states are distinguishable

    /// NULL follows `Config.queuedPromptDefault` wherever it goes; an explicit
    /// `false` does not. This is the property that makes graduation a one-line
    /// constant change with no forcing `UPDATE` migration.
    @Test func explicitFalseSurvivesADefaultFlipWhileNullFollowsIt() async throws {
        let db = try TBDDatabase(inMemory: true)

        let untouched = try #require(try await fetchConfigRecord(db))
        #expect(untouched.queued_prompt_enabled == nil)
        #expect(untouched.toModel(queuedPromptDefault: false).queuedPromptEnabled == false)
        #expect(
            untouched.toModel(queuedPromptDefault: true).queuedPromptEnabled == true,
            "a never-chosen row must pick up a changed shipped default"
        )

        try await db.config.setQueuedPrompt(false)
        let explicitlyOff = try #require(try await fetchConfigRecord(db))
        #expect(explicitlyOff.queued_prompt_enabled == false)
        #expect(explicitlyOff.toModel(queuedPromptDefault: false).queuedPromptEnabled == false)
        #expect(
            explicitlyOff.toModel(queuedPromptDefault: true).queuedPromptEnabled == false,
            "an explicit opt-out must be honored forever, whatever the shipped default becomes"
        )
    }

    /// The shipped default today. Graduation edits this constant and nothing else.
    @Test func shippedDefaultIsOff() async throws {
        #expect(Config.queuedPromptDefault == false)
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().queuedPromptEnabled == false)
    }

    @Test func setQueuedPromptRoundtrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setQueuedPrompt(true)
        #expect(try await db.config.get().queuedPromptEnabled == true)
        try await db.config.setQueuedPrompt(false)
        #expect(try await db.config.get().queuedPromptEnabled == false)
    }
}

/// `v74_worktree_pending_prompt` — the parked text and its submit bit.
///
/// Unlike the flag above, `pending_prompt_submit` is *data*, not a feature
/// gate: there is no third "nobody chose" state worth preserving, so a SQL
/// default is correct there. What an absent bit means is settled in exactly one
/// place — `Worktree.pendingPromptSubmitResolved` — and it means "do not press
/// Enter".
@Suite("QueuedPromptWorktreeStore")
struct QueuedPromptWorktreeStoreTests {

    private func makeWorktree(_ db: TBDDatabase) async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/v74-\(UUID())", displayName: "v74", defaultBranch: "main")
        return try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/v74-wt-\(UUID())", tmuxServer: "srv")
    }

    @Test func pendingPromptDefaultsToNothingParked() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        let fetched = try #require(try await db.worktrees.get(id: wt.id))
        #expect(fetched.pendingPrompt == nil)
    }

    @Test func setPendingPromptRoundTripsThroughTheModel() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)

        try await db.worktrees.setPendingPrompt(
            worktreeID: wt.id, text: "fix the flaky test\nthen open a PR", submit: false)

        let fetched = try #require(try await db.worktrees.get(id: wt.id))
        #expect(fetched.pendingPrompt == "fix the flaky test\nthen open a PR")
        #expect(fetched.pendingPromptSubmit == false)
    }

    /// A second parked prompt replaces the first (spec: not a queue).
    @Test func parkingASecondPromptReplacesTheFirst() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)

        try await db.worktrees.setPendingPrompt(worktreeID: wt.id, text: "first", submit: true)
        try await db.worktrees.setPendingPrompt(worktreeID: wt.id, text: "second", submit: false)

        let fetched = try #require(try await db.worktrees.get(id: wt.id))
        #expect(fetched.pendingPrompt == "second")
        #expect(fetched.pendingPromptSubmit == false)
    }

    /// Passing `nil` unparks without delivering — the modal's Escape path and
    /// the recovery UI's "discard" both need it.
    @Test func setPendingPromptNilClearsTheColumn() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        try await db.worktrees.setPendingPrompt(worktreeID: wt.id, text: "x", submit: true)
        try await db.worktrees.setPendingPrompt(worktreeID: wt.id, text: nil, submit: true)
        #expect(try await db.worktrees.get(id: wt.id)?.pendingPrompt == nil)
    }

    /// The delivery reads the text, suspends through the settle and the send,
    /// and comes back to clear. A park can land anywhere in that suspension, so
    /// the clear names the text it delivered: it must remove that and nothing
    /// else.
    @Test func clearOnlyFiresWhenTheColumnStillHoldsTheDeliveredText() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        try await db.worktrees.setPendingPrompt(worktreeID: wt.id, text: "second", submit: true)

        // What a cycle that delivered "first" asks for, after "second" landed.
        let cleared = try await db.worktrees.clearPendingPrompt(
            worktreeID: wt.id, ifTextIs: "first", submit: true)

        #expect(cleared == false)
        let fetched = try #require(try await db.worktrees.get(id: wt.id))
        #expect(fetched.pendingPrompt == "second")
    }

    @Test func clearFiresWhenTheColumnStillHoldsTheDeliveredText() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        try await db.worktrees.setPendingPrompt(worktreeID: wt.id, text: "first", submit: true)

        #expect(try await db.worktrees.clearPendingPrompt(
            worktreeID: wt.id, ifTextIs: "first", submit: true) == true)
        let fetched = try #require(try await db.worktrees.get(id: wt.id))
        #expect(fetched.pendingPrompt == nil)
    }

    /// Re-parking the same words with the box unticked is a different prompt —
    /// staged in the composer rather than sent — so a clear that named the
    /// delivered *submitted* one must not consume it.
    @Test func clearDoesNotFireWhenOnlyTheSubmitBitChanged() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        try await db.worktrees.setPendingPrompt(worktreeID: wt.id, text: "same words", submit: false)

        #expect(try await db.worktrees.clearPendingPrompt(
            worktreeID: wt.id, ifTextIs: "same words", submit: true) == false)
        let fetched = try #require(try await db.worktrees.get(id: wt.id))
        #expect(fetched.pendingPrompt == "same words")
        #expect(fetched.pendingPromptSubmit == false)
    }

    /// Ten concurrent clears of the same text, and exactly one may report
    /// having done it. The compare-and-swap is one statement, and the boolean
    /// it answers is what the coordinator uses to decide it delivered — two
    /// winners would be two callers each believing they owned the delivery.
    @Test func concurrentClearsWinExactlyOnce() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db)
        try await db.worktrees.setPendingPrompt(worktreeID: wt.id, text: "once", submit: true)

        let winners = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await db.worktrees.clearPendingPrompt(
                        worktreeID: wt.id, ifTextIs: "once", submit: true)
                }
            }
            var count = 0
            for try await won in group where won { count += 1 }
            return count
        }
        #expect(winners == 1, "the compare-and-swap must be atomic; \(winners) callers won")
        #expect(try await db.worktrees.get(id: wt.id)?.pendingPrompt == nil)
    }

    /// A worktree row written before v74 decodes with both fields absent —
    /// nothing parked, and the model still round-trips.
    @Test func rowWrittenBeforeV71DecodesWithNothingParked() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: "v69_config_delivery_verification")

        let repoID = "55555555-5555-5555-5555-555555555555"
        let wtID = "66666666-6666-6666-6666-666666666666"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
                VALUES (?, '/tmp/v74-pre-repo', 'V71', 'main', ?)
                """, arguments: [repoID, Date()])
            try db.execute(sql: """
                INSERT INTO worktree (id, repoID, name, displayName, branch, path,
                                      status, createdAt, tmuxServer)
                VALUES (?, ?, 'w', 'w', 'main', '/tmp/v74-pre-wt', 'active', ?, 'tbd-v74')
                """, arguments: [wtID, repoID, Date()])
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let record = try #require(try WorktreeRecord.fetchOne(db, key: wtID))
            #expect(record.pending_prompt == nil)
            let model = try #require(record.toModel())
            #expect(model.pendingPrompt == nil)
            // `pending_prompt_submit` IS data, not a feature gate, so its SQL
            // default is correct — and the backfill it performs here is inert,
            // because the row it lands on has nothing parked and therefore no
            // submit choice to remember. `setPendingPrompt` always names both
            // columns.
            #expect(record.pending_prompt_submit == true)
            #expect(model.pendingPromptSubmit == true)
        }
    }

    /// The Codable model tolerates JSON from a daemon that predates v74.
    @Test func modelDecodesJSONWithoutTheNewKeys() throws {
        let json = """
        {"id":"77777777-7777-7777-7777-777777777777","name":"w","displayName":"w",
         "branch":"b","path":"/tmp/x","status":"active",
         "createdAt":0,"tmuxServer":"srv"}
        """
        let wt = try JSONDecoder().decode(Worktree.self, from: Data(json.utf8))
        #expect(wt.pendingPrompt == nil)
        #expect(wt.pendingPromptSubmit == nil)
    }

    @Test func modelRoundTripsThroughJSON() throws {
        var wt = Worktree(
            repoID: UUID(), name: "w", displayName: "w", branch: "b",
            path: "/tmp/x", tmuxServer: "srv")
        wt.pendingPrompt = "line one\nline two \"quoted\""
        wt.pendingPromptSubmit = false
        let data = try JSONEncoder().encode(wt)
        let decoded = try JSONDecoder().decode(Worktree.self, from: data)
        #expect(decoded.pendingPrompt == "line one\nline two \"quoted\"")
        #expect(decoded.pendingPromptSubmit == false)
    }
}
