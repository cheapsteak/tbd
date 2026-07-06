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
    func wakeTerminal(terminalID: UUID, worktreeID: UUID) async {
        guard !wakeInFlight.contains(terminalID) else { return }
        wakeInFlight.insert(terminalID)
        defer { wakeInFlight.remove(terminalID) }
        do {
            let size = mainAreaTerminalSize()
            try await daemonClient.terminalWake(
                terminalID: terminalID, cols: size.cols, rows: size.rows
            )
            await refreshTerminals(worktreeID: worktreeID)
        } catch {
            logger.error("Failed to wake terminal: \(error, privacy: .public)")
            showAlert("Couldn't wake session: \(error.localizedDescription)", isError: true)
        }
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

    /// Auto-wake any PARKED Claude terminals in a worktree the user just
    /// focused/selected. Covers both hibernated (authoritative) and legacy
    /// suspended rows — wake is the one resume path. Called from the
    /// selection-change hook. Idempotent via `wakeTerminal`'s in-flight guard,
    /// so double-focus is safe.
    func wakeHibernatedTerminalsOnFocus(worktreeID: UUID) {
        let hibernated = (terminals[worktreeID] ?? []).filter { $0.isParked }
        guard !hibernated.isEmpty else { return }
        for terminal in hibernated {
            Task { await wakeTerminal(terminalID: terminal.id, worktreeID: worktreeID) }
        }
    }
}
