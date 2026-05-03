import Foundation
import Testing
@testable import TBDApp

/// Tests for the WIP `enableTerminalAutoResize` feature flag. The flag gates
/// the main-area resize broadcast to the daemon and the per-create cell
/// dimensions sent with `terminal.create` / `worktree.create` RPCs. Off by
/// default; on flips the broadcast back on.

@MainActor
@Suite("Terminal auto-resize flag")
struct TerminalAutoResizeFlagTests {
    private let key = AppState.terminalAutoResizeKey

    private func withFlag(_ enabled: Bool, _ body: () throws -> Void) rethrows {
        let prior = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(enabled, forKey: key)
        defer {
            // Restore prior state so tests don't bleed into each other or
            // into the developer's running app instance.
            if let prior {
                UserDefaults.standard.set(prior, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try body()
    }

    @Test("returns (nil, nil) when flag is off so daemon falls back to its 220×50 default")
    func mainAreaTerminalSizeOff() throws {
        try withFlag(false) {
            let state = AppState()
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
        try withFlag(true) {
            let state = AppState()
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
