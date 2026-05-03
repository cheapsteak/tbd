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

    @Test("returns (0, 0) when flag is off so daemon-side resize gates skip")
    func mainAreaTerminalSizeOff() throws {
        try withFlag(false) {
            let state = AppState()
            // The defaults seed mainAreaSize at 1120x776, which would
            // otherwise produce a real cell count — verify the flag wins.
            state.mainAreaSize = CGSize(width: 1200, height: 800)
            let size = state.mainAreaTerminalSize()
            #expect(size.cols == 0)
            #expect(size.rows == 0)
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
            #expect(size.cols >= 80)
            #expect(size.rows >= 24)
            #expect(size.cols < 1200)
            #expect(size.rows < 800)
        }
    }
}
