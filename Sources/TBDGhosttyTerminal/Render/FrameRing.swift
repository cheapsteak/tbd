// Adapted from tkzmux c961533 Sources/TkzTerminalRender/FrameRing.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// The per-surface instance-buffer ring.
//
// The renderer used to own a single 3-deep ring, which was right while exactly one surface was
// ever encoded per tick. With split panes it is not: N panes take N slots from the same ring in
// one tick, so a fourth pane blocks the **main thread** on `inflight.wait()` until the GPU has
// finished frame N-3. Deepening the ring only moves that wall, and leaves every pane's buffers
// sized to the largest pane on screen.
//
// So the ring belongs to the surface. Each pane gets three slots of its own, sized to its own
// content, and `TerminalSurface.detach()` drops the whole ring — which is what keeps "an
// unattached terminal costs only IO" true when a hidden view is torn down. A shared ring would
// never shrink back from the widest frame it had ever drawn.

import Metal

/// Three sets of instance buffers, cycled so the CPU can write frame N+2 while the GPU still reads
/// frame N.
///
/// Not `Sendable`, and it never crosses a thread: the slots and the cursor are only touched from
/// the render path (main thread). The one thing that does cross is the semaphore signal from a
/// Metal completion handler, and that goes through `Releaser` — a `Sendable` handle holding
/// nothing but the semaphore, which is exactly the split `DispatchSemaphore` exists for.
final class FrameRing {
    /// One frame's worth of instance buffers.
    final class Slot {
        var background: MTLBuffer?
        var glyphs: MTLBuffer?
        var rectsBelow: MTLBuffer?
        var rectsAbove: MTLBuffer?
    }

    /// The half of the ring that may leave the render thread: `release()` and nothing else.
    /// Captured by the command buffer's completion handler instead of the ring itself.
    struct Releaser: Sendable {
        fileprivate let inflight: DispatchSemaphore

        func release() {
            inflight.signal()
        }
    }

    static let depth = 3

    private let inflight = DispatchSemaphore(value: FrameRing.depth)
    private var slots: [Slot] = (0..<FrameRing.depth).map { _ in Slot() }
    /// The slot the last *committed* frame used. In-flight frames hold the slots ending here.
    private var index = 0
    /// The slot handed out by `acquire` and not yet committed or released.
    private var pending: Int?

    init() {}

    /// Blocks until a slot is free, then hands out the next one. Every `acquire` must be balanced
    /// by exactly one `commit` or `release`, including on every early return between them.
    ///
    /// The ring only moves on at `commit`. A frame that acquires and then bails gives its slot
    /// back unused, so the next frame takes the same slot; had the ring moved on, the next frame
    /// could land on a slot the GPU is still reading.
    func acquire() -> Slot {
        inflight.wait()
        let next = (index + 1) % FrameRing.depth
        pending = next
        return slots[next]
    }

    /// The acquired slot's frame is being committed: the slot is the GPU's until the command
    /// buffer's completion handler releases it through `releaser`.
    func commit() {
        if let pending { index = pending }
        pending = nil
    }

    /// Called directly on an encode that bailed before committing a command buffer: gives back
    /// both the permit and the slot. A committed buffer releases through `releaser` from its
    /// completion handler instead.
    func release() {
        pending = nil
        inflight.signal()
    }

    /// A `Sendable` handle that releases this ring's slot from a Metal completion handler.
    var releaser: Releaser {
        Releaser(inflight: inflight)
    }

    /// Total bytes the ring is holding. Diagnostics — with N panes this is the number that says
    /// what splitting actually costs.
    var byteCount: Int {
        slots.reduce(0) { total, slot in
            total + [slot.background, slot.glyphs, slot.rectsBelow, slot.rectsAbove]
                .reduce(0) { $0 + ($1?.length ?? 0) }
        }
    }
}
