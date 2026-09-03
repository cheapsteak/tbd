import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2: in-memory GRDB only, no provider and no filesystem.
///
/// The store is where a key becomes recoverable, so what is under test is
/// exactly that: a round trip, the `(provider, key)` identity, and an expiry
/// sweep that reads the instant it was handed rather than a clock of its own.
@Suite("RetainedTranscriptStore")
struct RetainedTranscriptStoreTests {
    let db: TBDDatabase
    init() throws { db = try TBDDatabase(inMemory: true) }

    private func receipt(
        provider: String = "agentbox", key: String = "k-1", expiresAt: Date? = nil,
        bytes: Int = 1234, sourceSessionID: String? = "sess-1",
        sourceTitle: String? = "fix flaky CI", originWorktreeID: UUID? = nil,
        localPath: String? = nil, createdAt: Date = Date()
    ) -> RetainedTranscript {
        RetainedTranscript(
            provider: provider, key: key, expiresAt: expiresAt, bytes: bytes,
            sourceSessionID: sourceSessionID, sourceTitle: sourceTitle,
            originWorktreeID: originWorktreeID, localPath: localPath, createdAt: createdAt)
    }

    @Test func insertRoundTripsEveryField() async throws {
        let expiry = Date(timeIntervalSince1970: 1_790_000_000)
        let worktreeID = UUID()
        let repoID = UUID()
        let row = RetainedTranscript(
            provider: "agentbox", key: "opaque/key with spaces", expiresAt: expiry,
            bytes: 148_213, sourceSessionID: "fix-flaky-ci", sourceTitle: "fix flaky CI",
            resolvedRepoID: repoID, originWorktreeID: worktreeID,
            localPath: "/tmp/x.jsonl", createdAt: Date(timeIntervalSince1970: 1_780_000_000))
        try await db.retainedTranscripts.insert(row)

        let found = try await db.retainedTranscripts.find(provider: "agentbox", key: "opaque/key with spaces")
        #expect(found?.id == row.id)
        #expect(found?.key == "opaque/key with spaces")
        #expect(found?.bytes == 148_213)
        #expect(found?.expiresAt == expiry)
        #expect(found?.sourceSessionID == "fix-flaky-ci")
        #expect(found?.sourceTitle == "fix flaky CI")
        #expect(found?.resolvedRepoID == repoID)
        #expect(found?.originWorktreeID == worktreeID)
        #expect(found?.localPath == "/tmp/x.jsonl")
    }

    @Test func absentExpiryRoundTripsAsNoClaim() async throws {
        try await db.retainedTranscripts.insert(receipt(key: "no-expiry", expiresAt: nil))
        let found = try await db.retainedTranscripts.find(provider: "agentbox", key: "no-expiry")
        #expect(found != nil)
        #expect(found?.expiresAt == nil)
    }

    /// A key is provider-scoped, so the same string under two providers is two
    /// records — not a collision.
    @Test func sameKeyUnderTwoProvidersAreTwoRows() async throws {
        try await db.retainedTranscripts.insert(receipt(provider: "agentbox", key: "shared"))
        try await db.retainedTranscripts.insert(receipt(provider: "acme-cloud", key: "shared"))
        #expect(try await db.retainedTranscripts.all().count == 2)
        #expect(try await db.retainedTranscripts.find(provider: "agentbox", key: "shared") != nil)
        #expect(try await db.retainedTranscripts.find(provider: "acme-cloud", key: "shared") != nil)
    }

    /// `(provider, key)` is the identity: re-recording the pair updates the
    /// receipt rather than growing a second row.
    @Test func reinsertingTheSameProviderKeyReplacesTheReceipt() async throws {
        try await db.retainedTranscripts.insert(receipt(key: "k", bytes: 10))
        try await db.retainedTranscripts.insert(
            receipt(key: "k", expiresAt: Date(timeIntervalSince1970: 99), bytes: 20))
        let rows = try await db.retainedTranscripts.all(provider: "agentbox")
        #expect(rows.count == 1)
        #expect(rows.first?.bytes == 20)
        #expect(rows.first?.expiresAt == Date(timeIntervalSince1970: 99))
    }

