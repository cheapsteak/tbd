import Darwin
import Dispatch
import Foundation
import Testing

@testable import TBDApp
import TestSupport

/// A pipe whose write end is empty, and therefore always writable. It stands in
/// for the panel's pty descriptor for the one question these tests ask — does
/// this adapter's `arm` / `disarm` / `cancel` reach the source's counted
/// suspend/resume pair correctly — without needing a child process. Task 1 of
/// the plan already measured that write-readiness fires on a `dup` of a pty
/// master; that is the platform's behaviour, and it is not re-litigated here.
@MainActor
private final class WritablePipe {
    let readEnd: Int32
    let writeEnd: Int32

    init() {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { pipe($0.baseAddress!) }
        precondition(rc == 0, "pipe() failed: \(errno)")
        readEnd = fds[0]
        writeEnd = fds[1]
    }

    /// Close only after the source over `writeEnd` has been cancelled *and* the
    /// cancellation has had a turn of the main queue to land. Closing a
    /// descriptor a live source still watches is a use-after-close the moment
    /// the kernel reissues the number.
    func close() {
        Darwin.close(readEnd)
        Darwin.close(writeEnd)
    }
}

/// Mutable state a `@MainActor` event handler can reach without capturing the
/// notifier that owns it strongly (the source retains the handler, so a strong
/// capture would be a cycle).
@MainActor
private final class DrainRecorder {
    var notifier: WriteSourceDrainNotifier?
    var fires = 0
    var firesAfterDisarm = 0
    var firesAfterCancel = 0
}

/// `.serialized` because each test arms a source on the main queue and then
/// waits on the main actor for it to fire; running two of them concurrently
/// would have each one's wait competing with the other's handler for the same
/// executor. `.clockDriven` is the hang bound: a notifier that never fires
/// would otherwise sit in the poll loop, and the loop's own deadline is the
/// first line of defence rather than the only one.
@MainActor
@Suite("WriteSourceDrainNotifier", .clockDriven, .serialized)
struct OutgoingDrainNotifierTests {
    /// Poll the main actor until `condition` holds or the deadline passes.
    /// Sleeping yields the main actor, which is what lets the source's handler
    /// — dispatched to `.main` — run at all.
    private func waitUntil(
        _ condition: () -> Bool,
        within seconds: Double = 5
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Let anything already queued on the main queue run, so "it did not fire
    /// again" is a reading rather than an assumption.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    @Test("arm() reports readiness, and disarm() stops it")
    func armThenDisarm() async {
        let pipe = WritablePipe()
        let recorder = DrainRecorder()
        recorder.notifier = WriteSourceDrainNotifier(
            fileDescriptor: pipe.writeEnd
        ) { [weak recorder] in
            guard let recorder else { return }
            recorder.fires += 1
            if recorder.fires == 1 {
                recorder.notifier?.disarm()
            } else {
                // A disarm that did not reach `suspend()` leaves a level-
                // triggered source firing tens of thousands of times a second
                // (Task 1: 44,486 / 182,060 / 47,845). Cancelling on the
                // second fire stops that at once so the run reddens quickly
                // instead of spending the suite's time limit with the main
                // queue pinned. Measured: with `suspend()` removed the run
                // dies on SIGTRAP rather than on this expectation, because a
                // disarm that did not suspend makes the very next cancel an
                // over-resume. Red either way; the signal is not the message.
                recorder.firesAfterDisarm += 1
                recorder.notifier?.cancel()
            }
        }

        // Nothing before the arm: the source is created suspended.
        await settle()
        #expect(recorder.fires == 0)

        recorder.notifier?.arm()
        await waitUntil { recorder.fires > 0 }
        #expect(recorder.fires == 1, "an armed source over a writable pipe must report readiness")

        await settle()
        #expect(
            recorder.firesAfterDisarm == 0,
            "disarm() must suspend the source; a level-triggered source left armed spins")

        recorder.notifier?.cancel()
        await settle()
        pipe.close()
    }

    @Test("cancel() ends delivery for good, including from inside the handler")
    func cancelStopsDelivery() async {
        let pipe = WritablePipe()
        let recorder = DrainRecorder()
        recorder.notifier = WriteSourceDrainNotifier(
            fileDescriptor: pipe.writeEnd
        ) { [weak recorder] in
            guard let recorder else { return }
            recorder.fires += 1
            if recorder.fires == 1 {
                recorder.notifier?.cancel()
            } else {
                recorder.firesAfterCancel += 1
            }
        }

        recorder.notifier?.arm()
        await waitUntil { recorder.fires > 0 }
        #expect(recorder.fires == 1)

        await settle()
        #expect(
            recorder.firesAfterCancel == 0,
            "a cancelled notifier must never call back again")

        // Post-cancel calls are no-ops rather than an unbalanced suspend count.
        recorder.notifier?.arm()
        recorder.notifier?.disarm()
        await settle()
        #expect(recorder.fires == 1)

        pipe.close()
    }

    /// The suspend count itself is not observable, and every way of getting it
    /// wrong takes the whole test runner down with SIGTRAP 133 rather than
    /// failing an assertion. So this test discriminates by *surviving*: without
    /// the `isArmed` guards, the doubled `arm()` is an over-resume, the doubled
    /// `disarm()` is two suspends against one resume, and the `cancel()` that
    /// follows releases a source with a non-zero count — all three measured
    /// fatal in Task 1. Its assertion is a formality; the signal is that the
    /// process is still alive to run it.
    @Test("arm(), disarm() and cancel() are idempotent, and cancel() rebalances")
    func idempotentAndBalanced() async {
        let pipe = WritablePipe()
        let recorder = DrainRecorder()
        recorder.notifier = WriteSourceDrainNotifier(
            fileDescriptor: pipe.writeEnd
        ) { [weak recorder] in
            recorder?.fires += 1
            recorder?.notifier?.disarm()
        }

        recorder.notifier?.arm()
        recorder.notifier?.arm()
        await waitUntil { recorder.fires > 0 }
        recorder.notifier?.disarm()
        recorder.notifier?.disarm()
        // The ordinary teardown state: suspended. Releasing here without the
        // rebalancing resume is the trap.
        recorder.notifier?.cancel()
        recorder.notifier?.cancel()

        await settle()
        #expect(recorder.fires >= 1)

        // And the other teardown state: cancelled while armed, which owes no
        // resume. A `cancel()` that resumed unconditionally would over-resume.
        let second = WriteSourceDrainNotifier(fileDescriptor: pipe.writeEnd) {}
        second.arm()
        second.cancel()
        await settle()

        pipe.close()
    }
}
