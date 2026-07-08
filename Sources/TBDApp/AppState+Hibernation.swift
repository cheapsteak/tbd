import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "Hibernation")

extension AppState {
    /// Load the auto-hibernate config (master switch + idle minutes) from the
    /// daemon `Config`. Called on launch and whenever a config-change delta
    /// arrives. Silent on failure — the Settings toggle just shows stale
    /// values until the next successful load.
    func loadHibernationConfig() async {
        guard let config = try? await daemonClient.getConfig() else { return }
        if config.autoHibernateEnabled != autoHibernateEnabled {
            autoHibernateEnabled = config.autoHibernateEnabled
        }
        if config.hibernateIdleMinutes != hibernateIdleMinutes {
            hibernateIdleMinutes = config.hibernateIdleMinutes
        }
    }

    /// Persist the auto-hibernate master switch + idle timeout, updating local
    /// published state optimistically.
    func setAutoHibernate(enabled: Bool, idleMinutes: Int) async {
        let minutes = max(1, idleMinutes)
        do {
            try await daemonClient.setAutoHibernate(enabled: enabled, idleMinutes: minutes)
            autoHibernateEnabled = enabled
            hibernateIdleMinutes = minutes
        } catch {
            logger.error("Failed to set auto-hibernate config: \(error, privacy: .public)")
            showAlert("Failed to update hibernation setting: \(error.localizedDescription)", isError: true)
        }
    }

    /// Manually hibernate one Claude terminal. The daemon enforces the
    /// running/permission rails and returns an error string we surface.
    func hibernateTerminal(terminalID: UUID, worktreeID: UUID) async {
        do {
            try await daemonClient.terminalHibernate(terminalID: terminalID)
            await refreshTerminals(worktreeID: worktreeID)
        } catch {
            logger.error("Failed to hibernate terminal: \(error, privacy: .public)")
            showAlert("Couldn't hibernate: \(error.localizedDescription)", isError: false)
        }
    }

    /// Wake a hibernated terminal (respawn `claude --resume`). Idempotent and
    /// singleflighted on the app side: a second call while one is in flight is
    /// dropped, so double-focus never fires two respawns.
    ///
    /// Never shows an alert itself — it returns the failure message (nil on
    /// success) so CALL SITES decide how to surface it: the explicit Wake menu
    /// action shows ONE coalesced alert for its whole batch (see
    /// `coalescedWakeFailureMessage`), while automatic focus-wakes stay silent
    /// — otherwise every worktree focus after a reboot (which kills all tmux
    /// windows) fired a modal per parked terminal. `userInitiated` drives the
    /// failure log level (explicit action → error; background → warning).
    @discardableResult
    func wakeTerminal(terminalID: UUID, worktreeID: UUID, userInitiated: Bool) async -> String? {
        guard !wakeInFlight.contains(terminalID) else { return nil }
        wakeInFlight.insert(terminalID)
        defer { wakeInFlight.remove(terminalID) }
        do {
            let size = mainAreaTerminalSize()
            try await daemonClient.terminalWake(
                terminalID: terminalID, cols: size.cols, rows: size.rows
            )
            await refreshTerminals(worktreeID: worktreeID)
            return nil
        } catch {
            if userInitiated {
                logger.error("Failed to wake terminal \(terminalID, privacy: .public): \(error, privacy: .public)")
            } else {
                logger.warning("Automatic wake failed for terminal \(terminalID, privacy: .public) (alert suppressed): \(error, privacy: .public)")
            }
            return error.localizedDescription
        }
    }

    /// Pure decision/formatting seam behind the explicit Wake menu action's
    /// COALESCED failure alert: `nil` for no failures (no alert), the bare
    /// message for a single failure, and a count-prefixed message when several
    /// wakes failed — one modal per user action, never one per terminal.
    /// Extracted as a pure function so every branch is unit-tested without a
    /// live `DaemonClient` (same pattern as `terminalIDToWakeOnFocus`).
    static func coalescedWakeFailureMessage(failures: [String]) -> String? {
        guard let first = failures.first else { return nil }
        if failures.count == 1 {
            return "Couldn't wake session: \(first)"
        }
        return "Couldn't wake \(failures.count) sessions: \(first)"
    }

