import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib

/// M4.2 — `PaneFanout.writeReplay`: the pre-ready, generation-checked,
/// EAGAIN-waiting replay write (unlike `route()`, which drops on EAGAIN).
@Suite("PaneFanout replay write")
struct PaneFanoutReplayTests {
    private let server = "tbd-test-server"

    /// Drain `readFD` on a background thread until `expected` bytes arrived
    /// (or the fd hits EOF). Returns the accumulated data via the completion
    /// box after `join()`.
    private final class PipeDrainer: @unchecked Sendable {
        private let readFD: Int32
        private let expected: Int
        private var received = Data()
        private let done = DispatchSemaphore(value: 0)

        init(readFD: Int32, expected: Int) {
            self.readFD = readFD
            self.expected = expected
        }

        func start(delay: TimeInterval = 0) {
            let thread = Thread { [self] in
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while received.count < expected {
                    let n = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
                    if n <= 0 { break }
                    received.append(contentsOf: buffer[0..<n])
                }
                done.signal()
            }
            thread.start()
        }

        func join(timeout: TimeInterval = 15) -> Data? {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
            return received
        }
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
    func eagainWaitsAndDeliversIntact() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%3")
        let (readFD, generation) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }

        // Far larger than any pipe buffer, with position-dependent content so
        // a dropped or duplicated chunk cannot go unnoticed.
        var replay = Data()
        replay.reserveCapacity(512 * 1024)
        var counter: UInt8 = 0
        while replay.count < 512 * 1024 {
            replay.append(counter)
            counter &+= 1
        }

        // Reader starts on a delay, guaranteeing the writer hits EAGAIN first.
        let drainer = PipeDrainer(readFD: readFD, expected: replay.count)
        drainer.start(delay: 0.1)

        try fanout.writeReplay(key: key, generation: generation, bytes: replay, deadline: 10)

        let received = try #require(drainer.join(), "reader thread did not finish")
        #expect(received == replay, "replay must arrive byte-for-byte intact")
    }

    @Test("a wedged reader trips the deadline with a distinct error, in bounded time")
    func deadlineThrowsTimely() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%4")
        let (readFD, generation) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }

        let replay = Data(repeating: UInt8(ascii: "r"), count: 512 * 1024)
        let start = DispatchTime.now()
        var thrown: PaneReplayWriteError?
        do {
            try fanout.writeReplay(key: key, generation: generation, bytes: replay, deadline: 0.2)
        } catch let error as PaneReplayWriteError {
            thrown = error
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

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
    func detachDuringWaitThrowsNotAttached() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%5")
        let (readFD, generation) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }

        let detacher = Thread {
            Thread.sleep(forTimeInterval: 0.15)
            fanout.detach(key: key)
        }
        detacher.start()

        let replay = Data(repeating: UInt8(ascii: "d"), count: 512 * 1024)
        let start = DispatchTime.now()
        #expect(throws: PaneReplayWriteError.notAttached) {
            try fanout.writeReplay(key: key, generation: generation, bytes: replay, deadline: 10)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        #expect(elapsed < 5.0, "re-validation must notice the detach well before the 10 s deadline")
    }
}
