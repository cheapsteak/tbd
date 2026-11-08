import Clocks
import Darwin
import Foundation
import SwiftTerm
import Testing

@testable import TBDApp
import TestSupport

/// A stopped holder reader reads on, briefly, while the output it has fed
/// ends part-way through a sequence.
///
/// The handback snapshot feeds the panel's terminal a `DECRQM` probe, and the
/// first `ESC` in it would end the session's sequence early; the rest, left on
/// the pty, would print as text in the daemon's emulator. So the reader keeps
/// reading until the sequence ends, for a bounded time on its clock, and stops
/// at once when the output itself has ended.
///
/// Driven over a `socketpair` standing in for the vended pty: the reader owns
/// one end and closes it, and the test plays the session on the other.
@Suite("A stopped holder reader finishes an open sequence before it closes", .fastPassBounded)
struct HolderStreamReaderSequenceBoundaryTests {

    private static let esc = "\u{1b}"

    @Test("a stopped reader reads on until the session's sequence ends")
    func readsOnUntilTheSequenceEnds() async throws {
        let session = try Session()
        defer { session.tearDown() }
        let terminal = FedTerminal()
        let asks = Counter()
        let rest = Array("TITLE-PAYLOAD\u{07}AFTER".utf8)
        let reader = HolderStreamReader(
            label: "boundary-reads-on", fd: session.vended,
            isAtSequenceBoundary: {
                // The child finishes its write a moment after the reader
                // stopped reading.
                if asks.next() == 1 { session.write(rest) }
                return terminal.isAtSequenceBoundary
            },
            onChunk: { terminal.feed($0) })
        reader.start()
        session.write(Array("BEFORE\r\n\(Self.esc)]0;HALF-OF-A-".utf8))
        try await waitFor(
            "the reader to feed the half-written title",
            observed: { "screen: \(terminal.screenText().debugDescription)" }
        ) {
            terminal.screenText().contains("BEFORE") && !terminal.isAtSequenceBoundary
        }

        reader.stop()
        await reader.awaitClosed()

        let screen = terminal.screenText()
        #expect(screen.contains("AFTER"), """
            the reader closed part-way through the title, leaving its rest on the pty: \
            \(screen.debugDescription)
            """)
        #expect(!screen.contains("PAYLOAD"), "the title's rest printed as text: \(screen.debugDescription)")
        #expect(!reader.closedMidSequence)
    }

    /// A child can leave a sequence open for good, so the wait gives up. Each
    /// reading of the clock is 100 ms later than the last against the default
    /// 250 ms budget, so a wait bounded on that clock looks three times, where
    /// one bounded on the wall clock would look some fifty.
    @Test("a stopped reader gives up on a sequence that never ends, by its clock")
    func theWaitIsBounded() async throws {
        let session = try Session()
        defer { session.tearDown() }
        let asks = Counter()
        let reader = HolderStreamReader(
            label: "boundary-bounded", fd: session.vended,
            isAtSequenceBoundary: {
                _ = asks.next()
                return false
            },
            onChunk: { _ in },
            clock: SteppingClock(step: .milliseconds(100)))
        reader.start()
        reader.stop()
        await reader.awaitClosed()

        #expect(reader.closedMidSequence, "the reader gave up waiting without logging that it had")
        #expect(asks.count == 3, "the wait looked \(asks.count) times, not the three its clock allows")
    }

    /// Output that has ended leaves nothing to wait for: the reader left its
    /// loop on the end of the output, not on a stop, and closes at once.
    @Test("a reader whose output ended mid-sequence closes without waiting")
    func endedOutputSkipsTheWait() async throws {
        let session = try Session()
        defer { session.tearDown() }
        let terminal = FedTerminal()
        let asks = Counter()
        let reader = HolderStreamReader(
            label: "boundary-ended", fd: session.vended,
            isAtSequenceBoundary: {
                _ = asks.next()
                return terminal.isAtSequenceBoundary
            },
            onChunk: { terminal.feed($0) },
            clock: SteppingClock(step: .milliseconds(100)))
        reader.start()
        session.write(Array("BEFORE\r\n\(Self.esc)]0;cut-off".utf8))
        session.hangUp()
        await reader.awaitClosed()

        #expect(asks.count == 0, "the reader waited \(asks.count) looks for output that had ended")
        #expect(!reader.closedMidSequence, "the reader logged a remainder that ended output cannot send")
    }

    @Test("a stopped reader stops waiting the moment the output ends")
    func outputEndingDuringTheWaitEndsIt() async throws {
        let session = try Session()
        defer { session.tearDown() }
        let asks = Counter()
        let reader = HolderStreamReader(
            label: "boundary-ends-during", fd: session.vended,
            isAtSequenceBoundary: {
                // The child exits a moment after the reader stopped reading.
                if asks.next() == 1 { session.hangUp() }
                return false
            },
            onChunk: { _ in },
            clock: SteppingClock(step: .milliseconds(100)))
        reader.start()
        reader.stop()
        await reader.awaitClosed()

        #expect(asks.count == 1, "the reader looked \(asks.count) times after the output had ended")
        #expect(!reader.closedMidSequence, "the reader logged a remainder that ended output cannot send")
    }

    // MARK: - Support

    /// A `socketpair` standing in for the vended pty. The reader owns
    /// `vended` and closes it; the test plays the session on the other end.
    private final class Session: @unchecked Sendable {
        let vended: Int32
        private let lock = NSLock()
        private var far: Int32

        init() throws {
            var pair: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            vended = pair[0]
            far = pair[1]
            // Close-on-exec at creation, so no sibling suite's child inherits
            // either end, and non-blocking, as the real vend is.
            for fd in pair {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            }
        }

        /// Bytes the child writes. A few, into an empty socket buffer.
        func write(_ bytes: [UInt8]) {
            lock.withLock {
                guard far >= 0 else { return }
                _ = bytes.withUnsafeBytes { Darwin.write(far, $0.baseAddress, $0.count) }
            }
        }

        /// The child exits: the reader's next read returns 0.
        func hangUp() {
            lock.withLock {
                guard far >= 0 else { return }
                Darwin.close(far)
                far = -1
            }
        }

        func tearDown() { hangUp() }
    }

    /// A terminal fed from the reader thread and read from the test, under
    /// its own lock. `Terminal.tdel` is weak, so the delegate is held here.
    private final class FedTerminal: @unchecked Sendable {
        private let terminal: SwiftTerm.Terminal
        private let delegate = SilentDelegate()

        init() {
            terminal = SwiftTerm.Terminal(
                delegate: delegate, options: TerminalOptions(cols: 40, rows: 8))
        }

        func feed(_ data: Data) {
            terminal.terminalLock.withLock { terminal.feed(byteArray: [UInt8](data)) }
        }

        var isAtSequenceBoundary: Bool {
            terminal.terminalLock.withLock { terminal.isAtSequenceBoundary }
        }

        func screenText() -> String {
            terminal.terminalLock.withLock {
                (0..<terminal.rows)
                    .map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
                    .joined(separator: "\n")
            }
        }
    }

    private final class SilentDelegate: TerminalDelegate {
        func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {}
    }

    /// Counts the reader's looks at the boundary, from its thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        /// Counts one more, and returns the new count.
        func next() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }

        var count: Int { lock.withLock { value } }
    }

    /// A clock whose every reading is `step` later than the one before, so a
    /// wait bounded on it ends after a known number of readings however fast
    /// or slow the machine is. Sleeping moves it to the deadline at once.
    private final class SteppingClock: Clock, @unchecked Sendable {
        typealias Instant = ImmediateClock<Duration>.Instant

        private let lock = NSLock()
        private var current = Instant()
        private let step: Duration

        init(step: Duration) { self.step = step }

        var now: Instant {
            lock.withLock {
                current = current.advanced(by: step)
                return current
            }
        }

        var minimumResolution: Duration { .zero }

        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            lock.withLock {
                if current < deadline { current = deadline }
            }
        }
    }
}
