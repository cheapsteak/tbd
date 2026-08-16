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
            branch: "fix-ci", environment: nil, paramsJSON: #"{"prompt":"hi"}"#, now: now)
        #expect(row.state == ClaudeCloudLedgerState.pending.rawValue)
        #expect(row.sessionID == nil)
        #expect(row.title == nil)
        #expect(row.archived == false)
        let all = try await db.claudeCloudSessions.rows()
        #expect(all.map(\.idempotencyKey) == ["tbd-1"])
        #expect(all.first?.repoKey == "acme/api")
        #expect(all.first?.repoPath == "/tmp/api")
        #expect(all.first?.branch == "fix-ci")
        #expect(all.first?.createdAt == now)
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
