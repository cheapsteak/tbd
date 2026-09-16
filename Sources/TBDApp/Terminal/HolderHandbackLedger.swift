import Foundation

/// The in-flight holder handbacks, keyed by terminal ID, so a panel that is
/// about to attach to a session can wait for the panel it replaces to finish
/// handing that session back.
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
/// registers its handback task, and the successor awaits it. When the detach
/// RPC has returned, the daemon has already resumed its own reader and cleared
/// the claim, so an attach issued after the awaited task completes succeeds
/// without a race. A terminal with no handback in flight waits for nothing.
///
/// Free of `AppState` so it can be unit-tested on its own; `AppState` holds
/// the one instance the coordinators share.
@MainActor
final class HolderHandbackLedger {
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    init() {}

    /// Records `task` as the handback in flight for `terminalID`.
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

    /// Whether a handback is currently in flight for `terminalID`.
    func isInFlight(terminalID: UUID) -> Bool {
        inFlight[terminalID] != nil
    }

    /// Suspends until no handback is in flight for `terminalID`.
    ///
    /// Loops rather than awaiting once: a second handback can be registered
    /// while the first is being awaited, and the caller wants the session
    /// free, not merely one predecessor finished. Returns immediately when
    /// nothing is registered.
    ///
    /// - Returns: `true` when at least one handback was actually waited on.
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
