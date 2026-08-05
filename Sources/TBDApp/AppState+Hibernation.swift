import Foundation
import AppKit
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.app", category: "Hibernation")

extension AppState {
    /// Outcome of one wake attempt, for EXPLICIT paths that can offer a
    /// follow-up. The focus path keeps using `wakeTerminal` (String?) and stays
    /// silent.
    enum WakeAttemptOutcome: Equatable {
        case ok
        case failed(message: String)
        /// The pinned profile is gone; carries what a fallback retry needs.
        case profileMissing(terminalID: UUID, worktreeID: UUID, message: String)
    }
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
        let minutes = min(max(Config.minHibernateIdleMinutes, idleMinutes), Config.maxHibernateIdleMinutes)
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

    /// Core explicit/implicit wake returning the structured outcome. `wakeTerminal`
    /// wraps this. `fallbackToDefaultProfile` opts into the ambient default login
    /// when the pinned profile is gone (used by the fallback retry).
    func wakeTerminalOutcome(terminalID: UUID, worktreeID: UUID, userInitiated: Bool,
                             fallbackToDefaultProfile: Bool) async -> WakeAttemptOutcome {
        guard !wakeInFlight.contains(terminalID) else { return .ok }  // in-flight dedupe = benign no-op
        wakeInFlight.insert(terminalID)
        defer { wakeInFlight.remove(terminalID) }
        do {
            let size = mainAreaTerminalSize()
            try await daemonClient.terminalWake(
                terminalID: terminalID, cols: size.cols, rows: size.rows,
                fallbackToDefaultProfile: fallbackToDefaultProfile)
            await refreshTerminals(worktreeID: worktreeID)
            return .ok
        } catch {
            let outcome = Self.wakeOutcome(
                forErrorCode: (error as? DaemonClientError)?.rpcCode,
                alreadyFallback: fallbackToDefaultProfile,
                terminalID: terminalID, worktreeID: worktreeID,
                message: error.localizedDescription)
            switch outcome {
            case .profileMissing:
                logger.warning("Wake refused (profile missing) for terminal \(terminalID, privacy: .public); offering default-account fallback")
            case .failed:
                if userInitiated {
                    logger.error("Failed to wake terminal \(terminalID, privacy: .public): \(error, privacy: .public)")
                } else {
                    logger.warning("Automatic wake failed for terminal \(terminalID, privacy: .public) (alert suppressed): \(error, privacy: .public)")
                }
            case .ok: break
            }
            return outcome
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
        switch await wakeTerminalOutcome(terminalID: terminalID, worktreeID: worktreeID,
                                         userInitiated: userInitiated, fallbackToDefaultProfile: false) {
        case .ok: return nil
        case .failed(let m): return m
        case .profileMissing(_, _, let m): return m
        }
    }

    /// Classify a wake error. A `.profileMissing`-coded RPC failure becomes the
    /// structured outcome ONLY when this wasn't already a fallback retry, so the
    /// offer can never loop. Everything else is a plain `.failed`.
    static func wakeOutcome(forErrorCode code: String?, alreadyFallback: Bool,
                            terminalID: UUID, worktreeID: UUID, message: String) -> WakeAttemptOutcome {
        if !alreadyFallback, code == RPCErrorCode.profileMissing.rawValue {
            return .profileMissing(terminalID: terminalID, worktreeID: worktreeID, message: message)
        }
        return .failed(message: message)
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

    /// Copy for the default-account fallback confirm. Pure so the wording is
    /// unit-tested; the actual modal is `confirmDefaultAccountFallback`.
    static func defaultAccountFallbackPrompt(count: Int) -> (message: String, informative: String, confirm: String) {
        let noun = count == 1 ? "This session was" : "\(count) sessions were"
        return (
            message: count == 1 ? "Wake this session on your default account?"
                                 : "Wake \(count) sessions on your default account?",
            informative: "\(noun) pinned to an account profile that no longer exists. You can wake on your default login instead, or cancel and restore the profile first.",
            confirm: count == 1 ? "Wake on Default Account" : "Wake \(count) on Default Account"
        )
    }

    /// Present the default-account fallback confirm. Returns true if the user
    /// chose to wake on the default account. Modal (mirrors CLIInstallerCoordinator).
    @MainActor
    func confirmDefaultAccountFallback(count: Int) -> Bool {
        let prompt = Self.defaultAccountFallbackPrompt(count: count)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = prompt.message
        alert.informativeText = prompt.informative
        alert.addButton(withTitle: prompt.confirm)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Concurrency bound for the explicit "Wake all parked" fan-out. Small on
    /// purpose: full parallelism caused the #367 spawn storm (N simultaneous
    /// heavy `claude --resume` respawns → RPC-timeout hang), so this caps
    /// in-flight respawns at 3 while still beating a fully-sequential walk on a
    /// 20-session worktree. The focus path stays ONE-at-a-time (see
    /// `wakeHibernatedTerminalsOnFocus`) — this bound is ONLY for the explicit
    /// user action.
    static let wakeAllBatchSize = 3

    /// Explicit user-initiated wake of ONE parked terminal, with the
    /// default-account fallback offer. On `.profileMissing`, confirm and retry
    /// with fallback. Surfaces any final failure as a coalesced alert. Focus
    /// path does NOT use this.
    func wakeParkedTerminalUserInitiated(terminalID: UUID, worktreeID: UUID) async {
        let outcome = await wakeTerminalOutcome(terminalID: terminalID, worktreeID: worktreeID,
                                                userInitiated: true, fallbackToDefaultProfile: false)
        var failure: String?
        switch outcome {
        case .ok: failure = nil
        case .failed(let m): failure = m
        case .profileMissing(let tid, let wid, let m):
            if confirmDefaultAccountFallback(count: 1) {
                switch await wakeTerminalOutcome(terminalID: tid, worktreeID: wid,
                                                 userInitiated: true, fallbackToDefaultProfile: true) {
                case .ok: failure = nil
                case .failed(let m2), .profileMissing(_, _, let m2): failure = m2
                }
            } else {
                failure = m  // declined → still show why it didn't wake
            }
        }
        if let failure, let message = Self.coalescedWakeFailureMessage(failures: [failure]) {
            showAlert(message, isError: true)
        }
    }

    /// Split parked-terminal ids into sequential batches of at most
    /// `batchSize`. Pure + static so the batching is unit-tested without a live
    /// `DaemonClient` (same pattern as `coalescedWakeFailureMessage`).
    static func wakeAllBatches(_ ids: [UUID], batchSize: Int = wakeAllBatchSize) -> [[UUID]] {
        guard batchSize > 0 else { return ids.isEmpty ? [] : [ids] }
        return stride(from: 0, to: ids.count, by: batchSize).map {
            Array(ids[$0 ..< min($0 + batchSize, ids.count)])
        }
    }

    /// Wake `ids` in bounded-concurrency batches (`wakeAllBatchSize` in flight,
    /// sequential batches), returning each outcome. Shared by the initial pass
    /// and the fallback retry.
    private func wakeBatched(_ ids: [UUID], worktreeID: UUID, fallbackToDefaultProfile: Bool) async -> [WakeAttemptOutcome] {
        var out: [WakeAttemptOutcome] = []
        for batch in Self.wakeAllBatches(ids) {
            let batchOutcomes = await withTaskGroup(of: WakeAttemptOutcome.self) { group in
                for id in batch {
                    group.addTask {
                        await self.wakeTerminalOutcome(terminalID: id, worktreeID: worktreeID,
                                                       userInitiated: true, fallbackToDefaultProfile: fallbackToDefaultProfile)
                    }
                }
                var collected: [WakeAttemptOutcome] = []
                for await o in group { collected.append(o) }
                return collected
            }
            out += batchOutcomes
        }
        return out
    }

    /// Explicit "Wake all parked in this worktree" action: wake EVERY parked
    /// (hibernated or legacy-suspended) Claude session in `worktreeID`, in
    /// bounded-concurrency batches (`wakeAllBatchSize` in flight, sequential
    /// batches). Deliberately NOT the focus default (one-per-focus) — this is
    /// the explicit fan-out users sometimes want. Folds all failures into ONE
    /// coalesced alert (never a modal per terminal).
    func wakeAllParkedInWorktree(worktreeID: UUID) async {
        let ids = (terminals[worktreeID] ?? []).filter { $0.isParked }.map { $0.id }
        let outcomes = await wakeBatched(ids, worktreeID: worktreeID, fallbackToDefaultProfile: false)
        var failures = outcomes.compactMap(\.failureMessage)
        let missing = outcomes.compactMap(\.profileMissingTerminalID)
        if !missing.isEmpty {
            if confirmDefaultAccountFallback(count: missing.count) {
                let retried = await wakeBatched(missing, worktreeID: worktreeID, fallbackToDefaultProfile: true)
                failures += retried.compactMap(\.anyFailureMessage)
            } else {
                failures += outcomes.compactMap(\.profileMissingMessage)  // declined → surface why
            }
        }
        if let message = Self.coalescedWakeFailureMessage(failures: failures) {
            showAlert(message, isError: true)
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
    /// navigates to them (activating their tab re-invokes this hook via
    /// `setActiveTab`). If the focused terminal can't be resolved to a parked
    /// row, fall back to waking at most one parked terminal — never a parallel
    /// fan-out.
    func wakeHibernatedTerminalsOnFocus(worktreeID: UUID) {
        guard let target = terminalIDToWakeOnFocus(worktreeID: worktreeID) else { return }
        // Wake exactly one; never a parallel fan-out (see the storm rationale above).
        Task { await wakeTerminal(terminalID: target, worktreeID: worktreeID, userInitiated: false) }
    }

    /// Pure decision behind `wakeHibernatedTerminalsOnFocus`: the single parked
    /// terminal (if any) to wake on focus. Three branches — (1) the focused
    /// terminal when it is itself parked AND resumable; (2) otherwise the first
    /// parked resumable terminal; (3) nil when none are parked/resumable.
    /// Extracted as a pure function so the fan-out choice is unit-tested without
    /// a live `DaemonClient`. Filters to `isClaudeResumable` to skip unresumable
    /// rows (e.g. legacy parked shell-kind rows with no claudeSessionID, which
    /// would fail "No session ID to resume" and shadow wakeable rows forever).
    ///
    /// Manually-parked sessions (`hibernateReason == .manual`) are excluded
    /// UP FRONT — before the focused-match and the `.first` fallback — so an
    /// explicit "Hibernate now" is never silently undone by navigating back to
    /// the worktree. They wake only via the explicit affordances (parked-pane
    /// click, Wake menu). nil-reason (legacy), auto, and recovery parks still
    /// focus-wake.
    func terminalIDToWakeOnFocus(worktreeID: UUID) -> UUID? {
        let parked = (terminals[worktreeID] ?? []).filter {
            $0.isParked && $0.isClaudeResumable && $0.hibernateReason != .manual
        }
        guard !parked.isEmpty else { return nil }
        if let focusedID = terminalIDForAutofocus(worktreeID: worktreeID),
           parked.contains(where: { $0.id == focusedID }) {
            return focusedID
        }
        return parked.first?.id
    }

    /// Pure decision for tab activation: the parked-and-resumable terminal ID(s)
    /// rendered by the newly-activated tab. Returns all such terminals in the
    /// tab's split layout — at most one tab, never a cross-tab fan-out. Empty
    /// when the tab has no terminals, none are parked, or none are resumable.
    /// Called by `setActiveTab` to wake only what the user is about to see,
    /// never a parallel spawn storm.
    func terminalIDsToWakeOnTabActivation(worktreeID: UUID, tabIndex: Int) -> [UUID] {
        guard let worktreeTabs = tabs[worktreeID], worktreeTabs.indices.contains(tabIndex) else { return [] }
        let tab = worktreeTabs[tabIndex]
        let terminalIDsInTab = terminalIDs(in: tab)
        return (terminals[worktreeID] ?? [])
            .filter { terminalIDsInTab.contains($0.id) && $0.isParked && $0.isClaudeResumable && $0.hibernateReason != .manual }
            .map { $0.id }
    }
}

extension AppState.WakeAttemptOutcome {
    /// `.failed` message only (nil otherwise).
    var failureMessage: String? { if case .failed(let m) = self { return m }; return nil }
    /// Any terminal failure message — `.failed` OR `.profileMissing` (used
    /// after a fallback retry, where `.profileMissing` shouldn't recur but is
    /// still a failure to report).
    var anyFailureMessage: String? {
        switch self {
        case .ok: return nil
        case .failed(let m): return m
        case .profileMissing(_, _, let m): return m
        }
    }
    var profileMissingTerminalID: UUID? { if case .profileMissing(let t, _, _) = self { return t }; return nil }
    var profileMissingMessage: String? { if case .profileMissing(_, _, let m) = self { return m }; return nil }
}
