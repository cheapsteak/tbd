import Darwin
import Foundation
import Testing
import TestSupport

@testable import TBDDaemonLib

/// M4.2 — `PaneFanout.writeReplay`: the pre-ready, generation-checked,
/// EAGAIN-waiting replay write (unlike `route()`, which drops on EAGAIN).
///
/// `writeReplay` blocks its caller while the pipe is full, by design, so the
/// tests that make it wait run it on a dedicated thread and suspend until it
/// returns: a cooperative thread blocked there is one the rest of the pass
/// cannot use. The moment it starts waiting is observed, not slept for — the
/// pipe probes `.full` only once the write has met EAGAIN.
@Suite("PaneFanout replay write")
struct PaneFanoutReplayTests {
    private let server = "tbd-test-server"

    /// Drain `readFD` on a dedicated thread until `expected` bytes arrived
    /// (or the fd hits EOF). `join()` suspends until it finishes.
    private final class PipeDrainer: @unchecked Sendable {
        private let readFD: Int32
        private let expected: Int
        private let lock = NSLock()
        /// Bytes read so far, published as they arrive so a timeout can say
        /// how far the reader got.
        private var received = Data()
        private var finished = false

        init(readFD: Int32, expected: Int) {
            self.readFD = readFD
            self.expected = expected
        }

        func start() {
            let thread = Thread { [self] in
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                var count = 0
                while count < expected {
                    let n = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
                    if n <= 0 { break }
                    count += n
                    lock.withLock { received.append(contentsOf: buffer[0..<n]) }
                }
                lock.withLock { finished = true }
            }
            thread.start()
        }

