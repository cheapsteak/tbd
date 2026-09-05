import Darwin
import Dispatch
import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "outgoingDrain")

/// Tells `OutgoingInputQueue` when the session's pty can take more.
///
/// **Armed only while the outbox is non-empty**, and that is measured, not
/// stylistic: readiness notification is level-triggered, so a notifier left
/// armed over a writable descriptor and an empty outbox fires tens to hundreds
/// of thousands of times per second (44,486 / 182,060 / 47,845 across three
/// measured runs). The queue disarms on the edge where the outbox empties, and
/// the implementation below makes `arm`/`disarm` idempotent so that edge can be
/// signalled more than once without unbalancing anything.
@MainActor
protocol OutgoingDrainNotifier: AnyObject {
    /// Start reporting readiness. Idempotent.
    func arm()
    /// Stop reporting it. Idempotent.
    func disarm()
    /// Permanent teardown. After this the notifier never calls back, whatever
    /// the descriptor does. Idempotent.
    func cancel()
}

/// A `DispatchSource` write source on the main queue. Its handler is main-actor
/// by construction (the source's queue is `.main`), so `assumeIsolated` is
/// sound and the drain runs on the same executor as every append.
///
/// ## The suspend count is the whole safety story
///
/// A `DispatchSource` is created suspended. `resume()` and `suspend()` are a
/// **counted** pair, and libdispatch traps (SIGTRAP 133) on the release of a
/// source whose count is non-zero — as it does on an over-resume. Every one of
/// these was measured fatal: releasing while suspended, `suspend → cancel →
/// release` with no rebalancing resume, two suspends against one resume, and
/// `resume` on an already-running source.
///
/// So this type keeps the count in {0, 1} and tracks which it is. `isArmed`
/// is not a convenience: it is what makes a second `arm()` or a second
/// `disarm()` a no-op instead of a crash, and it is what tells `cancel()`
/// whether a resume is owed.
@MainActor
final class WriteSourceDrainNotifier: OutgoingDrainNotifier {
    private var source: (any DispatchSourceWrite)?
    /// `true` when the source is running (suspend count 0), `false` when it is
    /// suspended (count 1). A source starts suspended, so this starts `false`.
    private var isArmed = false

    init(fileDescriptor: Int32, onWritable: @escaping @MainActor () -> Void) {
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: fileDescriptor, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { onWritable() }
        }
        self.source = source
    }

    func arm() {
        guard let source, !isArmed else { return }
        isArmed = true
        source.resume()
    }

    /// Called on the edge where the outbox empties, and it must not be skipped:
    /// see the fires-per-second measurement in this file's protocol comment.
    func disarm() {
        guard let source, isArmed else { return }
        isArmed = false
        source.suspend()
    }

    /// **Cancel, then rebalance to a suspend count of zero, then release.**
    ///
    /// A notifier at teardown is usually *suspended* — the ordinary state is an
    /// empty outbox — and releasing it there is the SIGTRAP. The resume after
    /// the cancel is what returns the count to zero; it cannot deliver an
    /// event, because a cancelled source's event handler does not run and this
    /// call is already on the source's own serial queue.
    ///
    /// It also has a second job. After `suspend → cancel`, a cancel handler
    /// does **not** run until the rebalancing resume lands (measured: still
    /// unrun 0.5 s later). This type installs no cancel handler precisely so
    /// nothing important waits on that; if one is ever added — to close a
    /// descriptor, say — it will not run until this resume, and anything
    /// ordered after it must account for the deferral.
    func cancel() {
        guard let source else { return }
        self.source = nil
        source.cancel()
        if !isArmed { source.resume() }   // count back to zero before release
        isArmed = true                    // running, cancelled, and safe to drop
        logger.debug(
            "writeSourceDrainNotifier: cancelled, suspend count rebalanced before release")
    }
}
