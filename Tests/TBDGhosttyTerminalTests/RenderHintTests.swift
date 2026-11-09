import AppKit
import Foundation
import Metal
import Synchronization
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// The hints a terminal's render signal was handed, oldest first. The signal runs on whichever
/// thread made the call, so the hints sit behind a lock.
private final class HintLog: Sendable {
    private let hints = Mutex<[RenderHint]>([])

    func append(_ hint: RenderHint) {
        hints.withLock { $0.append(hint) }
    }

    var all: [RenderHint] { hints.withLock { $0 } }
    var last: RenderHint? { hints.withLock { $0.last } }
}

/// What a render signal tells the view: the byte counter, the hold as the call left it, and the
/// end the call took. Every case runs on a real terminal, with a render signal standing in for
/// the view's.
@Suite(.fastPassBounded)
struct RenderHintTests {
    private static let begin = "\u{1b}[?2026h"
    private static let end = "\u{1b}[?2026l"

    /// A terminal whose render signal records its hints.
    private static func makeTerminal() throws -> (GhosttyTerminal, HintLog) {
        let terminal = try GhosttyTerminal(cols: 20, rows: 5, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        let log = HintLog()
        terminal.setRenderSignal { log.append($0) }
        return (terminal, log)
    }

    // MARK: The byte counter

    /// `feed` adds what it writes, and a frame's update reads the count and zeroes it in one lock
    /// hold, so the next hint counts only what came after.
    @Test func feedsAddToTheCounterAndAFramesUpdateTakesIt() throws {
        let (terminal, log) = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: "abc")
        let afterFirst = log.last
        let three: RenderHint? = RenderHint(outputBytesSinceFrame: 3)
        #expect(afterFirst == three, "a 3-byte feed signalled \(String(describing: afterFirst))")
        terminal.feed(text: "de")
        let afterSecond = log.last?.outputBytesSinceFrame
        #expect(afterSecond == 5, "a second feed of 2 bytes left the counter at \(String(describing: afterSecond))")

        let taken = terminal.withRawTakingOutputBytes { _ in () }?.outputBytes
        #expect(taken == 5, "the frame's update took \(String(describing: taken)) bytes")
        let left = terminal.outputBytesSinceFrame
        #expect(left == 0, "the update left \(left) bytes on the counter")

        terminal.feed(text: "f")
        let afterFrame = log.last?.outputBytesSinceFrame
        #expect(afterFrame == 1, "the feed after a frame signalled a count of \(String(describing: afterFrame))")
    }

    /// A muted feed is a replayed preamble, which the next frame draws like any other output.
    @Test func aMutedFeedStillCounts() throws {
        let (terminal, _) = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.isMuted = true
        terminal.feed(text: "preamble")
        terminal.isMuted = false
        let counted = terminal.outputBytesSinceFrame
        #expect(counted == 8, "a muted 8-byte feed counted \(counted) bytes")
    }

    /// The frame builder reads the counter in its `begin_update` hold, so the update says how much
    /// output it consumed, and an update with nothing new says none.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    @MainActor
    func aFramesUpdateReportsTheOutputItConsumed() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let glyphCache = GlyphCache(fontSet: FontSet(font: font, scale: 2), device: device)
        let renderer = try TerminalRenderer(device: device, glyphCache: glyphCache)
        let terminal = try GhosttyTerminal(cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        terminal.feed(text: "hello")
        let surface = TerminalSurface()
        try surface.attach(terminal)
        let size = renderer.drawableSize(columns: 10, rows: 3)
        let texture = try #require(renderer.makeOffscreenTexture(width: size.width, height: size.height))

        let first = try renderer.render(surface: surface, to: texture)
        first.commandBuffer?.waitUntilCompleted()
        let consumed = first.update.outputBytes
        #expect(consumed == 5, "the first frame after 5 bytes consumed \(consumed)")
        let left = terminal.outputBytesSinceFrame
        #expect(left == 0, "the frame left \(left) bytes on the counter")

        let second = try renderer.render(surface: surface, to: texture)
        second.commandBuffer?.waitUntilCompleted()
        let consumedAgain = second.update.outputBytes
        #expect(consumedAgain == 0, "a frame with nothing new fed consumed \(consumedAgain)")
    }

