import Foundation
import TBDShared

/// The bookkeeping behind the sidebar's no-status mark: which agent terminals
/// the app has seen sitting at `.unknown`, per incarnation, and whether each
/// has stayed there for `NoStatusMark.grace`. App memory only.
/// Design: `docs/specs/2026-10-30-osc-only-agent-status-design.md`, "Sessions
/// that cannot report".
extension AppState {
    /// Bring `noStatusSightings` in line with `terminals`.
    ///
    /// A candidate (`NoStatusMark.isCandidate`) with no sighting of its current
    /// incarnation gets a fresh one, plus a grace timer on `noStatusClock`. A
    /// terminal that stops being a candidate — it reported, parked, or left
    /// `terminals` — loses its sighting and its timer, and so does one whose
    /// incarnation changed, before it gets a fresh one. `terminals`' `didSet`
    /// calls this on every mutation outside `coalescingNoStatusReconcile`, and
    /// once at the end of one, so it writes `noStatusSightings` only to add or
    /// remove a sighting.
    func reconcileNoStatusSightings() {
        var candidates: [UUID: UUID?] = [:]
        for rows in terminals.values {
            for terminal in rows where NoStatusMark.isCandidate(terminal) {
                candidates[terminal.id] = terminal.sessionIncarnationID
            }
        }
        let stale = noStatusSightings.filter { terminalID, sighting in
            guard let incarnationID = candidates[terminalID] else { return true }
            return incarnationID != sighting.incarnationID
        }.keys
        for terminalID in stale {
            noStatusSightings.removeValue(forKey: terminalID)
            noStatusGraceTasks.removeValue(forKey: terminalID)?.cancel()
        }
        for (terminalID, incarnationID) in candidates where noStatusSightings[terminalID] == nil {
            noStatusSightings[terminalID] = NoStatusSighting(
                incarnationID: incarnationID, graceElapsed: false)
            startNoStatusGrace(terminalID: terminalID, incarnationID: incarnationID)
        }
    }

    /// `terminals`' `didSet`: reconcile now, or, inside
    /// `coalescingNoStatusReconcile`, once that call ends.
    func terminalsDidChangeForNoStatus() {
        if noStatusReconcileDepth > 0 {
            noStatusReconcilePending = true
        } else {
            reconcileNoStatusSightings()
        }
    }

    /// Run `body`, which may write `terminals` many times, and reconcile the
    /// sightings once when it ends rather than after every write. Each
    /// reconcile scans every terminal, and one run against a state `body`
    /// leaves only halfway — a woken row un-parked but still carrying its
    /// parked incarnation — would add a sighting and start a grace timer that
    /// the next write cancels. Nested calls reconcile once, when the outermost
    /// ends, and only if `terminals` changed.
    func coalescingNoStatusReconcile<T>(_ body: () throws -> T) rethrows -> T {
        noStatusReconcileDepth += 1
        defer {
            noStatusReconcileDepth -= 1
            if noStatusReconcileDepth == 0, noStatusReconcilePending {
                noStatusReconcilePending = false
                reconcileNoStatusSightings()
            }
        }
        return try body()
    }

    /// Wait out the grace for one sighting, then mark it elapsed. A timer
    /// cancelled by `reconcileNoStatusSightings` changes nothing: the
    /// cancellation and the post-sleep check both run on the main actor, so a
    /// sighting dropped first is never flipped by its old timer.
    private func startNoStatusGrace(terminalID: UUID, incarnationID: UUID?) {
        let clock = noStatusClock
        noStatusGraceTasks[terminalID]?.cancel()
        noStatusGraceTasks[terminalID] = Task { @MainActor [weak self] in
            try? await clock.sleep(for: NoStatusMark.grace)
            guard !Task.isCancelled else { return }
            self?.noStatusGraceElapsed(terminalID: terminalID, incarnationID: incarnationID)
        }
    }

    private func noStatusGraceElapsed(terminalID: UUID, incarnationID: UUID?) {
        guard let sighting = noStatusSightings[terminalID],
              sighting.incarnationID == incarnationID else { return }
        noStatusGraceTasks.removeValue(forKey: terminalID)
        guard !sighting.graceElapsed else { return }
        noStatusSightings[terminalID]?.graceElapsed = true
    }
}
