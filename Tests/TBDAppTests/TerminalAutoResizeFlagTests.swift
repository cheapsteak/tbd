import Foundation
import TestSupport
import Testing
@testable import TBDApp

/// Tests for the WIP `enableTerminalAutoResize` feature flag. The flag gates
/// the main-area resize broadcast to the daemon and the per-create cell
/// dimensions sent with `terminal.create` / `worktree.create` RPCs. Off by
/// default; on flips the broadcast back on.
///
/// Isolation matters: TBDApp ships as an unbundled SPM executable, so its
/// `UserDefaults.standard` domain is `TBDApp.plist` in the developer's home
/// — the SAME domain a running production TBDApp reads via `@AppStorage`.
/// An earlier version of these tests mutated `.standard`, which clobbered the
/// live app's preferences mid-test and triggered a real Claude `/exit`. Every
/// test below now constructs `AppState(userDefaults:)` with a per-test
/// `UserDefaults(suiteName:)` so `.standard` is never touched.

@MainActor
@Suite("Terminal auto-resize flag")
struct TerminalAutoResizeFlagTests {
    private let key = AppState.terminalAutoResizeKey

    /// Build an isolated UserDefaults domain seeded with the flag value,
    /// hand the body an `AppState` wired to that domain plus the domain
    /// itself, then tear the domain down so nothing persists across tests.
    ///
    /// The body gets the `UserDefaults` because `AppState.terminalAutoResizeEnabled`
    /// is a *live* `userDefaults.bool(forKey:)` read, not a cached-at-init
    /// value — so writing the key mid-test flips the flag for subsequent
    /// reads. `mainAreaTerminalSizeOn` relies on that; see the comment there.
    private func withFlag(
        _ enabled: Bool,
        _ body: (AppState, UserDefaults) throws -> Void
    ) rethrows {
        let defaultsSuite = TestDefaultsSuite("TerminalAutoResize")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        defaults.set(enabled, forKey: key)
        let state = AppState(userDefaults: defaults)
        try body(state, defaults)
    }

    @Test("returns (nil, nil) when flag is off so daemon falls back to its 220×50 default")
    func mainAreaTerminalSizeOff() {
        withFlag(false) { state, _ in
            // The defaults seed mainAreaSize at 1120x776, which would
            // otherwise produce a real cell count — verify the flag wins.
            // Safe to assign with the flag off: the `didSet` reaches
            // `scheduleMainAreaSizeBroadcast()`, which returns at its own
            // `guard terminalAutoResizeEnabled` before arming anything.
            state.mainAreaSize = CGSize(width: 1200, height: 800)
            let size = state.mainAreaTerminalSize()
            // nil (not 0) is required so callers' Int? params trigger the
            // daemon's `?? TmuxManager.defaultCols` fallback. `Some(0)` would
            // bypass the fallback and tmux would land at 80×24.
            #expect(size.cols == nil)
            #expect(size.rows == nil)
        }
    }

    @Test("returns real cell counts when flag is on")
    func mainAreaTerminalSizeOn() throws {
        try withFlag(true) { state, defaults in
            // Seed the viewport with the flag OFF, then flip it back on.
            //
            // Assigning `mainAreaSize` while the flag is on runs its `didSet`
            // → `scheduleMainAreaSizeBroadcast()`, which arms a 300ms debounce
            // in a stored Task. That task outlives this test and then fires a
            // REAL `setMainAreaSize` RPC at `~/tbd/sock` — the developer's
            // running daemon — violating the repo's "tests must not touch
            // ~/tbd" rule, and reporting any failure from a Task with no
            // enclosing test scope. `AppState.daemonClient` is a
            // non-injectable `let` with no protocol, so nothing can intercept
            // that RPC; the seam is filed as issue #532. Until it lands, the
            // flag guard is the only interception point we have — and
            // cancelling the debounce isn't an option either, because
            // `mainAreaSizeBroadcastTask` is `private` (not `@testable`-reachable).
            //
            // This costs no coverage: the subject here is
            // `mainAreaTerminalSize()` with the flag ON, which is exercised
            // exactly as before. The debounce was only ever an unasserted
            // side effect of the setup. `terminalAutoResizeEnabled` reads
            // UserDefaults on every access, so the flip below is immediate.
            defaults.set(false, forKey: key)
            state.mainAreaSize = CGSize(width: 1200, height: 800)
            defaults.set(true, forKey: key)

            let size = state.mainAreaTerminalSize()
            // Exact cell metrics depend on the platform monospaced font, so
            // we just assert plausible bounds — the floor is 80x24 and a
            // 1200x800 viewport must not exceed it by more than the screen
            // could fit at any reasonable cell size.
            let cols = try #require(size.cols)
            let rows = try #require(size.rows)
            #expect(cols >= 80)
            #expect(rows >= 24)
            #expect(cols < 1200)
            #expect(rows < 800)
        }
    }
}
