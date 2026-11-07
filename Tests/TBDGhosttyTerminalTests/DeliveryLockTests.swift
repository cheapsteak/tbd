import Dispatch
import Foundation
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// A delivery that blocks holds the delivery lock, and a call that queued nothing must not wait
/// for it. Otherwise the main thread's next key or click waits on whatever the IO thread is
/// delivering, and the IO thread's next feed waits on the main thread's delivery, so nobody reads
/// the program's output while the program waits to write it.
@Suite(.fastPassBounded)
struct DeliveryLockTests {
    @Test func callsThatQueueNothingDoNotWaitForABlockedWritePty() async throws {
        let gate = WritePtyGate()
        let terminal = try GhosttyTerminal(
            cols: 80, rows: 24, scrollbackLines: 100,
            callbacks: GhosttyTerminalCallbacks(writePty: { _ in gate.pass() }))
        // A view's frame request, so the feed below changes the screen with a signal installed.
        terminal.setRenderSignal {}
        // Mode 2048, so the resize below writes a size report. Enabling it writes one too, which
        // goes through: the gate is not armed yet.
        terminal.feed(text: "\u{1b}[?2048h")
        gate.arm()

        // The resize's drain reaches writePty, which blocks there, holding the delivery lock.
        let resize = gateHoldingTask { terminal.resize(cols: 100, rows: 30) }
        let held = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { gate.isHolding }
        guard held == .satisfied else {
            gate.release()
            await resize.value
            terminal.close()
            if held == .timedOut { Issue.record("the resize's size report never reached writePty") }
            return
        }

        // On another thread, three calls that produce nothing for the callbacks.
        let finished = CompletionFlag()
        let others = gateHoldingTask {
            terminal.feed(text: "plain output, nothing to answer")
            _ = terminal.encodeMouse(MousePress(action: .motion, button: nil, position: SurfacePoint(x: 5, y: 5)))
            _ = terminal.encodeKey(
                KeyPress(key: MacKeyCodes.key(forVirtualKeyCode: 0x00), text: "a", unshiftedCodepoint: 0x61),
                optionAsAlt: .never)
            finished.set()
        }
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { finished.isSet }
        gate.release()
        await resize.value
        await others.value
        terminal.close()
        if outcome == .timedOut {
            Issue.record("a feed with no reply, a mouse event or a key waited on the blocked writePty")
        }
    }
}

/// Lets `writePty` calls through until armed, then holds the first one until released.
private final class WritePtyGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var holding = false
    private var released = false

    var isHolding: Bool { lock.withLock { holding } }

    func arm() { lock.withLock { armed = true } }

    /// Called from `writePty`, on whichever thread is delivering.
    func pass() {
        let hold = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false
            holding = true
            return true
        }
        if hold { _ = semaphore.waitForGate("writePty, held inside a resize's drain") }
    }

    /// Lets the held call go. Only the first call signals.
    func release() {
        let signal = lock.withLock { () -> Bool in
            defer { released = true }
            return !released
        }
        if signal { semaphore.signal() }
    }
}

/// A flag one thread sets and another polls.
private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}
