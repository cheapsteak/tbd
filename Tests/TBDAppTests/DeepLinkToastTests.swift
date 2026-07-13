import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tests for the deep-link toast state machine (Toast model + AppState+Toast).
///
/// Every test constructs `AppState(userDefaults:)` against a throwaway suite —
/// `UserDefaults.standard` on this unbundled executable is the developer's
/// real `TBDApp.plist`. Countdown ticks are shrunk to 5ms via
/// `toastTickDuration` so no test sleeps for real seconds.
@MainActor
@Suite("Deep-link toast")
struct DeepLinkToastTests {

    private func withState(_ body: (AppState) async -> Void) async {
        let suiteName = "TBDAppTests.DeepLinkToast.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)
        state.toastTickDuration = .milliseconds(5)
        await body(state)
    }

    /// Poll `cond` on the main actor until true or deadline. Returns success.
    private func waitUntil(
        deadline: Duration = .seconds(2), _ cond: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while !cond() {
            if clock.now - start > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    // MARK: - showToast / dismissToast basics

    @Test func showToast_publishesToast() async {
        await withState { state in
            state.showToast(Toast(id: UUID(), message: "Looking for worktree…", style: .progress))
            #expect(state.activeToast?.message == "Looking for worktree…")
            #expect(state.activeToast?.style == .progress)
        }
    }

    @Test func dismissToast_clearsToastAndCTA() async {
        await withState { state in
            state.showToast(Toast(id: UUID(), message: "m", style: .progress))
            state.toastCTAAction = {}
            state.dismissToast()
            #expect(state.activeToast == nil)
            #expect(state.toastCTAAction == nil)
        }
    }

    // MARK: - Countdown

    @Test func startToastCountdown_beginsAtFullSeconds() async {
        await withState { state in
            state.showToast(Toast(id: UUID(), message: "m", style: .progress))
            state.startToastCountdown(onExpiry: {})
            #expect(state.activeToast?.style == .countdown(secondsRemaining: 5))
        }
    }

    @Test func countdownExpiry_firesOnExpiryOnceAndDismisses() async {
        await withState { state in
            var fired = 0
            state.showToast(Toast(id: UUID(), message: "m", style: .progress))
            state.startToastCountdown(onExpiry: { fired += 1 })
            let expired = await waitUntil { state.activeToast == nil }
            #expect(expired)
            // Drain a few more ticks to prove it fires exactly once.
            try? await Task.sleep(for: .milliseconds(50))
            #expect(fired == 1)
        }
    }

    @Test func hoverDuringCountdown_cancelsPermanentlyAndShowsCTA() async {
        await withState { state in
            var fired = false
            state.showToast(Toast(id: UUID(), message: "m", style: .progress))
            state.startToastCountdown(onExpiry: { fired = true })
            state.toastHoverChanged(true)
            #expect(state.activeToast?.style == .action(ctaLabel: "Go to archive entry"))
            // Mouse leaves — countdown must NOT resume.
            state.toastHoverChanged(false)
            try? await Task.sleep(for: .milliseconds(60))  // > 10 ticks
            #expect(fired == false)
            #expect(state.activeToast != nil)
        }
    }

    @Test func hoverOutsideCountdownState_isIgnored() async {
        await withState { state in
            state.showToast(Toast(id: UUID(), message: "m", style: .progress))
            state.toastHoverChanged(true)
            #expect(state.activeToast?.style == .progress)
        }
    }

    @Test func newToast_replacesOldAndCancelsItsCountdown() async {
        await withState { state in
            var fired = false
            state.showToast(Toast(id: UUID(), message: "old", style: .progress))
            state.startToastCountdown(onExpiry: { fired = true })
            state.showToast(Toast(id: UUID(), message: "new", style: .progress))
            try? await Task.sleep(for: .milliseconds(60))
            #expect(fired == false)
            #expect(state.activeToast?.message == "new")
        }
    }

    // MARK: - Error toast

    @Test func errorToast_autoDismisses() async {
        await withState { state in
            state.showErrorToast("Worktree not found — it may have been deleted.")
            #expect(state.activeToast?.style == .error)
            let dismissed = await waitUntil { state.activeToast == nil }
            #expect(dismissed)
        }
    }
}
