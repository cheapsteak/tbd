import Foundation
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
    /// hand the body an `AppState` wired to that domain, then tear the
    /// domain down so nothing persists across tests.
    private func withFlag(_ enabled: Bool, _ body: (AppState) throws -> Void) rethrows {
        let suiteName = "TBDAppTests.TerminalAutoResize.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(enabled, forKey: key)
        let state = AppState(userDefaults: defaults)
        try body(state)
    }

    @Test("returns (nil, nil) when flag is off so daemon falls back to its 220×50 default")
    func mainAreaTerminalSizeOff() {
        withFlag(false) { state in
            // The defaults seed mainAreaSize at 1120x776, which would
            // otherwise produce a real cell count — verify the flag wins.
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
        try withFlag(true) { state in
            state.mainAreaSize = CGSize(width: 1200, height: 800)
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
