import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

@Suite("AuditStore Integration Tests")
struct AuditStoreTests {

    @Test("Log action and retrieve")
    func logActionAndRetrieve() async throws {
        let db = try TBDDatabase(inMemory: true)
        let entry = AuditLogEntry(
            action: .wouldMerge,
            prNumber: 42,
            repo: "test/repo",
            headSHA: "abc123"
        )

        try await db.audit.logAction(entry)
        let retrieved = try await db.audit.get(id: entry.id)

        #expect(retrieved?.action == .wouldMerge)
        #expect(retrieved?.prNumber == 42)
    }

    @Test("List audit entries by time range")
    func listByTimeRange() async throws {
        let db = try TBDDatabase(inMemory: true)
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        let oneHourFromNow = now.addingTimeInterval(3600)

        let e1 = AuditLogEntry(action: .wouldMerge, prNumber: 42, timestamp: oneHourAgo)
        let e2 = AuditLogEntry(action: .hold, prNumber: 43, timestamp: now)
        let e3 = AuditLogEntry(action: .escalate, prNumber: 44, timestamp: oneHourFromNow)

        try await db.audit.logAction(e1)
        try await db.audit.logAction(e2)
        try await db.audit.logAction(e3)

        let recent = try await db.audit.list(since: now, until: oneHourFromNow)

        #expect(recent.count == 2)
        #expect(recent.contains(where: { $0.action == .hold }))
        #expect(recent.contains(where: { $0.action == .escalate }))
        #expect(!recent.contains(where: { $0.action == .wouldMerge }))
    }

    @Test("List audit entries by action")
    func listByAction() async throws {
        let db = try TBDDatabase(inMemory: true)

        try await db.audit.logAction(AuditLogEntry(action: .wouldMerge, prNumber: 1))
        try await db.audit.logAction(AuditLogEntry(action: .wouldMerge, prNumber: 2))
        try await db.audit.logAction(AuditLogEntry(action: .hold, prNumber: 3))
        try await db.audit.logAction(AuditLogEntry(action: .escalate, prNumber: 4))

        let merges = try await db.audit.list(action: .wouldMerge)
        let holds = try await db.audit.list(action: .hold)

        #expect(merges.count == 2)
        #expect(holds.count == 1)
        #expect(merges.allSatisfy { $0.action == .wouldMerge })
    }

    @Test("Count audit entries by action")
    func countByAction() async throws {
        let db = try TBDDatabase(inMemory: true)

        try await db.audit.logAction(AuditLogEntry(action: .wouldMerge, prNumber: 1))
        try await db.audit.logAction(AuditLogEntry(action: .wouldMerge, prNumber: 2))
        try await db.audit.logAction(AuditLogEntry(action: .hold, prNumber: 3))
        try await db.audit.logAction(AuditLogEntry(action: .escalate, prNumber: 4))

        let counts = try await db.audit.countByAction()

        #expect(counts[.wouldMerge] == 2)
        #expect(counts[.hold] == 1)
        #expect(counts[.escalate] == 1)
        #expect(counts[.clearanceVoided] == nil)
    }

    @Test("Audit entries ordered by timestamp descending")
    func entriesOrderedByTimestamp() async throws {
        let db = try TBDDatabase(inMemory: true)
        let now = Date()

        let e1 = AuditLogEntry(action: .wouldMerge, prNumber: 1, timestamp: now.addingTimeInterval(-10))
        let e2 = AuditLogEntry(action: .hold, prNumber: 2, timestamp: now)
        let e3 = AuditLogEntry(action: .escalate, prNumber: 3, timestamp: now.addingTimeInterval(10))

        try await db.audit.logAction(e1)
        try await db.audit.logAction(e2)
        try await db.audit.logAction(e3)

        let entries = try await db.audit.list()

        #expect(entries.count == 3)
        #expect(entries[0].prNumber == 3)  // Most recent first
        #expect(entries[1].prNumber == 2)
        #expect(entries[2].prNumber == 1)  // Oldest last
    }

    @Test("Audit details captured in JSON")
    func detailsCapture() async throws {
        let db = try TBDDatabase(inMemory: true)
        let details = #"{"reason":"high_impact_domain","domain":".nightwatch"}"#
        let entry = AuditLogEntry(
            action: .hold,
            prNumber: 42,
            repo: "test/repo",
            details: details
        )

        try await db.audit.logAction(entry)
        let retrieved = try await db.audit.get(id: entry.id)

        #expect(retrieved?.details == details)
    }
}
