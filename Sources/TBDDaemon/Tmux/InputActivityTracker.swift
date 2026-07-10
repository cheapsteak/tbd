import Foundation
import os

/// Tracks the timestamp of the last keystroke recorded for each tmux pane,
/// enabling a daemon-side pending-input veto for auto-idle-hibernate that does
/// not depend on parsing the Claude TUI.
///
/// In-memory only, mirroring the coordinator's `idleSince` map. Keyed by
/// paneID (not terminal UUID) because the input router speaks paneIDs; a paneID
/// reused after respawn can only ADD a stale veto, never drop a real one —
/// the safe direction.
///
/// Lock-protected so the router's consumer can `recordInput` while nothing else
/// contends. The `now` seam lets tests drive time without real time.
final class InputActivityTracker: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "InputActivityTracker")
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    /// Maps paneID → last input timestamp (wall-clock Date, comparable to idleSince).
    private var lastInputByPane: [String: Date] = [:]

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Record that `paneID` received input at the current time.
    func recordInput(paneID: String) {
        lock.lock()
        lastInputByPane[paneID] = now()
        lock.unlock()
    }

    /// Return the timestamp of the last input recorded for `paneID`, or `nil`
    /// if no input has been recorded (e.g. post-restart, or a pane that has
    /// never received input).
    func lastInput(paneID: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastInputByPane[paneID]
    }

    /// Clear the recorded input timestamp for `paneID`. Called when a pane is
    /// respawned or closed.
    func forget(paneID: String) {
        lock.lock()
        lastInputByPane.removeValue(forKey: paneID)
        lock.unlock()
    }

    /// Drop recorded entries for panes not in `livePaneIDs`. Called during the
    /// idle sweep to prune stale entries alongside the coordinator's existing
    /// idleSince prune. Safe to call on any pane ID whether or not it has ever
    /// received input.
    func prune(keeping livePaneIDs: Set<String>) {
        lock.lock()
        lastInputByPane = lastInputByPane.filter { livePaneIDs.contains($0.key) }
        lock.unlock()
    }
}
