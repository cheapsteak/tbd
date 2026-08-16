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
}
