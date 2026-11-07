import Foundation
import TBDGhosttyTerminal
import TestSupport
import Testing

/// Collects what a terminal's callbacks were handed. Sendable through its lock, because the
/// callbacks are `@Sendable` and may run on whichever thread fed the terminal.
final class CallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ptyWrites: [[UInt8]] = []
    private var bellCount = 0
    private var reports: [GhosttyTerminalCallbacks.ProgramStatus] = []
    private var notificationCount = 0

    var writes: [[UInt8]] { lock.withLock { ptyWrites } }
    var bells: Int { lock.withLock { bellCount } }
    var statuses: [GhosttyTerminalCallbacks.ProgramStatus] { lock.withLock { reports } }
    var total: Int { lock.withLock { ptyWrites.count + bellCount + reports.count + notificationCount } }

    var callbacks: GhosttyTerminalCallbacks {
        GhosttyTerminalCallbacks(
            writePty: { bytes in self.lock.withLock { self.ptyWrites.append(bytes) } },
            bell: { self.lock.withLock { self.bellCount += 1 } },
            clipboardWrite: { _ in self.lock.withLock { self.notificationCount += 1 } },
            desktopNotification: { _, _ in self.lock.withLock { self.notificationCount += 1 } },
            programStatus: { report in self.lock.withLock { self.reports.append(report) } })
    }
}

extension GhosttyTerminal {
    func feed(text: String) { feed(Array(text.utf8)[...]) }
}

/// A 4 KiB chunk of ordinary output: numbered lines, some colour, a cursor move and a DA1 query, so
/// a feed exercises the parser, the screen and the reply path at once.
private let streamChunk: [UInt8] = {
    var bytes: [UInt8] = []
    var line = 0
    while bytes.count < 4096 {
        let text = "\u{1b}[3\(line % 8)mline \(line) of the stream\u{1b}[0m\r\n" + (line % 16 == 0 ? "\u{1b}[c\u{1b}[H" : "")
        bytes.append(contentsOf: text.utf8)
        line += 1
    }
    return Array(bytes.prefix(4096))
}()

@Suite(.fastPassBounded)
struct GhosttyTerminalTests {
    @Test func feedThenReadCellText() throws {
        let terminal = try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        terminal.feed(text: "hello")
        let line = terminal.withLocked { $0.lineText(0) }
        #expect(line.hasPrefix("hello"), "row 0 reads \(line.debugDescription)")
    }

    @Test func effectCallbacksFireInsideFeed() throws {
        let recorder = CallbackRecorder()
        let terminal = try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: recorder.callbacks)

        terminal.feed(text: "\u{07}")
        // Read straight after `feed` returns: nothing is queued for later.
        #expect(recorder.bells == 1)

        terminal.feed(text: "\u{1b}]7501;state=working\u{1b}\\")
        let statuses = recorder.statuses
        #expect(statuses.count == 1)
        #expect(statuses.first?.state == .working)
    }

    @Test func mutedTerminalDropsWritePty() throws {
        let recorder = CallbackRecorder()
        let terminal = try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: recorder.callbacks)

        terminal.isMuted = true
        terminal.feed(text: "\u{1b}[c")
        #expect(recorder.writes.isEmpty, "a muted terminal answered DA1 with \(recorder.writes)")

        terminal.isMuted = false
        terminal.feed(text: "\u{1b}[c")
        let writes = recorder.writes
        #expect(writes.count == 1)
        // A DA1 reply is `CSI ? ... c`.
        let isDA1Reply = writes.first?.starts(with: Array("\u{1b}[?".utf8)) ?? false
        #expect(isDA1Reply, "DA1 reply was \(writes)")
    }

    @Test func resetClearsAlternateScreenLeftovers() throws {
        let terminal = try GhosttyTerminal(cols: 40, rows: 10, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        // A previous life: the alternate screen, filled in red, with red text on it.
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[41m\u{1b}[2J\u{1b}[31mleftover\u{1b}[0m")
        let colouredBefore = terminal.withLocked { $0.cellHasColor(column: 0, row: 0) }
        #expect(colouredBefore, "the fixture did not colour the alternate screen")

        terminal.reset()
        terminal.feed(text: "plain preamble\r\n")

        let (alternate, coloured) = terminal.withLocked { state -> (Bool, [String]) in
            var coloured: [String] = []
            for row in 0..<state.rows {
                for column in 0..<state.cols where state.cellHasColor(column: column, row: row) {
                    coloured.append("(\(column),\(row))")
                }
            }
            return (state.isAlternateScreen, coloured)
        }
        #expect(!alternate)
        #expect(coloured.isEmpty, "coloured cells survived the reset: \(coloured.prefix(10))")
        let firstLine = terminal.withLocked { $0.lineText(0) }
        #expect(firstLine == "plain preamble")
    }

    @Test func feedAfterCloseIsANoOp() throws {
        let recorder = CallbackRecorder()
        let terminal = try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: recorder.callbacks)

        terminal.close()
        terminal.feed(text: "\u{07}\u{1b}[c\u{1b}]7501;state=working\u{1b}\\hello")
        terminal.reset()
        terminal.resize(cols: 100, rows: 30)
        terminal.close()

        #expect(recorder.total == 0, "a closed terminal still called back")
        #expect(terminal.isClosed)
        let (closed, line) = terminal.withLocked { ($0.isClosed, $0.lineText(0)) }
        #expect(closed)
        #expect(line.isEmpty)
    }

    @Test @MainActor func closeDuringBackgroundFeedDoesNotCrash() async throws {
        let recorder = CallbackRecorder()
        let terminal = try GhosttyTerminal(cols: 120, rows: 40, scrollbackLines: 1000, callbacks: recorder.callbacks)
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let chunk = streamChunk
        let chunkCount = (4 * 1024 * 1024) / chunk.count

        let feeder = Task.detached {
            for index in 0..<chunkCount {
                terminal.feed(chunk[...])
                // A quarter of the way in, let the main actor close the terminal under the feed.
                if index == chunkCount / 4 { startedContinuation.yield() }
            }
            startedContinuation.finish()
            return chunkCount
        }

        for await _ in started { break }
        terminal.close()
        let fed = await feeder.value

        #expect(fed == chunkCount)
        #expect(terminal.isClosed)
        // Feeding after the close is still safe, and changes nothing.
        let writesAfterClose = recorder.writes.count
        terminal.feed(chunk[...])
        #expect(recorder.writes.count == writesAfterClose)
    }

    @Test @MainActor func resizeWhileFeedingFromBackgroundEndsAtLastSize() async throws {
        let terminal = try GhosttyTerminal(
            cols: 80, rows: 24, scrollbackLines: 1000, callbacks: GhosttyTerminalCallbacks())
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let chunk = streamChunk

        let feeder = Task.detached {
            for index in 0..<512 {
                terminal.feed(chunk[...])
                if index == 0 { startedContinuation.yield() }
            }
            startedContinuation.finish()
        }

        for await _ in started { break }
        var last = (cols: 0, rows: 0)
        for step in 0..<200 {
            last = (cols: 40 + (step * 7) % 100, rows: 10 + (step * 3) % 50)
            terminal.resize(cols: last.cols, rows: last.rows)
        }
        await feeder.value

        let size = terminal.withLocked { ($0.cols, $0.rows) }
        #expect(size.0 == last.cols)
        #expect(size.1 == last.rows)
    }
}