    /// A re-`retain` must not forget where an earlier `recall` put the file.
    @Test func reinsertingPreservesAnExistingLocalPath() async throws {
        try await db.retainedTranscripts.insert(receipt(key: "k", localPath: "/tmp/first.jsonl"))
        try await db.retainedTranscripts.insert(receipt(key: "k", bytes: 77, localPath: nil))
        let found = try await db.retainedTranscripts.find(provider: "agentbox", key: "k")
        #expect(found?.localPath == "/tmp/first.jsonl")
        #expect(found?.bytes == 77)
    }

    @Test func setLocalPathRecordsWhereRecallWrote() async throws {
        try await db.retainedTranscripts.insert(receipt(key: "k"))
        let changed = try await db.retainedTranscripts.setLocalPath(
            provider: "agentbox", key: "k", localPath: "/tmp/tbd/transcripts/agentbox/k.jsonl")
        #expect(changed)
        let found = try await db.retainedTranscripts.find(provider: "agentbox", key: "k")
        #expect(found?.localPath == "/tmp/tbd/transcripts/agentbox/k.jsonl")
    }

    @Test func setLocalPathOnAnUnknownKeyChangesNothing() async throws {
        let changed = try await db.retainedTranscripts.setLocalPath(
            provider: "agentbox", key: "nope", localPath: "/tmp/x")
        #expect(changed == false)
    }

    /// The whole point of the date seam: the sweep acts on the instant it was
    /// handed, so the same rows are expired or not depending only on that
    /// argument.
    @Test func deleteExpiredRemovesOnlyStatedExpiriesInThePast() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await db.retainedTranscripts.insert(
            receipt(key: "past", expiresAt: now.addingTimeInterval(-60)))
        try await db.retainedTranscripts.insert(
            receipt(key: "future", expiresAt: now.addingTimeInterval(60)))
        try await db.retainedTranscripts.insert(receipt(key: "no-claim", expiresAt: nil))

        let removed = try await db.retainedTranscripts.deleteExpired(asOf: now)
        #expect(removed == 1)
        let remaining = Set(try await db.retainedTranscripts.all().map(\.key))
        #expect(remaining == ["future", "no-claim"])
    }

    /// An absent `expires_at` is "the provider makes no claim", never "already
    /// gone" — no instant may sweep it.
    @Test func deleteExpiredNeverRemovesARowWithNoStatedExpiry() async throws {
        try await db.retainedTranscripts.insert(receipt(key: "no-claim", expiresAt: nil))
        let removed = try await db.retainedTranscripts.deleteExpired(
            asOf: Date(timeIntervalSince1970: 4_000_000_000))
        #expect(removed == 0)
        #expect(try await db.retainedTranscripts.all().count == 1)
    }

    @Test func allByProviderIsScopedToThatProvider() async throws {
        try await db.retainedTranscripts.insert(receipt(provider: "agentbox", key: "a"))
        try await db.retainedTranscripts.insert(receipt(provider: "acme-cloud", key: "b"))
        let rows = try await db.retainedTranscripts.all(provider: "agentbox")
        #expect(rows.map(\.key) == ["a"])
    }

    @Test func deleteForgetsOneReceipt() async throws {
        try await db.retainedTranscripts.insert(receipt(key: "a"))
        try await db.retainedTranscripts.insert(receipt(key: "b"))
        try await db.retainedTranscripts.delete(provider: "agentbox", key: "a")
        #expect(try await db.retainedTranscripts.all().map(\.key) == ["b"])
    }

    /// `hasExpired` is the model's half of the same rule the store enforces in
    /// SQL, and it must agree: no stated expiry is never expired.
    @Test func hasExpiredReadsAbsenceAsNoClaim() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(receipt(expiresAt: nil).hasExpired(asOf: now) == false)
        #expect(receipt(expiresAt: now.addingTimeInterval(-1)).hasExpired(asOf: now))
        #expect(receipt(expiresAt: now.addingTimeInterval(1)).hasExpired(asOf: now) == false)
    }
}