        /// The accumulated bytes once the thread finished. Throws a named
        /// timeout, with how far the reader got, if it did not finish within
        /// the shared saturated-pass budget, and rethrows a cancellation.
        func join() async throws -> Data {
            let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
                lock.withLock { finished }
            }
            switch outcome {
            case .satisfied:
                return lock.withLock { received }
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                let readSoFar = lock.withLock { received.count }
                throw BoundedWaitTimeout(
                    what: "the reader thread to finish",
                    observed: "\(readSoFar) of \(expected) bytes read",
                    deadline: TestDeadlines.saturatedPass)
            }
        }
    }

    /// One `writeReplay` call on a dedicated thread, with what it returned and
    /// when, measured on that thread so the test body's own scheduling cannot
    /// inflate it.
    private final class ReplayWriteThread: @unchecked Sendable {
        struct Outcome {
            let error: (any Error)?
            /// Seconds from the call to its return.
            let elapsed: TimeInterval
            let finishedAt: DispatchTime
        }

        private let lock = NSLock()
        private var outcome: Outcome?

        func start(_ write: @escaping @Sendable () throws -> Void) {
            let thread = Thread { [self] in
                let start = DispatchTime.now()
                var failure: (any Error)?
                do { try write() } catch { failure = error }
                let end = DispatchTime.now()
                let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
                lock.withLock { outcome = Outcome(error: failure, elapsed: elapsed, finishedAt: end) }
            }
            thread.start()
        }

        /// Suspends until the call returns.
        func finished() async throws -> Outcome {
            let waited = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
                lock.withLock { outcome != nil }
            }
            switch waited {
            case .satisfied:
                let finished = lock.withLock { outcome }
                return try #require(finished)
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                throw BoundedWaitTimeout(
                    what: "writeReplay to return", observed: nil, deadline: TestDeadlines.saturatedPass)
            }
        }
    }

    /// Waits until the pipe probes `.full`. `writeReplay` fills the pipe under
    /// the fanout's lock and `isPipeWritable` takes the same lock, so `.full`
    /// is only observable once the write has met EAGAIN and is waiting.
    private func requirePipeFull(_ fanout: PaneFanout, key: PaneKey, generation: UInt64) async throws {
        let waited = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            fanout.isPipeWritable(key: key, generation: generation) == .full
        }
        switch waited {
        case .satisfied:
            return
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw BoundedWaitTimeout(
                what: "the replay write to fill the pipe",
                observed: String(describing: fanout.isPipeWritable(key: key, generation: generation)),
                deadline: TestDeadlines.saturatedPass)
        }
    }

    /// Closes a test's read end only after stopping any thread still writing
    /// to the pane. A writer thread outlives a wait that failed or was
    /// cancelled; detaching first makes its next re-validation throw. A write
    /// into a pipe with no reader would instead raise SIGPIPE: the test host's
    /// handler (`Tests/TestProcessDefaults/SIGPIPEHandler.c`) turns it into
    /// EPIPE but logs a caught-SIGPIPE line that reads as an unguarded write,
    /// and without the handler it ends the whole test process.
    private func detachThenClose(_ fanout: PaneFanout, key: PaneKey, readFD: Int32) {
        fanout.detach(key: key)
        Darwin.close(readFD)
    }

    @Test("replay lands in the pipe BEFORE the sink is ready, and live output follows it")
    func preReadyWriteLands() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%1")
        let (readFD, generation) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }

        let replay = Data("\u{1b}[2J\u{1b}[HREPLAY".utf8)
        try fanout.writeReplay(key: key, generation: generation, bytes: replay)

        // Live output routed while not ready is still dropped…
        fanout.route(server: server, event: .output(paneID: "%1", bytes: Data("dropped".utf8)))
        // …and output after markReady lands strictly after the replay bytes.
        fanout.markReady(key: key, generation: generation)
        fanout.route(server: server, event: .output(paneID: "%1", bytes: Data("LIVE".utf8)))

        let expected = replay + Data("LIVE".utf8)
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<count]) == expected)
    }

    @Test("a superseded generation refuses and writes nothing")
    func generationMismatchRefuses() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%2")
        let (readFD, generation) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }

        #expect(throws: PaneReplayWriteError.superseded) {
            try fanout.writeReplay(key: key, generation: generation + 1, bytes: Data("stale".utf8))
        }

        // Nothing may have reached the pipe.
        let flags = fcntl(readFD, F_GETFL)
        _ = fcntl(readFD, F_SETFL, flags | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 8)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(count < 0 && errno == EAGAIN)
    }

    @Test("writing to a never-attached pane throws notAttached")
    func notAttachedThrows() {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%404")
        #expect(throws: PaneReplayWriteError.notAttached) {
            try fanout.writeReplay(key: key, generation: 1, bytes: Data("x".utf8))
        }
    }

    @Test("EAGAIN waits for the reader instead of dropping — the full replay arrives intact")
    func eagainWaitsAndDeliversIntact() async throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%3")
        let (readFD, generation) = try fanout.attach(key: key)
        defer { detachThenClose(fanout, key: key, readFD: readFD) }

        // Far larger than any pipe buffer, with position-dependent content so
        // a dropped or duplicated chunk cannot go unnoticed.
        var replay = Data()
        replay.reserveCapacity(512 * 1024)
        var counter: UInt8 = 0
        while replay.count < 512 * 1024 {
            replay.append(counter)
            counter &+= 1
        }

        // The deadline is only a hang guard here: the write has to outlast
        // the test body noticing the full pipe, which is a scheduling hop.
        let writer = ReplayWriteThread()
        writer.start { [replay] in
            try fanout.writeReplay(
                key: key, generation: generation, bytes: replay,
                deadline: TestDeadlines.saturatedPassSeconds)
        }

        // Reader starts only once the pipe is full, so the writer hits EAGAIN first.
        try await requirePipeFull(fanout, key: key, generation: generation)
        let drainer = PipeDrainer(readFD: readFD, expected: replay.count)
        drainer.start()

        let outcome = try await writer.finished()
        if let error = outcome.error { throw error }
        let received = try await drainer.join()
        #expect(received == replay, "replay must arrive byte-for-byte intact")
    }

    @Test("a wedged reader trips the deadline with a distinct error, in bounded time")
    func deadlineThrowsTimely() async throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%4")
        let (readFD, generation) = try fanout.attach(key: key)
        defer { detachThenClose(fanout, key: key, readFD: readFD) }

        let replay = Data(repeating: UInt8(ascii: "r"), count: 512 * 1024)
        let writer = ReplayWriteThread()
        writer.start {
            try fanout.writeReplay(key: key, generation: generation, bytes: replay, deadline: 0.2)
        }
        let outcome = try await writer.finished()
        let thrown = outcome.error as? PaneReplayWriteError
        let elapsed = outcome.elapsed

        guard case .deadlineExceeded(let written, let total)? = thrown else {
            Issue.record("expected deadlineExceeded, got \(String(describing: thrown))")
            return
        }
        #expect(total == replay.count)
        #expect(written > 0, "the pipe-buffer-sized prefix should have been written")
        #expect(written < total)
        #expect(elapsed < 2.0, "a 0.2 s deadline must not stall for \(elapsed) s")
    }

    @Test("detach during an EAGAIN wait is noticed by re-validation, not the deadline")
    func detachDuringWaitThrowsNotAttached() async throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%5")
        let (readFD, generation) = try fanout.attach(key: key)
        defer { detachThenClose(fanout, key: key, readFD: readFD) }

        let replay = Data(repeating: UInt8(ascii: "d"), count: 512 * 1024)
        let writer = ReplayWriteThread()
        writer.start {
            try fanout.writeReplay(
                key: key, generation: generation, bytes: replay,
                deadline: TestDeadlines.saturatedPassSeconds)
        }

        // Detach once the write is waiting on EAGAIN, not after a guessed delay.
        try await requirePipeFull(fanout, key: key, generation: generation)
        let detachedAt = DispatchTime.now()
        fanout.detach(key: key)

        let outcome = try await writer.finished()
        #expect(outcome.error as? PaneReplayWriteError == .notAttached)
        let noticedAfter = (Double(outcome.finishedAt.uptimeNanoseconds)
            - Double(detachedAt.uptimeNanoseconds)) / 1_000_000_000
        #expect(
            noticedAfter < 5.0,
            "re-validation must notice the detach well before the deadline, took \(noticedAfter) s")
    }
}
