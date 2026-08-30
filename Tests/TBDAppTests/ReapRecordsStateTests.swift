import Foundation
import TestSupport
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
        let defaultsSuite = TestDefaultsSuite("ReapRecordsState")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        body(AppState(userDefaults: defaults))
    }

    private func archivedWorktree(id: UUID, repoID: UUID, archivedAt: Date) -> Worktree {
        Worktree(
            id: id,
            repoID: repoID,
            name: "test-\(id.uuidString.prefix(8))",
            displayName: "Test \(id.uuidString.prefix(8))",
            branch: "main",
            path: "/tmp/test",
            status: .archived,
            archivedAt: archivedAt,
            tmuxServer: "test-server"
        )
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

    @Test func archivedWorktreeRollupNilWhenNoArchivedWorktrees() {
        let summary = ReclaimedSummary(records: [record(kind: .agentWorktree, apparentBytes: 10)])
        #expect(summary.archivedWorktreeRollup == nil)
    }

    @Test func archivedWorktreeRollupAggregatesCountAndBytes() {
        let records = [
            record(kind: .archivedWorktree, apparentBytes: 300),
            record(kind: .archivedWorktree, apparentBytes: nil),
            record(kind: .archivedWorktree, apparentBytes: 200),
            record(kind: .agentWorktree, apparentBytes: 9_999),
            record(kind: .scratchpad, apparentBytes: 1),
        ]
        let summary = ReclaimedSummary(records: records)
        let rollup = summary.archivedWorktreeRollup
        #expect(rollup?.count == 3)
        #expect(rollup?.bytes == 500)
    }

    @Test func archivedWorktreeRecordsCountTowardHeaderTotalsButNotAgentRecords() {
        // The gap the review caught: `.archivedWorktree` records must
        // contribute to `count` / `totalApparentBytes` (the header) exactly
        // like every other kind, but must NOT appear in `agentRecords` (the
        // per-row restorable list) — they render via the rollup instead.
        let records = [
            record(kind: .archivedWorktree, apparentBytes: 700),
            record(kind: .agentWorktree, worktreePath: "/tmp/agent", apparentBytes: 300),
        ]
        let summary = ReclaimedSummary(records: records)
        #expect(summary.count == 2)
        #expect(summary.totalApparentBytes == 1_000)
        #expect(summary.agentRecords.map(\.worktreePath) == ["/tmp/agent"])
    }

    @Test func unrestoredExcludesRestoredRecordsFromCountAndBytes() {
        let restored = record(kind: .agentWorktree, apparentBytes: 1_000, restoredAt: Date())
        let live = record(kind: .agentWorktree, apparentBytes: 500)
        let scratch = record(kind: .scratchpad, apparentBytes: 250)
        let summary = ReclaimedSummary(records: [restored, live, scratch])

        #expect(summary.count == 3) // unfiltered — the expanded list still shows everything
        #expect(summary.unrestored.count == 2)
        #expect(summary.unrestored.totalApparentBytes == 750)
    }

    @Test func unrestoredIsIdentityWhenNothingRestored() {
        let records = [
            record(kind: .agentWorktree, apparentBytes: 100),
            record(kind: .scratchpad, apparentBytes: 200),
        ]
        let summary = ReclaimedSummary(records: records)
        #expect(summary.unrestored.count == summary.count)
        #expect(summary.unrestored.totalApparentBytes == summary.totalApparentBytes)
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

    // MARK: - Archived/Reclaimed selection exclusivity
    //
    // ArchivedWorktreesView's "Reclaimed" section used to hold its selection
    // in view-local @State, documented as mutually exclusive with
    // `selectedArchivedWorktreeIDs[repoID]` but with no way to enforce that
    // from `ensureArchivedSelectionValid`'s fallback auto-pick, which could
    // steal the highlight out from under a deliberate Reclaimed selection.
    // The fix lifts both selections into AppState (`selectedReapRecordIDs` +
    // `selectedArchivedWorktreeIDs`) so every entry point can respect the
    // invariant. These tests cover that invariant directly.

    @Test func ensureArchivedSelectionValidDoesNotAutoPickWhenReapSelectionExists() {
        withAppState { app in
            let repoID = UUID()
            let worktreeID = UUID()
            app.archivedWorktrees[repoID] = [
                archivedWorktree(id: worktreeID, repoID: repoID, archivedAt: Date())
            ]
            app.selectedReapRecordIDs[repoID] = UUID()

            app.ensureArchivedSelectionValid(repoID: repoID)

            #expect(app.selectedArchivedWorktreeIDs[repoID] == nil)
            #expect(app.selectedReapRecordIDs[repoID] != nil)
        }
    }

    @Test func ensureArchivedSelectionValidStillAutoPicksWhenNoReapSelection() {
        withAppState { app in
            let repoID = UUID()
            let older = archivedWorktree(id: UUID(), repoID: repoID, archivedAt: Date().addingTimeInterval(-100))
            let newer = archivedWorktree(id: UUID(), repoID: repoID, archivedAt: Date())
            app.archivedWorktrees[repoID] = [older, newer]

            app.ensureArchivedSelectionValid(repoID: repoID)

            #expect(app.selectedArchivedWorktreeIDs[repoID] == newer.id)
        }
    }

    @Test func ensureArchivedSelectionValidClearsWhenNothingArchivedAndNoReapSelection() {
        withAppState { app in
            let repoID = UUID()
            app.archivedWorktrees[repoID] = []

            app.ensureArchivedSelectionValid(repoID: repoID)

            #expect(app.selectedArchivedWorktreeIDs[repoID] == nil)
        }
    }

    @Test func selectArchivedWorktreeClearsReapSelectionForSameRepo() {
        withAppState { app in
            let repoID = UUID()
            let worktreeID = UUID()
            app.selectedReapRecordIDs[repoID] = UUID()

            app.selectArchivedWorktree(worktreeID, repoID: repoID)

            #expect(app.selectedArchivedWorktreeIDs[repoID] == worktreeID)
            #expect(app.selectedReapRecordIDs[repoID] == nil)
        }
    }

    @Test func selectReapRecordClearsArchivedSelectionForSameRepo() {
        withAppState { app in
            let repoID = UUID()
            let recordID = UUID()
            app.selectedArchivedWorktreeIDs[repoID] = UUID()

            app.selectReapRecord(recordID, repoID: repoID)

            #expect(app.selectedReapRecordIDs[repoID] == recordID)
            #expect(app.selectedArchivedWorktreeIDs[repoID] == nil)
        }
    }

    @Test func selectionHelpersScopeToTheirOwnRepoOnly() {
        withAppState { app in
            let repoA = UUID()
            let repoB = UUID()
            app.selectedReapRecordIDs[repoB] = UUID()

            app.selectArchivedWorktree(UUID(), repoID: repoA)

            // Selecting an archived row in repoA must not disturb repoB's
            // independent reap selection.
            #expect(app.selectedReapRecordIDs[repoB] != nil)
        }
    }
}
