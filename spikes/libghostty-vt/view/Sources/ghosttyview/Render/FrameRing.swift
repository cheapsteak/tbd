// Adapted from tkzmux c961533 Sources/TkzTerminalRender/FrameRing.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
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
// unattached terminal costs only IO" true when a hidden tab's panes are torn down. That is
// strictly better than before, where the shared ring never shrank back from the widest frame it
// had ever drawn.

import Metal

/// Three sets of instance buffers, cycled so the CPU can write frame N+2 while the GPU still reads
/// frame N.
///
/// Not `Sendable`, and it never crosses a thread: the slots and the cursor are only touched from
/// the render path (main thread). The one thing that does cross is the semaphore signal from a
/// Metal completion handler, and that goes through `Releaser` — a `Sendable` handle holding
/// nothing but the semaphore, which is exactly the split `DispatchSemaphore` exists for.
public final class FrameRing {
    /// One frame's worth of instance buffers.
    final class Slot {
        var background: MTLBuffer?
        var glyphs: MTLBuffer?
        var rectsBelow: MTLBuffer?
        var rectsAbove: MTLBuffer?
    }

    /// The half of the ring that may leave the render thread: `release()` and nothing else.
    /// Captured by the command buffer's completion handler instead of the ring itself.
    public struct Releaser: Sendable {
        fileprivate let inflight: DispatchSemaphore

        public func release() {
            inflight.signal()
        }
    }

    public static let depth = 3

    private let inflight = DispatchSemaphore(value: FrameRing.depth)
    private var slots: [Slot] = (0..<FrameRing.depth).map { _ in Slot() }
    private var index = 0

    public init() {}

    /// Blocks until a slot is free, then hands out the next one. Every `acquire` must be balanced
    /// by exactly one `release`, including on every early return between them.
    func acquire() -> Slot {
        inflight.wait()
        index = (index + 1) % FrameRing.depth
        return slots[index]
    }

    /// Called directly on an encode that bailed before committing a command buffer. A committed
    /// buffer releases through `releaser` from its completion handler instead.
    public func release() {
        inflight.signal()
    }

    /// A `Sendable` handle that releases this ring's slot from a Metal completion handler.
    public var releaser: Releaser {
        Releaser(inflight: inflight)
    }

    /// Total bytes the ring is holding. Diagnostics — with N panes this is the number that says
    /// what splitting actually costs (docs/perf.md).
    public var byteCount: Int {
        slots.reduce(0) { total, slot in
            total + [slot.background, slot.glyphs, slot.rectsBelow, slot.rectsAbove]
                .reduce(0) { $0 + ($1?.length ?? 0) }
        }
    }
}
