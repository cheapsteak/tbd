import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tests for the orphan-GC app plumbing: the `ReclaimedSummary` pure
/// view-model helpers, and the `AppState.reapRecords` / `gcEnabled` mirror.
///
/// Every AppState-touching test constructs `AppState(userDefaults:)` against
/// a unique throwaway suite — TBDApp ships as an unbundled SPM executable, so
/// `UserDefaults.standard` is the running developer's real `TBDApp.plist`
/// (mirrors `EffectiveAutoArchiveTests.swift:14-35`).
@MainActor
@Suite("ReapRecordsState")
struct ReapRecordsStateTests {

    private func withAppState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.ReapRecordsState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func record(
        kind: ReapKind,
        worktreePath: String = "/tmp/wt",
        apparentBytes: Int64? = nil,
        reapedAt: Date = Date(),
        restoredAt: Date? = nil
    ) -> ReapRecord {
        ReapRecord(
            kind: kind,
            repoPath: "/tmp/repo",
            worktreePath: worktreePath,
            apparentBytes: apparentBytes,
            reapedAt: reapedAt,
            restoredAt: restoredAt
        )
    }

    // MARK: - ReclaimedSummary

    @Test func emptyRecordsYieldZeroedSummary() {
        let summary = ReclaimedSummary(records: [])
        #expect(summary.count == 0)
        #expect(summary.totalApparentBytes == 0)
        #expect(summary.agentRecords.isEmpty)
        #expect(summary.scratchpadRollup == nil)
    }

    @Test func countAndBytesSumAcrossMixedKinds() {
        let records = [
            record(kind: .agentWorktree, apparentBytes: 1_000),
            record(kind: .scratchpad, apparentBytes: 500),
            record(kind: .agentWorktree, apparentBytes: 2_000),
        ]
        let summary = ReclaimedSummary(records: records)
        #expect(summary.count == 3)
        #expect(summary.totalApparentBytes == 3_500)
    }

    @Test func nilApparentBytesTreatedAsZero() {
        let records = [
            record(kind: .agentWorktree, apparentBytes: nil),
            record(kind: .agentWorktree, apparentBytes: 100),
        ]
        let summary = ReclaimedSummary(records: records)
        #expect(summary.totalApparentBytes == 100)
    }

    @Test func agentRecordsExcludesScratchpadsAndSortsDescending() {
        let now = Date()
        let oldest = record(kind: .agentWorktree, worktreePath: "/tmp/oldest", reapedAt: now.addingTimeInterval(-200))
        let middle = record(kind: .agentWorktree, worktreePath: "/tmp/middle", reapedAt: now.addingTimeInterval(-100))
        let newest = record(kind: .agentWorktree, worktreePath: "/tmp/newest", reapedAt: now)
        let scratch = record(kind: .scratchpad, worktreePath: "/tmp/scratch", reapedAt: now)

        let summary = ReclaimedSummary(records: [oldest, newest, scratch, middle])
        #expect(summary.agentRecords.map(\.worktreePath) == ["/tmp/newest", "/tmp/middle", "/tmp/oldest"])
    }

    @Test func scratchpadRollupNilWhenNoScratchpads() {
        let summary = ReclaimedSummary(records: [record(kind: .agentWorktree, apparentBytes: 10)])
        #expect(summary.scratchpadRollup == nil)
    }

    @Test func scratchpadRollupAggregatesCountAndBytes() {
        let records = [
            record(kind: .scratchpad, apparentBytes: 300),
            record(kind: .scratchpad, apparentBytes: nil),
            record(kind: .scratchpad, apparentBytes: 200),
            record(kind: .agentWorktree, apparentBytes: 9_999),
        ]
        let summary = ReclaimedSummary(records: records)
        let rollup = summary.scratchpadRollup
        #expect(rollup?.count == 3)
        #expect(rollup?.bytes == 500)
    }

    // MARK: - AppState mirror

    @Test func gcEnabledDefaultsToTrue() {
        withAppState { app in
            #expect(app.gcEnabled == true)
        }
    }

    @Test func reapRecordsDefaultsToEmpty() {
        withAppState { app in
            #expect(app.reapRecords.isEmpty)
        }
    }

    @Test func reapRecordsKeyedByRepoID() {
        withAppState { app in
            let repoA = UUID()
            let repoB = UUID()
            app.reapRecords[repoA] = [record(kind: .agentWorktree)]
            app.reapRecords[repoB] = []
            #expect(app.reapRecords[repoA]?.count == 1)
            #expect(app.reapRecords[repoB]?.isEmpty == true)
            #expect(app.reapRecords[UUID()] == nil)
        }
    }
}
