// Adapted from tkzmux c961533 Sources/TkzTerminalRender/FrameRing.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// `tryAcquire()`, which drops a frame rather than wait for the GPU, adapted from termio 8196587 Shared/Sources/TermioStream/TermiodStreamRenderer.swift (MIT, see LICENSE-termio.txt).
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
//
// A display tick never waits for a slot. It checks `hasFreeSlot` before it builds anything and
// takes its slot with `tryAcquire()`, so a ring the GPU still holds whole drops the frame, and
// the next tick draws the newer screen. Only a live resize and `drawFrameNow()` wait, in
// `acquire()`.

import Metal
import Synchronization

/// Three sets of instance buffers, cycled so the CPU can write frame N+2 while the GPU still reads
/// frame N.
///
/// Not `Sendable`, and it never crosses a thread: the slots and the cursor are only touched from
/// the render path (main thread). The one thing that does cross is the release from a Metal
/// completion handler, and that goes through `Releaser` — a `Sendable` handle holding nothing but
/// the permits and the count of slots in flight.
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
        fileprivate let inflight: Inflight

        func release() {
            inflight.releaseCommitted()
        }
    }

    /// The permits, and how many committed frames the GPU still holds. Shared by the ring and
    /// every completion handler, so a ring dropped by a detach still gets its slots back.
    fileprivate final class Inflight: Sendable {
        let permits = DispatchSemaphore(value: FrameRing.depth)
        /// Frames committed and not yet released by their completion handler. Raised on main at
        /// `commit()`, lowered on Metal's completion thread.
        let committed = Atomic<Int>(0)

        func releaseCommitted() {
            // The permit first, then the count. A reader that sees the count drop then finds the
            // permit there too, so `hasFreeSlot` never says yes to a `tryAcquire()` that fails.
            permits.signal()
            committed.wrappingSubtract(1, ordering: .releasing)
        }
    }

    static let depth = 3

    private let inflight = Inflight()
    private var slots: [Slot] = (0..<FrameRing.depth).map { _ in Slot() }
    /// The slot the last *committed* frame used. In-flight frames hold the slots ending here.
    private var index = 0
    /// The slot handed out by `acquire` or `tryAcquire` and not yet committed or released.
    private var pending: Int?

    init() {}

    /// Blocks until a slot is free, then hands out the next one. Every `acquire` must be balanced
    /// by exactly one `commit` or `release`, including on every early return between them.
    ///
    /// Only for a frame that may not be dropped: a live resize, whose transaction must end with a
    /// present, and `drawFrameNow()`. A display tick uses `tryAcquire()`.
    ///
    /// The ring only moves on at `commit`. A frame that acquires and then bails gives its slot
    /// back unused, so the next frame takes the same slot; had the ring moved on, the next frame
    /// could land on a slot the GPU is still reading.
    func acquire() -> Slot {
        inflight.permits.wait()
        return takeNext()
    }

    /// The next slot, or nil at once when the GPU still holds all three. Balanced like `acquire`.
    func tryAcquire() -> Slot? {
        guard inflight.permits.wait(timeout: .now()) == .success else { return nil }
        return takeNext()
    }

    private func takeNext() -> Slot {
        let next = (index + 1) % FrameRing.depth
        pending = next
        return slots[next]
    }

    /// The acquired slot's frame is being committed: the slot is the GPU's until the command
    /// buffer's completion handler releases it through `releaser`.
    func commit() {
        guard let pending else { return }
        index = pending
        self.pending = nil
        inflight.committed.wrappingAdd(1, ordering: .relaxed)
    }

    /// Called directly on an encode that bailed before committing a command buffer: gives back
    /// both the permit and the slot. A committed buffer releases through `releaser` from its
    /// completion handler instead.
    func release() {
        pending = nil
        inflight.permits.signal()
    }

    /// A `Sendable` handle that releases this ring's slot from a Metal completion handler.
    var releaser: Releaser {
        Releaser(inflight: inflight)
    }

    /// Whether a slot is free, read without taking one. Main thread, which is the only thread
    /// that takes slots, so a yes here stays true until main takes one.
    var hasFreeSlot: Bool {
        inflight.committed.load(ordering: .acquiring) + (pending == nil ? 0 : 1) < FrameRing.depth
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
