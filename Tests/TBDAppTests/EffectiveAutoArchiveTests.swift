import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tests for `effectiveAutoArchive(for:)` — the per-worktree auto-archive resolver.
///
/// The rule is simple: return the worktree's per-worktree override when set;
/// otherwise fall back to the global default (`autoArchiveOnMergeDefault`).
///
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite — TBDApp ships as an unbundled SPM executable, so `UserDefaults.standard`
/// is the running developer's real `TBDApp.plist`.
@MainActor
@Suite("EffectiveAutoArchive")
struct EffectiveAutoArchiveTests {

    private func withAppState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.EffectiveAutoArchive.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func sampleWorktree(autoArchiveOnMerge: Bool? = nil) -> Worktree {
        Worktree(
            repoID: UUID(),
            name: "acme",
            displayName: "acme",
            branch: "tbd/acme",
            path: "/tmp/acme",
            tmuxServer: "tbd-test",
            autoArchiveOnMerge: autoArchiveOnMerge
        )
    }

    @Test func nilFollowsDefaultOff() {
        withAppState { app in
            app.autoArchiveOnMergeDefault = false
            let wt = sampleWorktree(autoArchiveOnMerge: nil)
            #expect(app.effectiveAutoArchive(for: wt) == false)
        }
    }

    @Test func nilFollowsDefaultOn() {
        withAppState { app in
            app.autoArchiveOnMergeDefault = true
            let wt = sampleWorktree(autoArchiveOnMerge: nil)
            #expect(app.effectiveAutoArchive(for: wt) == true)
        }
    }

    @Test func explicitFalseOverridesDefaultOn() {
        withAppState { app in
            app.autoArchiveOnMergeDefault = true
            let wt = sampleWorktree(autoArchiveOnMerge: false)
            #expect(app.effectiveAutoArchive(for: wt) == false)
        }
    }

    @Test func explicitTrueOverridesDefaultOff() {
        withAppState { app in
            app.autoArchiveOnMergeDefault = false
            let wt = sampleWorktree(autoArchiveOnMerge: true)
            #expect(app.effectiveAutoArchive(for: wt) == true)
        }
    }
}
