import Foundation
import TBDShared
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
    /// Latest-wins arbitration across the provider hop (R7-M1). Each `resize()`
    /// stamps a globally monotonic sequence per window AT ENTRY, before the
    /// `await commandProvider(...)` suspension; after the hop it re-checks and
    /// DROPS itself if a newer resize has been stamped since — SocketServer
    /// spawns an unstructured Task per RPC, so two concurrent calls can resolve
    /// the hop out of order, and without this the OLDER geometry lands on the
    /// wire last and sticks. Entries are cleared when the stamping call is done
    /// with them (fence completion, nil-provider drop) to keep the map small;
    /// the counter is global and never reset, so a fresh stamp after removal
    /// is still strictly newer.
    private var latestSequence: [WindowKey: UInt64] = [:]
    private var sequenceCounter: UInt64 = 0

    /// Sane geometry bounds. Garbage sizes from a mid-animation view (or a wildly
    /// wrong debounce sample) must not wedge tmux, which historically misbehaves
    /// on absurd dimensions — clamp before it ever reaches `resize-window`.
    /// The SHARED `ControlModeGeometry` envelope (R6-M5): the app's resize
    /// gate refuses to send below the same floor, so this clamp is a backstop
    /// for other/older clients, not a path our own app exercises.
    private static let colBounds = ControlModeGeometry.minCols...ControlModeGeometry.maxCols
    private static let rowBounds = ControlModeGeometry.minRows...ControlModeGeometry.maxRows

    init(commandProvider: @escaping @Sendable (String) async -> TmuxControlCommandClient?) {
        self.commandProvider = commandProvider
    }

    /// Issue a `resize-window` for `windowID` and open an echo fence. Called on
    /// the `pane.resize` RPC handler's task, once per debounced app resize.
    ///
    /// Latest-wins across the provider hop (R7-M1): concurrent calls for one
    /// window stamp a sequence before suspending; a call that resolves the hop
    /// only to find a newer stamp drops itself — the newer call sends. The
    /// residual window (a newer call completing its ENTIRE send between this
    /// call's re-check and its `sendList` enqueue) is far narrower than the
    /// provider hop and additionally guarded app-side by
    /// `ControlModeResizeSerializer`'s one-in-flight discipline.
    func resize(server: String, windowID: String, cols: Int, rows: Int) async {
        let clampedCols = min(max(cols, Self.colBounds.lowerBound), Self.colBounds.upperBound)
        let clampedRows = min(max(rows, Self.rowBounds.lowerBound), Self.rowBounds.upperBound)

        let key = WindowKey(server: server, windowID: windowID)
        // Stamp BEFORE the provider hop — this is what a concurrent newer
        // resize's re-check observes.
        let sequence = stampSequence(key)

        guard let client = await commandProvider(server) else {
            // Unknown/down server: nothing to resize. The counter is untouched.
            logger.debug("no command client for server \(server, privacy: .public); dropping resize")
            clearSequence(key, ifCurrent: sequence)
            return
        }
        guard isCurrentSequence(key, sequence) else {
            // A newer resize was stamped while this one was suspended in the
            // provider hop; sending now would put the OLDER size on the wire
            // last. Drop — the newer call sends. Counter untouched (only
            // sends that proceed open a fence).
            logger.debug("""
                dropping superseded resize for \(windowID, privacy: .public) \
                on \(server, privacy: .public) (a newer size was stamped mid-hop)
                """)
            return
        }
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
        //
        // Accepted residual (review F2): if the stream is wedged-but-ALIVE (the
        // write succeeded, but no reply block ever arrives and no EOF closes the
        // connection), the fence completion never fires, so the counter stays > 0
        // and layout changes for this window stay suppressed until the connection
        // tears down (`connectionClosed()` drains pending and decrements). This is
        // tolerated by design: a mute stream means control mode is wholly dead
        // (no `%output` either), so there is nothing to render or reconcile
        // anyway. Detecting and rebuilding a wedged connection is Phase B crash
        // recovery's job — do NOT add a timeout here.
        let fenceCommand = TmuxCommand(
            text: "list-windows -F '#{window_id}'",
            tolerateErrors: true
        ) { [weak self] _ in
            self?.decrement(key)
            // This send's stamp is spent; clear it unless a newer resize has
            // re-stamped the window (its own completion clears its own).
            self?.clearSequence(key, ifCurrent: sequence)
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

    /// Stamp `key` with the next global sequence and return it (R7-M1).
    private func stampSequence(_ key: WindowKey) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        sequenceCounter += 1
        latestSequence[key] = sequenceCounter
        return sequenceCounter
    }

    /// Whether `sequence` is still the newest stamp for `key` — i.e. no
    /// concurrent resize entered for this window since we stamped.
    private func isCurrentSequence(_ key: WindowKey, _ sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestSequence[key] == sequence
    }

    /// Remove `key`'s stamp iff it is still `sequence`, so windows that stop
    /// resizing don't accumulate entries forever. Never touches a newer stamp.
    private func clearSequence(_ key: WindowKey, ifCurrent sequence: UInt64) {
        lock.lock()
        if latestSequence[key] == sequence {
            latestSequence.removeValue(forKey: key)
        }
        lock.unlock()
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
