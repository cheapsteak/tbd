import Foundation

/// The holder work still unsettled for each terminal, keyed by terminal ID,
/// so a panel that is about to attach to a session can wait for the panel it
/// replaces to let go of it.
///
/// An entry is one of three things, and the ledger treats them alike: a live
/// panel's handback (`pane.detach` carrying its screen), the release of an
/// attach a panel abandoned before it was confirmed (`attach.ready` then
/// `pane.detach`), or an attach that is itself still in progress — pending at
/// the daemon, with no release registered yet because its panel has not
/// reached an exit. Each one can leave the daemon holding the session for
/// this terminal until it completes.
///
/// Two `TerminalPanelView`s for one terminal overlap whenever SwiftUI swaps
/// the view type that hosts the terminal — a tab whose layout goes from a
/// single pane to a split, or back, tears the old panel down and builds a new
/// one in the same update. The old coordinator's handback is asynchronous: it
/// stops its reader, serializes the screen, and only then sends `pane.detach`,
/// which is what releases the daemon's viewer claim. An attach sent before
/// that RPC returns is refused as "attached to viewer", and a refusal has no
/// retry, so the new panel would paint a placard over a healthy session.
///
/// The ledger makes the wait deterministic instead of timed: the predecessor
/// registers its task, and the successor awaits it. When the detach RPC has
/// returned, the daemon has already processed it — resumed its own reader and
/// cleared any claim the detach could clear — so an attach issued after the
/// awaited task completes does not race it. A terminal with nothing unsettled waits for nothing.
///
/// Free of `AppState` so it can be unit-tested on its own; `AppState` holds
/// the one instance the coordinators share.
@MainActor
final class HolderHandbackLedger {
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    init() {}

    /// Records `task` as the unsettled work for `terminalID` — a handback, an
    /// abandoned attach's release, or an attach still in progress.
    ///
    /// When the task finishes it removes its own entry, but only if the entry
    /// is still that task: a newer registration for the same terminal wins,
    /// and an older task completing must not erase it.
    func register(terminalID: UUID, task: Task<Void, Never>) {
        inFlight[terminalID] = task
        Task { @MainActor [weak self] in
            await task.value
            guard let self, self.inFlight[terminalID] == task else { return }
            self.inFlight[terminalID] = nil
        }
    }

    /// Drops `task`'s entry for `terminalID` now, rather than on the
    /// completion hop `register` schedules — but only while the entry is still
    /// that task, so a newer registration survives.
    ///
    /// For a caller that finishes a registered task itself and wants the
    /// ledger to say so by the time it returns: an attach's own "still
    /// settling" entry, withdrawn as the attach ends, would otherwise read as
    /// in flight for one more actor turn.
    func withdraw(terminalID: UUID, task: Task<Void, Never>) {
        guard inFlight[terminalID] == task else { return }
        inFlight[terminalID] = nil
    }

    /// Whether anything is still unsettled for `terminalID`: a handback, an
    /// abandoned attach's release, or an attach still in progress.
    func isInFlight(terminalID: UUID) -> Bool {
        inFlight[terminalID] != nil
    }

    /// Suspends until nothing is unsettled for `terminalID`.
    ///
    /// Loops rather than awaiting once: a second entry can be registered
    /// while the first is being awaited, and the caller wants the session
    /// free, not merely one predecessor finished. Returns immediately when
    /// nothing is registered.
    ///
    /// - Returns: `true` when at least one entry was actually waited on.
    @discardableResult
    func awaitSettled(terminalID: UUID) async -> Bool {
        var waited = false
        while let task = inFlight[terminalID] {
            waited = true
            await task.value
            // The completion hop in `register` clears this entry one actor
            // turn later; clearing it here as well, if it is still the task
            // just awaited, keeps the loop from spinning on a finished task
            // until that hop runs.
            if inFlight[terminalID] == task {
                inFlight[terminalID] = nil
            }
        }
        return waited
    }
}
