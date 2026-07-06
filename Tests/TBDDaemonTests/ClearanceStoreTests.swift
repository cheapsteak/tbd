import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

@Suite("ClearanceStore Integration Tests")
struct ClearanceStoreTests {

    @Test("Insert and retrieve clearance")
    func insertAndRetrieve() async throws {
        let db = try TBDDatabase(inMemory: true)
        let clearance = Clearance(
            prNumber: 42,
            repo: "test/repo",
            clearedWhenSHA: "abc123",
            clearanceKind: .small_safe
        )

        try await db.clearance.insert(clearance)
        let retrieved = try await db.clearance.get(id: clearance.id)

        #expect(retrieved?.prNumber == 42)
        #expect(retrieved?.repo == "test/repo")
        #expect(retrieved?.clearedWhenSHA == "abc123")
    }

    @Test("Void clearance by ID")
    func voidByID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let clearance = Clearance(
            prNumber: 42,
            repo: "test/repo",
            clearedWhenSHA: "abc123",
            clearanceKind: .small_safe
        )

        try await db.clearance.insert(clearance)
        try await db.clearance.voidByID(clearance.id, reason: "sha_mismatch")
        let voided = try await db.clearance.get(id: clearance.id)

        #expect(voided?.voidReason == "sha_mismatch")
    }

    @Test("List clearances by PR")
    func listByPR() async throws {
        let db = try TBDDatabase(inMemory: true)

        let c1 = Clearance(id: "id1", prNumber: 42, repo: "test/repo", clearedWhenSHA: "abc123", clearanceKind: .small_safe)
        let c2 = Clearance(id: "id2", prNumber: 42, repo: "test/repo", clearedWhenSHA: "def456", clearanceKind: .preclear)
        let c3 = Clearance(id: "id3", prNumber: 99, repo: "test/repo", clearedWhenSHA: "xyz789", clearanceKind: .in_channel)

        try await db.clearance.insert(c1)
        try await db.clearance.insert(c2)
        try await db.clearance.insert(c3)

        let forPR42 = try await db.clearance.listByPR(42, repo: "test/repo")
        let forPR99 = try await db.clearance.listByPR(99, repo: "test/repo")

        #expect(forPR42.count == 2)
        #expect(forPR99.count == 1)
        #expect(forPR99.first?.prNumber == 99)
    }

    @Test("Audit trail excludes voided clearances")
    func auditTrailExcludesVoided() async throws {
        let db = try TBDDatabase(inMemory: true)

        let c1 = Clearance(id: "id1", prNumber: 42, repo: "test/repo", clearedWhenSHA: "abc123", clearanceKind: .small_safe)
        let c2 = Clearance(id: "id2", prNumber: 43, repo: "test/repo", clearedWhenSHA: "def456", clearanceKind: .preclear, voidReason: "rebased")

        try await db.clearance.insert(c1)
        try await db.clearance.insert(c2)

        let trail = try await db.clearance.auditTrail()

        #expect(trail.count == 1)
        #expect(trail.first?.id == "id1")
    }

    @Test("Void by SHA affects multiple clearances")
    func voidBySHAMultiple() async throws {
        let db = try TBDDatabase(inMemory: true)

        let c1 = Clearance(id: "id1", prNumber: 42, repo: "test/repo", clearedWhenSHA: "abc123", clearanceKind: .small_safe)
        let c2 = Clearance(id: "id2", prNumber: 42, repo: "test/repo", clearedWhenSHA: "abc123", clearanceKind: .preclear)
        let c3 = Clearance(id: "id3", prNumber: 42, repo: "test/repo", clearedWhenSHA: "def456", clearanceKind: .in_channel)

        try await db.clearance.insert(c1)
        try await db.clearance.insert(c2)
        try await db.clearance.insert(c3)

        // Head is now def456: clearances pinned to abc123 void; the clearance
        // granted on the current head (id3) survives — design §7.3.
        try await db.clearance.voidBySHA(pr: 42, repo: "test/repo", newSHA: "def456", reason: "rebased")

        let current = try await db.clearance.listByPR(42, repo: "test/repo")
        let voided = current.filter { $0.voidReason != nil }

        #expect(voided.count == 2, "Expected 2 voided (pinned to the old SHA)")
        #expect(current.first(where: { $0.id == "id3" })?.voidReason == nil,
                "Clearance granted on the current head must survive")
    }
}
