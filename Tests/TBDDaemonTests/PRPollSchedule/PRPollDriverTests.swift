import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// `pr_poll_schedule_enabled` picks exactly one periodic PR driver. Both
/// branches, and the unset (NULL) state, which must follow the shipped default.
@Suite("PRPollDriver")
struct PRPollDriverTests {
    actor Started {
        var names: [String] = []
        func add(_ name: String) { names.append(name) }
    }

    @Test func nullOrFalseRunsTheLegacyPollerOnly() async throws {
        let db = try TBDDatabase(inMemory: true)                       // column NULL
        #expect(PRPollDriver.kind(for: try await db.config.get()) == .legacyPoller)
        try await db.config.setPRPollScheduleEnabled(false)            // column 0
        let kind = PRPollDriver.kind(for: try await db.config.get())
        #expect(kind == .legacyPoller)
        let started = Started()
        await PRPollDriver.start(kind, legacy: { await started.add("legacy") },
                                 schedule: { await started.add("schedule") })
        #expect(await started.names == ["legacy"])
    }

    @Test func trueRunsTheSchedulerOnly() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPRPollScheduleEnabled(true)
        let kind = PRPollDriver.kind(for: try await db.config.get())
        #expect(kind == .schedule)
        let started = Started()
        await PRPollDriver.start(kind, legacy: { await started.add("legacy") },
                                 schedule: { await started.add("schedule") })
        #expect(await started.names == ["schedule"])
    }
}
