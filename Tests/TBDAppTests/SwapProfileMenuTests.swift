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

    @Test func legacyScopedBucketAddsNoSegment() {
        // A stored snapshot can still carry a `weekly_scoped` Fable bucket;
        // Fable usage counts toward the plan's all-models limits, so the
        // label shows only the plan-wide windows.
        let profile = profile(name: "Work")
        let sessionBucket = bucket("session", 25.0)
        let weeklyBucket = bucket("weekly_all", 10.0)
        let scopedBucket = ClaudeUsageLimitBucket(
            kind: "weekly_scoped",
            percent: 100.0,
            severity: "critical",
            resetsAt: nil,
            modelDisplayName: "Fable"
        )
        let snap = snapshot(with: [sessionBucket, weeklyBucket, scopedBucket])
        let label = SwapProfileMenu.menuLabel(for: profile, usage: snap)
        #expect(label == "Work — 5h 25% · wk 10%")
    }

    @Test func scopedOnlySnapshotFallsBackToBaseName() {
        let profile = profile(name: "Gmail")
        let scopedBucket = ClaudeUsageLimitBucket(
            kind: "weekly_scoped", percent: 100.0, modelDisplayName: "Fable")
        let label = SwapProfileMenu.menuLabel(for: profile, usage: snapshot(with: [scopedBucket]))
        #expect(label == "Gmail")
    }
}

@Suite("SwapProfileMenu — items")
struct SwapProfileMenuItemsTests {
    private func entry(_ name: String) -> ModelProfileWithUsage {
        ModelProfileWithUsage(
            profile: ModelProfile(id: UUID(), name: name, kind: .oauth, createdAt: Date()),
            usage: nil)
    }

    @Test func marksOnlyTheCurrentAccount() {
        let a = entry("acct-a"), b = entry("acct-b")
        let items = SwapProfileMenu.items(
            profiles: [a, b], currentProfileID: b.profile.id, mode: .inPlace, activityState: .idle)
        #expect(items == [
            .profile(id: nil, title: "Default (logged in)", isCurrent: false),
            .separator,
            .profile(id: a.profile.id, title: "acct-a", isCurrent: false),
            .profile(id: b.profile.id, title: "acct-b", isCurrent: true),
        ])
    }

    @Test func defaultIsCurrentWhenTabHasNoProfile() {
        let items = SwapProfileMenu.items(
            profiles: [entry("acct-a")], currentProfileID: nil, mode: .fork, activityState: nil)
        #expect(items.first == .profile(id: nil, title: "Default (logged in)", isCurrent: true))
    }

    @Test func busyCaptionOnlyForInPlaceWorkingSession() {
        let busy = SwapProfileMenu.items(
            profiles: [], currentProfileID: nil, mode: .inPlace, activityState: .working)
        #expect(busy.last == .caption(SwapProfileMenu.interruptsRunCaption))
        let fork = SwapProfileMenu.items(
            profiles: [], currentProfileID: nil, mode: .fork, activityState: .working)
        #expect(!fork.contains { if case .caption = $0 { true } else { false } })
    }
}

@Suite("TabContextMenuHitTest")
struct TabContextMenuHitTestTests {
    @Test func findsTheTabUnderThePoint() {
        let a = UUID(), b = UUID()
        let frames = [a: CGRect(x: 0, y: 0, width: 100, height: 28),
                      b: CGRect(x: 100, y: 0, width: 100, height: 28)]
        #expect(TabContextMenuHitTest.tabID(at: CGPoint(x: 150, y: 10), frames: frames) == b)
        #expect(TabContextMenuHitTest.tabID(at: CGPoint(x: 50, y: 10), frames: frames) == a)
        #expect(TabContextMenuHitTest.tabID(at: CGPoint(x: 250, y: 10), frames: frames) == nil)
        #expect(TabContextMenuHitTest.tabID(at: .zero, frames: [:]) == nil)
    }

    @Test func onlyRightAndControlClicksOpenTheMenu() {
        #expect(TabContextMenuHitTest.opensContextMenu(type: .rightMouseDown, modifiers: []))
        #expect(TabContextMenuHitTest.opensContextMenu(type: .leftMouseDown, modifiers: .control))
        #expect(!TabContextMenuHitTest.opensContextMenu(type: .leftMouseDown, modifiers: []))
        #expect(!TabContextMenuHitTest.opensContextMenu(type: .mouseMoved, modifiers: .control))
    }
}
