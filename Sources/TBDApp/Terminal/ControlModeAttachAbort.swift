import Foundation

/// Pure decision for the in-flight-attach vs view-teardown race (review H2).
///
/// `startControlModeClient` commits resources across several `await`
/// resumptions: `openAttach` vends an fd, the reader registers (and owns the
/// fd from then on), `attach.ready` opens the daemon's write gate. The view's
/// `cleanup()` can run between any two of them — and its attach-teardown
/// block only fires when `controlModeAttach` is already set, so an attach
/// that resolves AFTER the teardown would otherwise leak: an fd nobody
/// closes, a reader thread parked in `read()` forever, and a phantom daemon
/// attach nothing ever detaches. Each resumption therefore re-checks the
/// coordinator's torn-down flag through `undo(tornDown:at:)` and unwinds
/// exactly what is committed at that stage. Extracted so the gated branches
/// carry no untested conditional — mirrors `ControlModeResizeGate` /
/// `PasteInterception` / `OutgoingInputRoute`.
enum ControlModeAttachAbort {
    /// Where the attach sequence is when it resumes from an `await`.
    enum Stage: CaseIterable {
        /// `openAttach` resolved: fd received, generation known. The reader
        /// is NOT yet registered (nothing owns the fd but this frame) and no
        /// AppState bookkeeping exists.
        case openAttachResolved
        /// The reader is registered in the registry, which owns the fd now.
        case readerRegistered
        /// `attach.ready` acked: the daemon's gate is open. The AppState
        /// attach record is still NOT created (that happens after this
        /// checkpoint), so there is nothing extra to unwind beyond the
        /// reader + daemon attach.
        case attachReadyAcked
    }

    /// What a late-resolving attach must unwind, given the stage it reached.
    /// Every abort ALSO sends a generation-scoped `pane.detach` (idempotent
    /// against `cleanup()`'s own detach for the same generation, and unable
    /// to kill a successor attach's sink) — that part is unconditional, so
    /// it is not modeled here.
    struct Undo: Equatable {
        /// Close the vended fd directly — the reader doesn't own it yet.
        let closeFD: Bool
        /// Remove the reader from the registry (flags its thread stopped;
        /// the reader closes its own fd once the detach EOFs the pipe).
        let removeReader: Bool
    }

    /// Non-nil when the sequence must abort: the view was torn down while
    /// the awaited call was in flight.
    static func undo(tornDown: Bool, at stage: Stage) -> Undo? {
        guard tornDown else { return nil }
        switch stage {
        case .openAttachResolved:
            return Undo(closeFD: true, removeReader: false)
        case .readerRegistered, .attachReadyAcked:
            return Undo(closeFD: false, removeReader: true)
        }
    }

    /// Whether the grouped-sessions fallback PTY (and the NSEvent monitors
    /// `startTmuxClient` installs) may start: never after teardown — the
    /// view is gone, and nothing would ever terminate the spawned attach
    /// client process.
    static func shouldStartFallback(tornDown: Bool) -> Bool {
        !tornDown
    }
}