    // MARK: The hold

    /// A call that signals takes the end, reading and clearing it, so the next call's hint has
    /// none.
    @Test func aHintCarriesTheHoldAndTakesItsEnd() throws {
        let (terminal, log) = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: Self.begin + "frame")
        let held = log.last
        let heldExpected: RenderHint? = RenderHint(outputBytesSinceFrame: 13, holdOpen: true, holdEnded: false)
        #expect(held == heldExpected, "after ?2026h the hint was \(String(describing: held))")

        terminal.feed(text: Self.end)
        let released = log.last
        let releasedExpected: RenderHint? = RenderHint(outputBytesSinceFrame: 21, holdOpen: false, holdEnded: true)
        #expect(released == releasedExpected, "after ?2026l the hint was \(String(describing: released))")
        let leftEnded = terminal.renderHold.ended
        #expect(!leftEnded, "the call that signalled the end left it on the terminal")

        terminal.feed(text: "x")
        let next = log.last?.holdEnded
        #expect(next == false, "the call after the end signalled the end again")
    }

    /// One chunk that ends a hold and begins the next signals both: a hold open, and an end.
    @Test func aChunkThatEndsAndBeginsAHoldSignalsBoth() throws {
        let (terminal, log) = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: Self.begin + "one")
        terminal.feed(text: Self.end + Self.begin + "two")
        let hint = log.last
        let open = hint?.holdOpen
        let ended = hint?.holdEnded
        #expect(open == true, "a chunk ending one hold and beginning the next left the hold closed: \(String(describing: hint))")
        #expect(ended == true, "a chunk ending one hold and beginning the next signalled no end: \(String(describing: hint))")
    }

    /// `reset()` and `resize` end a hold the program did not finish. Each takes the end, so no
    /// later hint reports it, and reports none itself: a half-written frame is no finished one.
    @Test func aResetAndAResizeTakeTheEndTheyCauseAndReportNone() throws {
        let (terminal, log) = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(text: Self.begin + "half a frame")
        terminal.reset()
        let afterReset = log.last
        let resetExpected: RenderHint? = RenderHint(outputBytesSinceFrame: 20, holdOpen: false, holdEnded: false)
        #expect(afterReset == resetExpected, "a reset during a hold signalled \(String(describing: afterReset))")
        let leftByReset = terminal.renderHold.ended
        #expect(!leftByReset, "a reset left its end for the next call to report")

        terminal.feed(text: Self.begin)
        terminal.resize(cols: 30, rows: 6)
        let afterResize = log.last
        let resizeHoldEnded = afterResize?.holdEnded
        let resizeHoldOpen = afterResize?.holdOpen
        #expect(resizeHoldEnded == false, "a resize during a hold reported an end: \(String(describing: afterResize))")
        #expect(resizeHoldOpen == false, "a resize during a hold left it open: \(String(describing: afterResize))")
        let leftByResize = terminal.renderHold.ended
        #expect(!leftByResize, "a resize left its end for the next call to report")

        terminal.feed(text: "x")
        let next = log.last?.holdEnded
        #expect(next == false, "the feed after a reset and a resize reported an end")
    }

    /// With no signal installed no call signals a render, so the end stays on the terminal for
    /// the first call that has a signal to hand it to.
    @Test func anEndNoSignalTookWaitsForTheNextCallThatSignals() throws {
        let terminal = try GhosttyTerminal(cols: 20, rows: 5, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        terminal.feed(text: Self.begin)
        terminal.feed(text: Self.end)
        let kept = terminal.renderHold.ended
        #expect(kept, "an end with no signal installed was dropped")

        let log = HintLog()
        terminal.setRenderSignal { log.append($0) }
        terminal.feed(text: "x")
        let signalled = log.last?.holdEnded
        #expect(signalled == true, "the first call with a signal installed did not hand on the end")
        let left = terminal.renderHold.ended
        #expect(!left, "the call that handed on the end left it on the terminal")
    }

    /// An attach drops an end that no signal took. The view's first frame after it is a full
    /// rebuild, so the end is no news, and kept it would let the next chunk draw whatever its size.
    @Test func anAttachDropsAnEndNoSignalTook() throws {
        let terminal = try GhosttyTerminal(cols: 20, rows: 5, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        terminal.feed(text: Self.begin)
        terminal.feed(text: Self.end)
        let log = HintLog()
        terminal.setRenderSignal { log.append($0) }
        terminal.resetSyncOutputWatchdog()
        let left = terminal.renderHold.ended
        #expect(!left, "the attach left a stale end on the terminal")

        terminal.feed(text: "x")
        let signalled = log.last?.holdEnded
        #expect(signalled == false, "the first chunk after the attach signalled a stale end")
    }

    // MARK: The close

    @Test func theCloseSignalsAnEmptyHint() throws {
        let (terminal, log) = try Self.makeTerminal()
        terminal.feed(text: Self.begin + "unfinished")
        terminal.close()
        let last = log.last
        let empty: RenderHint? = .empty
        #expect(last == empty, "the close signalled \(String(describing: last))")
        let count = log.all.count
        #expect(count == 2, "a feed and a close signalled \(count) times")
    }

    // MARK: Folding

    @Test func mergingKeepsTheNewerCountAndHoldAndAnyEnd() {
        let older = RenderHint(outputBytesSinceFrame: 10, holdOpen: false, holdEnded: true)
        let newer = RenderHint(outputBytesSinceFrame: 30, holdOpen: true, holdEnded: false)
        let merged = older.merged(with: newer)
        let expected = RenderHint(outputBytesSinceFrame: 30, holdOpen: true, holdEnded: true)
        #expect(merged == expected, "merging an end into a newer open hold gave \(merged)")

        let neither = RenderHint(outputBytesSinceFrame: 1).merged(with: RenderHint(outputBytesSinceFrame: 2))
        let neitherExpected = RenderHint(outputBytesSinceFrame: 2)
        #expect(neither == neitherExpected, "merging two hints with no end gave \(neither)")
    }
}

/// What a relay delivered, in order.
@MainActor
private final class DeliveredHints {
    var hints: [RenderHint] = []
}

/// `RenderSignalRelay` folds every signal that comes before its delivery into one hint, and a
/// signal after the delivery starts the next.
@Suite(.fastPassBounded)
@MainActor
struct RenderSignalRelayTests {
    /// Waits, bounded, until `delivered` holds `count` hints. The deliveries are main-actor tasks
    /// already enqueued, so suspending is all they need.
    private func waitForDeliveries(_ delivered: DeliveredHints, count: Int) async {
        let start = ContinuousClock.now
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { delivered.hints.count >= count }
        }
        if outcome == .timedOut {
            Issue.record(BoundedWaitTimeout(
                what: "the relay to deliver \(count) hints",
                observed: "\(delivered.hints.count) delivered after \(ContinuousClock.now - start)",
                deadline: TestDeadlines.saturatedPass))
        }
    }

    @Test func signalsBeforeTheDeliveryFoldIntoOneHint() async {
        let delivered = DeliveredHints()
        let relay = RenderSignalRelay { delivered.hints.append($0) }
        relay.signal(RenderHint(outputBytesSinceFrame: 10, holdOpen: true, holdEnded: true))
        relay.signal(RenderHint(outputBytesSinceFrame: 20, holdOpen: false, holdEnded: false))
        relay.signal(RenderHint(outputBytesSinceFrame: 30, holdOpen: true, holdEnded: false))
        await waitForDeliveries(delivered, count: 1)
        let folded = delivered.hints
        let expected = [RenderHint(outputBytesSinceFrame: 30, holdOpen: true, holdEnded: true)]
        #expect(folded == expected, "three signals before one delivery delivered \(folded)")

        // The delivery cleared the pending hint: the next signal starts afresh, with no end.
        relay.signal(RenderHint(outputBytesSinceFrame: 5))
        await waitForDeliveries(delivered, count: 2)
        let all = delivered.hints
        let expectedAll = expected + [RenderHint(outputBytesSinceFrame: 5)]
        #expect(all == expectedAll, "a signal after the delivery delivered \(all)")
    }
}
