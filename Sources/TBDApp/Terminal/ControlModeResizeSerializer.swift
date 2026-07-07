import Foundation

/// Latest-wins serialization state for control-mode `pane.resize` RPCs
/// (R5-M3). The Coordinator's 100 ms debounce collapses a window-drag flurry
/// to its tail, but cancel-and-replace only cancels the wrapper Task — each
/// `paneResize` RPC rides its own socket task, so an already-in-flight resize
/// has no ordering against a newer one and can be processed AFTER it,
/// wedging the pane at a stale size until the next resize event.
///
/// This type keeps at most ONE resize in flight: a debounce tick that fires
/// while one is in flight stashes the latest size instead of sending, and the
/// in-flight call's completion sends the stash (the sender loops until
/// quiescent). Pure decision state, extracted so the branchy logic is
/// headlessly testable — mirrors `ControlModeResizeGate` / `PasteInterception`.
/// MainActor-confined by its owner (a Coordinator stored property), like the
/// rest of the resize/debounce state.
struct ControlModeResizeSerializer {
    struct Size: Equatable {
        let cols: Int
        let rows: Int
    }

    /// True from a `sizeToSend` that returned a size until the matching
    /// `completedInFlight` returns nil (quiescent).
    private(set) var inFlight = false
    /// The latest size that arrived while a send was in flight. Overwritten
    /// by newer ticks (latest wins); consumed by `completedInFlight`.
    private(set) var stashed: Size?

    /// A debounce tick fired with the latest size. Returns the size to send
    /// now — the caller becomes the in-flight sender — or nil when a send is
    /// already in flight: the size is stashed (overwriting any older stash)
    /// for the in-flight sender to pick up on completion.
    mutating func sizeToSend(cols: Int, rows: Int) -> Size? {
        let size = Size(cols: cols, rows: rows)
        if inFlight {
            stashed = size
            return nil
        }
        inFlight = true
        return size
    }

    /// The in-flight RPC completed. Returns the stashed size to send next —
    /// the caller stays the in-flight sender and must loop — or nil:
    /// quiescent, no send in flight anymore.
    mutating func completedInFlight() -> Size? {
        if let next = stashed {
            stashed = nil
            return next
        }
        inFlight = false
        return nil
    }

    /// Whether the drain loop may issue its next send (R6-M6). The loop
    /// deliberately ignores `Task.isCancelled` (a newer tick's cancel only
    /// means "your size was replaced — deliver my stash"), so without this
    /// check `cleanup()` could not stop a sender already past the debounce
    /// guard: it would keep firing `pane.resize` RPCs for a dead view. A
    /// torn-down coordinator stops draining outright — the stashed size is
    /// irrelevant post-teardown (the pane is detached or detaching; the next
    /// live view sends its own initial resize). Mirrors
    /// `ControlModeAttachAbort.shouldStartFallback`'s pure-gate shape.
    static func shouldContinueDraining(tornDown: Bool) -> Bool {
        !tornDown
    }
}
