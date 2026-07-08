import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("SwapProfileMenu — busy-session warning")
struct SwapProfileMenuTests {
    @Test func inPlaceSwapOfBusySessionWarnsAboutInterrupt() {
        let caption = SwapProfileMenu.busyCaption(mode: .inPlace, activityState: .working)
        #expect(caption == SwapProfileMenu.interruptsRunCaption)
        #expect(caption?.contains("interrupts current run") == true)
    }

    @Test func inPlaceSwapOfNonBusySessionHasNoWarning() {
        #expect(SwapProfileMenu.busyCaption(mode: .inPlace, activityState: .idle) == nil)
        #expect(SwapProfileMenu.busyCaption(mode: .inPlace, activityState: .unknown) == nil)
        #expect(SwapProfileMenu.busyCaption(mode: .inPlace, activityState: nil) == nil)
    }

    @Test func forkNeverWarnsEvenWhenBusy() {
        // Forking duplicates the conversation into a new tab and leaves the
        // source session untouched — no interruption to warn about.
        #expect(SwapProfileMenu.busyCaption(mode: .fork, activityState: .working) == nil)
        #expect(SwapProfileMenu.busyCaption(mode: .fork, activityState: .idle) == nil)
    }
}

@Suite("SwapProfileMenu — menuLabel")
struct SwapProfileMenuLabelTests {
    private func profile(name: String) -> ModelProfile {
        ModelProfile(id: UUID(), name: name, kind: .oauth, createdAt: Date())
    }

    private func bucket(_ kind: String, _ percent: Double) -> ClaudeUsageLimitBucket {
        ClaudeUsageLimitBucket(kind: kind, percent: percent, severity: nil, resetsAt: nil)
    }

    private func snapshot(with buckets: [ClaudeUsageLimitBucket]) -> ProfileUsageSnapshot {
        let now = Date()
        return ProfileUsageSnapshot(
            buckets: buckets,
            fetchedAt: now,
            lastAttemptAt: now,
            status: "ok",
            statusKind: .ok
        )
    }

    @Test func profileWithNoSnapshot() {
        let profile = profile(name: "Work")
        let label = SwapProfileMenu.menuLabel(for: profile, usage: nil)
        #expect(label == "Work")
    }

    @Test func profileWithEmptySnapshot() {
        let profile = profile(name: "Work")
        let emptySnapshot = snapshot(with: [])
        let label = SwapProfileMenu.menuLabel(for: profile, usage: emptySnapshot)
        #expect(label == "Work")
    }

    @Test func profileWithSessionBucketOnly() {
        let profile = profile(name: "Gmail")
        let sessionBucket = bucket("session", 40.0)
        let snap = snapshot(with: [sessionBucket])
        let label = SwapProfileMenu.menuLabel(for: profile, usage: snap)
        #expect(label == "Gmail — 5h 40%")
    }

    @Test func profileWithSessionAndWeeklyBuckets() {
        let profile = profile(name: "Gmail")
        let sessionBucket = bucket("session", 40.0)
        let weeklyBucket = bucket("weekly_all", 16.0)
        let snap = snapshot(with: [sessionBucket, weeklyBucket])
        let label = SwapProfileMenu.menuLabel(for: profile, usage: snap)
        #expect(label == "Gmail — 5h 40% · wk 16%")
    }

    @Test func profileWithScopedBuckets() {
        let profile = profile(name: "Gmail")
        let sessionBucket = bucket("session", 50.0)
        let scopedBucket = ClaudeUsageLimitBucket(
            kind: "weekly_scoped",
            percent: 100.0,
            severity: nil,
            resetsAt: nil,
            modelDisplayName: "Fable"
        )
        let snap = snapshot(with: [sessionBucket, scopedBucket])
        let label = SwapProfileMenu.menuLabel(for: profile, usage: snap)
        #expect(label == "Gmail — 5h 50% · F 100%")
    }

    @Test func profileWithAllBucketTypes() {
        let profile = profile(name: "Work")
        let sessionBucket = bucket("session", 25.0)
        let weeklyBucket = bucket("weekly_all", 10.0)
        let scopedBucket = ClaudeUsageLimitBucket(
            kind: "weekly_scoped",
            percent: 75.0,
            severity: nil,
            resetsAt: nil,
            modelDisplayName: "Opus"
        )
        let snap = snapshot(with: [sessionBucket, weeklyBucket, scopedBucket])
        let label = SwapProfileMenu.menuLabel(for: profile, usage: snap)
        #expect(label == "Work — 5h 25% · wk 10% · O 75%")
    }
}