    /// Toggle a terminal's keep-warm pin (exempts it from auto-hibernation).
    func setTerminalKeepWarm(terminalID: UUID, keepWarm: Bool, worktreeID: UUID) async {
        do {
            try await daemonClient.terminalSetKeepWarm(terminalID: terminalID, keepWarm: keepWarm)
            // Optimistic local update; the daemon also broadcasts a delta.
            if let idx = terminals[worktreeID]?.firstIndex(where: { $0.id == terminalID }) {
                terminals[worktreeID]?[idx].keepWarm = keepWarm
            }
        } catch {
            logger.error("Failed to set keep-warm: \(error, privacy: .public)")
            showAlert("Failed to update keep-warm: \(error.localizedDescription)", isError: true)
        }
    }

    /// Auto-wake the PARKED Claude terminal the user is actually about to look
    /// at in a worktree they just focused/selected. Covers both hibernated
    /// (authoritative) and legacy suspended rows — wake is the one resume path.
    /// Called from the selection-change hook. Idempotent via `wakeTerminal`'s
    /// in-flight guard, so double-focus is safe.
    ///
    /// Deliberately does NOT wake every parked terminal in the worktree. A
    /// worktree with ~20+ hibernated sessions on ONE tmux server used to fire
    /// that many simultaneous `respawn-window -k … claude --resume` (heavy Node)
    /// spawns on focus → a spawn storm that queued respawns past the app's 300s
    /// RPC ceiling → the "recv timed out after 300s" hang, which then re-fired
    /// on the next focus (~5-min loop) and re-inflated memory/swap each cycle.
    ///
    /// Strategy: wake ONLY the terminal that autofocus will surface (the active
    /// tab's terminal). The rest stay hibernated until the user actually
    /// navigates to them (selecting their tab re-invokes this hook). If the
    /// focused terminal can't be resolved to a parked row, fall back to waking
    /// at most one parked terminal — never a parallel fan-out.
    func wakeHibernatedTerminalsOnFocus(worktreeID: UUID) {
        guard let target = terminalIDToWakeOnFocus(worktreeID: worktreeID) else { return }
        // Wake exactly one; never a parallel fan-out (see the storm rationale above).
        Task { await wakeTerminal(terminalID: target, worktreeID: worktreeID, userInitiated: false) }
    }

    /// Pure decision behind `wakeHibernatedTerminalsOnFocus`: the single parked
    /// terminal (if any) to wake on focus. Three branches — (1) the focused
    /// terminal when it is itself parked; (2) otherwise the first parked
    /// terminal; (3) nil when none are parked. Extracted as a pure function so
    /// the fan-out choice is unit-tested without a live `DaemonClient`.
    ///
    /// Manually-parked sessions (`hibernateReason == .manual`) are excluded
    /// UP FRONT — before the focused-match and the `.first` fallback — so an
    /// explicit "Hibernate now" is never silently undone by navigating back to
    /// the worktree. They wake only via the explicit affordances (parked-pane
    /// click, Wake menu). nil-reason (legacy), auto, and recovery parks still
    /// focus-wake.
    func terminalIDToWakeOnFocus(worktreeID: UUID) -> UUID? {
        let parked = (terminals[worktreeID] ?? []).filter {
            $0.isParked && $0.hibernateReason != .manual
        }
        guard !parked.isEmpty else { return nil }
        if let focusedID = terminalIDForAutofocus(worktreeID: worktreeID),
           parked.contains(where: { $0.id == focusedID }) {
            return focusedID
        }
        return parked.first?.id
    }
}
