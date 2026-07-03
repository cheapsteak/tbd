import Foundation
import os

/// Arbitrates control-mode window resizes with echo suppression (addendum §4).
///
/// The daemon is the sole size authority: the app sends the desired `(cols,
/// rows)` per window (debounced on geometry change) over the RPC socket, and
/// this coordinator issues `resize-window` through the FIFO correlator, chaining
/// a `list-windows` as an **echo fence**. Every `%layout-change` tmux emits in
/// response to OUR resize is ordered BEFORE the `list-windows` reply on the one
/// `-CC` stream, so once the fence completes we know all of our own echoes have
/// already been seen — anything after it is a real external change. A
/// `%layout-change` arriving while the fence is open (counter > 0) is a stale
/// echo of our own command and is IGNORED entirely, not reconciled.
///
/// Concretizes iTerm2's `numOutstandingWindowResizes_` (`TmuxController.m`).
/// Ours is per-window (keyed by `(server, windowID)`); iTerm2's is a single
/// global counter — finer granularity, same idea.
///
/// Construction mirrors `ControlModeInputRouter`: an injectable
/// `commandProvider` resolves a server name to its FIFO correlator (production
/// passes `{ await supervisor.command(server: $0) }`, tests inject a fake).
final class ControlModeResizeCoordinator: @unchecked Sendable {
    /// tmux windowIDs ("@0", "@1", …) are only unique within one tmux server
    /// (mirrors `PaneKey`'s rationale for panes), so every entry keys by the
    /// `(server, windowID)` composite.
    private struct WindowKey: Hashable {
        let server: String
        let windowID: String
    }

    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")
    private let commandProvider: @Sendable (String) async -> TmuxControlCommandClient?

    private let lock = NSLock()
    /// In-flight resize count per window. > 0 means an echo fence is open, so
    /// layout notifications for that window are stale echoes to be suppressed.
    /// Entries are removed at 0 to keep the map small.
    private var outstanding: [WindowKey: Int] = [:]

    /// Sane geometry bounds. Garbage sizes from a mid-animation view (or a wildly
    /// wrong debounce sample) must not wedge tmux, which historically misbehaves
    /// on absurd dimensions — clamp before it ever reaches `resize-window`.
    private static let colBounds = 20...500
    private static let rowBounds = 5...300

    init(commandProvider: @escaping @Sendable (String) async -> TmuxControlCommandClient?) {
        self.commandProvider = commandProvider
    }

    /// Issue a `resize-window` for `windowID` and open an echo fence. Called on
    /// the `pane.resize` RPC handler's task, once per debounced app resize.
    func resize(server: String, windowID: String, cols: Int, rows: Int) async {
        let clampedCols = min(max(cols, Self.colBounds.lowerBound), Self.colBounds.upperBound)
        let clampedRows = min(max(rows, Self.rowBounds.lowerBound), Self.rowBounds.upperBound)

        guard let client = await commandProvider(server) else {
            // Unknown/down server: nothing to resize. The counter is untouched.
            logger.debug("no command client for server \(server, privacy: .public); dropping resize")
            return
        }
        let key = WindowKey(server: server, windowID: windowID)
        // Increment AT SEND so a layout echo that races back before the fence
        // completes is already suppressed.
        increment(key)

        let resizeCommand = TmuxCommand(
            text: "resize-window -t \(windowID) -x \(clampedCols) -y \(clampedRows)",
            tolerateErrors: true
        ) { [logger] result in
            // A dead/gone window is a race, not an error — just debug-log.
            if case .failure(let error) = result {
                logger.debug("resize-window failed (window race): \(String(describing: error), privacy: .public)")
            }
        }
        // The echo fence. Its COMPLETION — success OR failure — closes the fence:
        // failure still decrements, because a dead window must not suppress its
        // key forever.
        let fenceCommand = TmuxCommand(
            text: "list-windows -F '#{window_id}'",
            tolerateErrors: true
        ) { [weak self] _ in
            self?.decrement(key)
        }
        // ONE stream write: `resize-window` THEN the fence are atomic in the
        // FIFO, so tmux processes the resize (emitting its layout echoes) strictly
        // before it replies to `list-windows`.
        await client.sendList([resizeCommand, fenceCommand])
    }

    /// Whether a `%layout-change` for this window should be applied. `false`
    /// while a resize we issued is still echoing (counter > 0): the notification
    /// is our own stale echo and is discarded, not reconciled (addendum §4).
    func shouldApplyLayoutChange(server: String, windowID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (outstanding[WindowKey(server: server, windowID: windowID)] ?? 0) == 0
    }

    private func increment(_ key: WindowKey) {
        lock.lock()
        outstanding[key, default: 0] += 1
        lock.unlock()
    }

    private func decrement(_ key: WindowKey) {
        lock.lock()
        let next = (outstanding[key] ?? 0) - 1
        if next <= 0 {
            outstanding.removeValue(forKey: key)  // floor at 0; remove to keep the map small
        } else {
            outstanding[key] = next
        }
        lock.unlock()
    }
}
