import Foundation
import TestSupport
import Testing
@testable import TBDApp
import TBDShared

/// Tests for `effectiveAutoHibernate(for:)` — the per-worktree auto-hibernate resolver.
///
/// The rule mirrors auto-archive: return the worktree's per-worktree override
/// when set; otherwise fall back to the global default
/// (`autoHibernateOnMergeDefault`).
///
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite — TBDApp ships as an unbundled SPM executable, so `UserDefaults.standard`
/// is the running developer's real `TBDApp.plist`.
@MainActor
@Suite("EffectiveAutoHibernate")
struct EffectiveAutoHibernateTests {

    private func withAppState(_ body: (AppState) -> Void) {
        let defaultsSuite = TestDefaultsSuite("EffectiveAutoHibernate")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        body(AppState(userDefaults: defaults))
    }

    private func sampleWorktree(autoHibernateOnMerge: Bool? = nil) -> Worktree {
        Worktree(
            repoID: UUID(),
            name: "acme",
            displayName: "acme",
            branch: "tbd/acme",
            path: "/tmp/acme",
            tmuxServer: "tbd-test",
            autoHibernateOnMerge: autoHibernateOnMerge
        )
    }

    @Test func nilFollowsDefaultOff() {
        withAppState { app in
            app.autoHibernateOnMergeDefault = false
            let wt = sampleWorktree(autoHibernateOnMerge: nil)
            #expect(app.effectiveAutoHibernate(for: wt) == false)
        }
    }

    @Test func nilFollowsDefaultOn() {
        withAppState { app in
            app.autoHibernateOnMergeDefault = true
            let wt = sampleWorktree(autoHibernateOnMerge: nil)
            #expect(app.effectiveAutoHibernate(for: wt) == true)
        }
    }

    @Test func explicitFalseOverridesDefaultOn() {
        withAppState { app in
            app.autoHibernateOnMergeDefault = true
            let wt = sampleWorktree(autoHibernateOnMerge: false)
            #expect(app.effectiveAutoHibernate(for: wt) == false)
        }
    }

    @Test func explicitTrueOverridesDefaultOff() {
        withAppState { app in
            app.autoHibernateOnMergeDefault = false
            let wt = sampleWorktree(autoHibernateOnMerge: true)
            #expect(app.effectiveAutoHibernate(for: wt) == true)
        }
    }
}
