import Foundation
import Testing
@testable import TBDDaemonLib

// Tier 2: in-memory GRDB only.
@Suite("ClaudeCloudLedgerStore")
struct ClaudeCloudLedgerStoreTests {
    @Test func aPendingRowIsWrittenBeforeTheInvocationAndReadBack() async throws {
        let db = try TBDDatabase(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let row = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "acme/api", repoPath: "/tmp/api",
            branch: "fix-ci", environment: "staging", paramsJSON: #"{"prompt":"hi"}"#, now: now)
        #expect(row.state == ClaudeCloudLedgerState.pending.rawValue)
        #expect(row.sessionID == nil)
        #expect(row.title == nil)
        #expect(row.archived == false)
        let all = try await db.claudeCloudSessions.rows()
        #expect(all.map(\.idempotencyKey) == ["tbd-1"])
        let stored = try #require(all.first)
        // `id` is a generated UUID, not asserted against a literal — only that
        // the write and read paths agree on it.
        #expect(stored.id == row.id)
        #expect(stored.idempotencyKey == "tbd-1")
        #expect(stored.state == ClaudeCloudLedgerState.pending.rawValue)
        // Not yet resolved: a create's output has not been read at this point
        // in the lifecycle, so both are expected nil rather than skipped.
        #expect(stored.sessionID == nil)
        #expect(stored.title == nil)
        #expect(stored.createdAt == now)
        #expect(stored.resolvedAt == nil)
        #expect(stored.repoKey == "acme/api")
        #expect(stored.repoPath == "/tmp/api")
        #expect(stored.branch == "fix-ci")
        #expect(stored.environment == "staging")
        // The column this table exists to carry — a dropped or truncated
        // paramsJSON is the failure this row would otherwise never catch.
        #expect(stored.paramsJSON == #"{"prompt":"hi"}"#)
        #expect(stored.archived == false)
    }

    /// The daemon retries a timed-out create ONCE with the same key. A pending
    /// row is expected during that retry, not a reason to refuse it — and the
    /// original creation time must survive, because the failure window is
    /// measured from the create, not from the retry.
    @Test func theSameKeyTwiceYieldsOneRowWithItsOriginalTimestamp() async throws {
        let db = try TBDDatabase(inMemory: true)
        let first = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "acme/api", repoPath: "/tmp/api",
            branch: nil, environment: nil, paramsJSON: "{}",
            now: Date(timeIntervalSince1970: 10))
        let second = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "acme/api", repoPath: "/tmp/api",
            branch: nil, environment: nil, paramsJSON: "{}",
            now: Date(timeIntervalSince1970: 20))
        #expect(first.id == second.id)
        #expect(second.createdAt == Date(timeIntervalSince1970: 10))
        #expect(try await db.claudeCloudSessions.rows().count == 1)
    }

    @Test func distinctKeysYieldDistinctRowsOrderedByCreation() async throws {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-2", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 200))
        _ = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 100))
        #expect(try await db.claudeCloudSessions.rows().map(\.idempotencyKey) == ["tbd-1", "tbd-2"])
    }

    @Test func resolveStampsTheSessionIDAndTitleAndFlipsTheState() async throws {
        let db = try TBDDatabase(inMemory: true)
        let row = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "a/b", repoPath: "/a", branch: "fix",
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 1))
        try await db.claudeCloudSessions.resolve(
            id: row.id, sessionID: "session_01AAA", title: "Add probe pong reply",
            now: Date(timeIntervalSince1970: 2))
        let stored = try #require(try await db.claudeCloudSessions.rows().first)
        #expect(stored.state == ClaudeCloudLedgerState.resolved.rawValue)
        #expect(stored.sessionID == "session_01AAA")
        #expect(stored.title == "Add probe pong reply")
        #expect(stored.resolvedAt == Date(timeIntervalSince1970: 2))
        // Neighbouring columns a naive UPDATE could clobber must survive.
        #expect(stored.repoKey == "a/b")
        #expect(stored.repoPath == "/a")
        #expect(stored.branch == "fix")
        #expect(stored.createdAt == Date(timeIntervalSince1970: 1))
    }

    /// A title parse that found nothing is not a failure — the row resolves
    /// with a null title and the lane is named from its id instead.
    @Test func resolveAcceptsANilTitleWithoutFailingTheCreate() async throws {
        let db = try TBDDatabase(inMemory: true)
        let row = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 1))
        try await db.claudeCloudSessions.resolve(
            id: row.id, sessionID: "session_01AAA", title: nil,
            now: Date(timeIntervalSince1970: 2))
        let stored = try #require(try await db.claudeCloudSessions.rows().first)
        #expect(stored.state == ClaudeCloudLedgerState.resolved.rawValue)
        #expect(stored.title == nil)
    }

    /// Resolving a row that does not exist is reachable on a retry path and
    /// must not throw — there is nothing to update, so it is a silent no-op.
    @Test func resolvingAnUnknownIDIsANoOp() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.claudeCloudSessions.resolve(
            id: "does-not-exist", sessionID: "session_01AAA", title: "x",
            now: Date(timeIntervalSince1970: 2))
        #expect(try await db.claudeCloudSessions.rows().isEmpty)
    }

    /// A retry may resolve the same row twice; the second call must remain a
    /// harmless overwrite rather than erroring or double-applying anything.
    @Test func resolvingTheSameRowTwiceIsIdempotent() async throws {
        let db = try TBDDatabase(inMemory: true)
        let row = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 1))
        try await db.claudeCloudSessions.resolve(
            id: row.id, sessionID: "session_01AAA", title: "first",
            now: Date(timeIntervalSince1970: 2))
        try await db.claudeCloudSessions.resolve(
            id: row.id, sessionID: "session_01AAA", title: "second",
            now: Date(timeIntervalSince1970: 3))
        let stored = try #require(try await db.claudeCloudSessions.rows().first)
        #expect(stored.state == ClaudeCloudLedgerState.resolved.rawValue)
        #expect(stored.title == "second")
        #expect(stored.resolvedAt == Date(timeIntervalSince1970: 3))
        #expect(try await db.claudeCloudSessions.rows().count == 1)
    }

    /// The ungated path: a `pending` row (no session id yet) must still
    /// resolve normally. Proves the id-based guard did not disable ordinary
    /// resolution — only a NAMED different id is refused.
    @Test func resolveOnAPendingRowRecordsTheSession() async throws {
        let db = try TBDDatabase(inMemory: true)
        let row = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 1))
        #expect(row.sessionID == nil)
        try await db.claudeCloudSessions.resolve(
            id: row.id, sessionID: "session_01AAA", title: "first",
            now: Date(timeIntervalSince1970: 2))
        let stored = try #require(try await db.claudeCloudSessions.rows().first)
        #expect(stored.state == ClaudeCloudLedgerState.resolved.rawValue)
        #expect(stored.sessionID == "session_01AAA")
    }

    /// Resolving the SAME session id twice must remain the harmless idempotent
    /// no-op already promised by the doc comment — the guard is on the id,
    /// not on the state, so a same-id retry must not be refused.
    @Test func resolveWithTheSameSessionIDTwiceIsANoOpThatKeepsTheRowIntact() async throws {
        let db = try TBDDatabase(inMemory: true)
        let row = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 1))
        try await db.claudeCloudSessions.resolve(
            id: row.id, sessionID: "session_01AAA", title: "first",
            now: Date(timeIntervalSince1970: 2))
        try await db.claudeCloudSessions.resolve(
            id: row.id, sessionID: "session_01AAA", title: "second",
            now: Date(timeIntervalSince1970: 3))
        let stored = try #require(try await db.claudeCloudSessions.rows().first)
        #expect(stored.state == ClaudeCloudLedgerState.resolved.rawValue)
        #expect(stored.sessionID == "session_01AAA")
        #expect(stored.title == "second")
        #expect(stored.resolvedAt == Date(timeIntervalSince1970: 3))
        #expect(try await db.claudeCloudSessions.rows().count == 1)
    }

    /// A row that already names a DIFFERENT session must refuse — the harm a
    /// state-based predicate would not catch, and the harm a bare
    /// `WHERE id = ?` never guarded against. The original id and its
    /// resolvedAt survive untouched.
    @Test func resolveRefusesToOverwriteADifferentSessionID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let row = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 1))
        try await db.claudeCloudSessions.resolve(
            id: row.id, sessionID: "session_01AAA", title: "original",
            now: Date(timeIntervalSince1970: 2))
        try await db.claudeCloudSessions.resolve(
            id: row.id, sessionID: "session_02BBB", title: "different",
            now: Date(timeIntervalSince1970: 3))
        let stored = try #require(try await db.claudeCloudSessions.rows().first)
        #expect(stored.state == ClaudeCloudLedgerState.resolved.rawValue)
        // The original id, title and resolvedAt all survive — not silently
        // overwritten by the second call naming a different session.
        #expect(stored.sessionID == "session_01AAA")
        #expect(stored.title == "original")
        #expect(stored.resolvedAt == Date(timeIntervalSince1970: 2))
        #expect(try await db.claudeCloudSessions.rows().count == 1)
    }

    /// `resolve` must not throw when the guard refuses the write — the
    /// refusal is loud in the log, not in the caller's control flow.
    @Test func resolveRefusingADifferentSessionIDDoesNotThrow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let row = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "tbd-1", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 1))
        try await db.claudeCloudSessions.resolve(
            id: row.id, sessionID: "session_01AAA", title: "original",
            now: Date(timeIntervalSince1970: 2))
        // Must not throw.
        try await db.claudeCloudSessions.resolve(
            id: row.id, sessionID: "session_02BBB", title: "different",
            now: Date(timeIntervalSince1970: 3))
    }

    @Test func markFailedFlipsOnlyTheNamedRowsAndRetainsThem() async throws {
        let db = try TBDDatabase(inMemory: true)
        let keep = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "k", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 1))
        let doomed = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "d", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 2))
        try await db.claudeCloudSessions.markFailed(ids: [doomed.id])
        let rows = try await db.claudeCloudSessions.rows()
        // Retained, not deleted: the record of a create that may have started
        // a real session outlives the judgement that it did not.
        #expect(rows.count == 2)
        #expect(rows.first(where: { $0.id == keep.id })?.state
            == ClaudeCloudLedgerState.pending.rawValue)
        #expect(rows.first(where: { $0.id == doomed.id })?.state
            == ClaudeCloudLedgerState.failed.rawValue)
        // The row markFailed leaves alone must be untouched, not just
        // "still pending" — check a neighbouring column too.
        #expect(rows.first(where: { $0.id == keep.id })?.idempotencyKey == "k")
    }

    /// The batch takes ids, so an empty batch must be a no-op rather than an
    /// `IN ()` that matches everything.
    @Test func anEmptyFailureBatchTouchesNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "k", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 1))
        try await db.claudeCloudSessions.markFailed(ids: [])
        let rows = try await db.claudeCloudSessions.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.state == ClaudeCloudLedgerState.pending.rawValue)
    }

    /// A failure batch may name a row already marked failed on a retry path;
    /// re-applying must not error or disturb its neighbours.
    @Test func markFailedTwiceOnTheSameIDIsIdempotent() async throws {
        let db = try TBDDatabase(inMemory: true)
        let row = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: "k", repoKey: "a/b", repoPath: "/a", branch: nil,
            environment: nil, paramsJSON: "{}", now: Date(timeIntervalSince1970: 1))
        try await db.claudeCloudSessions.markFailed(ids: [row.id])
        try await db.claudeCloudSessions.markFailed(ids: [row.id])
        let rows = try await db.claudeCloudSessions.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.state == ClaudeCloudLedgerState.failed.rawValue)
    }
}
