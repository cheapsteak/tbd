import Foundation
import TBDShared
import Testing

@testable import TBDApp

/// Tests for `TerminalLatencyTap` — the per-panel half of the terminal
/// transport latency instrument — and for the feed seam both transports reach
/// it through.
///
/// The line formats are pinned here on purpose: `scripts/diag/terminal-latency-report.py`
/// matches them verbatim, so a rewording that looks harmless in Swift silently
/// empties every report.
@MainActor
@Suite("Terminal latency tap")
struct TerminalLatencyTapTests {

    /// Collects emitted lines. `@unchecked Sendable` with a lock because the
    /// tap's emit closure is `@Sendable` — in production it is called from the
    /// IO thread.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.lock()
            storage.append(line)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// A tap over a hand-cranked clock. `now` is a mutable box so a test can
    /// advance time between a feed and a draw the way a real wait does.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0

        var seconds: Double {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }

        func advance(ms: Double) { seconds += ms / 1000 }
    }

    private func makeTap(
        terminalID: UUID = UUID(),
        transport: TerminalTransport = .holder
    ) -> (tap: TerminalLatencyTap, clock: Clock, lines: Lines) {
        let clock = Clock()
        let lines = Lines()
        let tap = TerminalLatencyTap(
            terminalID: terminalID,
            transport: transport,
            now: { clock.seconds },
            emit: { lines.append($0) })
        return (tap, clock, lines)
    }

    /// One chunk fed at `clock`, costing `parseMs` to parse.
    private func feed(
        _ tap: TerminalLatencyTap, _ clock: Clock, _ bytes: [UInt8], parseMs: Double = 0
    ) {
        let feedAt = clock.seconds
        clock.advance(ms: parseMs)
        tap.noteChunk(bytes[...], feedAt: feedAt, feedReturnedAt: clock.seconds)
    }

    /// `key=value` pairs of a line, after its leading verb.
    private func fields(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        for token in line.split(separator: " ").dropFirst() {
            let halves = token.split(separator: "=", maxSplits: 1)
            guard halves.count == 2 else { continue }
            out[String(halves[0])] = String(halves[1])
        }
        return out
    }

    // MARK: - The passive tap

    @Test("one chunk then a draw reports one line whose oldest wait is the gap")
    func oneChunkThenDraw() throws {
        let (tap, clock, lines) = makeTap()
        feed(tap, clock, Array("hello".utf8))
        clock.advance(ms: 7)
        tap.noteDrawWillBegin(at: clock.seconds, isOnScreen: true)

        #expect(lines.all.count == 1)
        let line = try #require(lines.all.first)
        let parsed = fields(line)
        #expect(line.hasPrefix("draw "))
        #expect(parsed["chunks"] == "1")
        #expect(parsed["oldestms"] == "7.000")
        #expect(parsed["newestms"] == "7.000")
        #expect(parsed["dropped"] == "0")
        #expect(parsed["vis"] == "1")
    }

    @Test("three chunks report the first as oldest, the last as newest, and the largest parse")
    func threeChunksThenDraw() throws {
        let (tap, clock, lines) = makeTap()
        feed(tap, clock, Array("a".utf8), parseMs: 1)
        clock.advance(ms: 4)
        feed(tap, clock, Array("b".utf8), parseMs: 3)
        clock.advance(ms: 2)
        feed(tap, clock, Array("c".utf8), parseMs: 2)
        clock.advance(ms: 5)
        tap.noteDrawWillBegin(at: clock.seconds, isOnScreen: false)

        #expect(lines.all.count == 1)
        let parsed = fields(try #require(lines.all.first))
        #expect(parsed["chunks"] == "3")
        // First feed at t=0, draw at 1+4+3+2+2+5 = 17ms.
        #expect(parsed["oldestms"] == "17.000")
        // Last feed at 1+4+3+2 = 10ms, so it waited 7ms.
        #expect(parsed["newestms"] == "7.000")
        #expect(parsed["parsemaxms"] == "3.000")
        #expect(parsed["vis"] == "0")
    }

    @Test("a draw with no chunks waiting emits nothing — a caret blink is silent")
    func drawWithNoChunksIsSilent() {
        let (tap, clock, lines) = makeTap()
        clock.advance(ms: 20)
        tap.noteDrawWillBegin(at: clock.seconds, isOnScreen: true)
        #expect(lines.all.isEmpty)
    }

    @Test("a draw resets the window, so a second draw with nothing new is silent")
    func drawResetsTheWindow() {
        let (tap, clock, lines) = makeTap()
        feed(tap, clock, Array("a".utf8))
        clock.advance(ms: 3)
        tap.noteDrawWillBegin(at: clock.seconds, isOnScreen: true)
        clock.advance(ms: 3)
        tap.noteDrawWillBegin(at: clock.seconds, isOnScreen: true)
        #expect(lines.all.count == 1)
    }

    @Test("overflowing the ring reports the cap and counts the drops")
    func ringOverflowIsCountedNotSilent() throws {
        let (tap, clock, lines) = makeTap()
        for _ in 0..<(TerminalLatencyTap.ringCapacity + 1) {
            feed(tap, clock, Array("x".utf8))
            clock.advance(ms: 1)
        }
        tap.noteDrawWillBegin(at: clock.seconds, isOnScreen: false)

        #expect(lines.all.count == 1)
        let parsed = fields(try #require(lines.all.first))
        #expect(parsed["chunks"] == "512")
        #expect(parsed["dropped"] == "1")
    }

    @Test("the draw line's shape is exactly what the report script parses")
    func drawLineFormatIsPinned() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let (tap, clock, lines) = makeTap(terminalID: id, transport: .tmux)
        feed(tap, clock, Array("a".utf8), parseMs: 0.5)
        clock.advance(ms: 1.5)
        tap.noteDrawWillBegin(at: clock.seconds, isOnScreen: true)

        #expect(
            lines.all == [
                "draw transport=tmux terminal=11111111-2222-3333-4444-555555555555"
                    + " chunks=1 oldestms=2.000 newestms=2.000 parsemaxms=0.500"
                    + " dropped=0 vis=1"
            ])
    }

    // MARK: - The echo probe

    @Test("a token echoed inside one chunk is reported with its round-trip time")
    func echoInOneChunk() throws {
        let (tap, clock, lines) = makeTap()
        tap.armEcho(seq: 4, token: TerminalLatencyTap.token(seq: 4), sentAt: clock.seconds)
        clock.advance(ms: 2)
        feed(tap, clock, Array("$ lp4z\r\n".utf8))

        let echoes = lines.all.filter { $0.hasPrefix("echo ") }
        #expect(echoes.count == 1)
        let parsed = fields(try #require(echoes.first))
        #expect(parsed["seq"] == "4")
        #expect(parsed["ms"] == "2.000")
    }

    @Test("a token split across two chunks still matches")
    func echoSplitAcrossChunks() throws {
        let (tap, clock, lines) = makeTap()
        tap.armEcho(seq: 91, token: TerminalLatencyTap.token(seq: 91), sentAt: clock.seconds)
        clock.advance(ms: 1)
        feed(tap, clock, Array("prompt lp9".utf8))
        #expect(lines.all.filter { $0.hasPrefix("echo ") }.isEmpty)
        clock.advance(ms: 3)
        feed(tap, clock, Array("1z more".utf8))

        let echoes = lines.all.filter { $0.hasPrefix("echo ") }
        #expect(echoes.count == 1)
        // Stamped at the arrival of the chunk that completed the match: 1+3ms.
        #expect(fields(try #require(echoes.first))["ms"] == "4.000")
    }

    @Test("a second copy of the token is ignored — cat's own line is not a second echo")
    func secondCopyIsIgnored() {
        let (tap, clock, lines) = makeTap()
        tap.armEcho(seq: 7, token: TerminalLatencyTap.token(seq: 7), sentAt: clock.seconds)
        clock.advance(ms: 1)
        feed(tap, clock, Array("lp7z\r\n".utf8))
        clock.advance(ms: 40)
        feed(tap, clock, Array("lp7z\r\n".utf8))

        #expect(lines.all.filter { $0.hasPrefix("echo ") }.count == 1)
    }

    @Test("arming over a pending token retires it as lost")
    func rearmRetiresThePendingToken() {
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let (tap, clock, lines) = makeTap(terminalID: id, transport: .holder)
        tap.armEcho(seq: 1, token: TerminalLatencyTap.token(seq: 1), sentAt: clock.seconds)
        clock.advance(ms: 250)
        tap.armEcho(seq: 2, token: TerminalLatencyTap.token(seq: 2), sentAt: clock.seconds)

        #expect(
            lines.all == [
                "echolost transport=holder terminal=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE seq=1"
            ])

        // And the replacement is live, not collateral damage.
        clock.advance(ms: 5)
        feed(tap, clock, Array("lp2z".utf8))
        #expect(lines.all.filter { $0.hasPrefix("echo ") }.count == 1)
    }

    @Test("the echo line's shape is exactly what the report script parses")
    func echoLineFormatIsPinned() {
        let id = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let (tap, clock, lines) = makeTap(terminalID: id, transport: .tmux)
        tap.armEcho(seq: 12, token: TerminalLatencyTap.token(seq: 12), sentAt: clock.seconds)
        clock.advance(ms: 3.25)
        feed(tap, clock, Array("lp12z".utf8))

        #expect(
            lines.all.filter { $0.hasPrefix("echo ") } == [
                "echo transport=tmux terminal=99999999-8888-7777-6666-555555555555"
                    + " seq=12 ms=3.250"
            ])
    }

    @Test("the token is plain lowercase ASCII with no carriage return")
    func tokenShape() {
        #expect(TerminalLatencyTap.token(seq: 0) == Array("lp0z".utf8))
        #expect(TerminalLatencyTap.token(seq: 1234) == Array("lp1234z".utf8))
        #expect(!TerminalLatencyTap.token(seq: 1).contains(0x0d))
    }

    // MARK: - The seam

    @Test("with no tap installed, feed reaches the view exactly as withView did")
    func feedWithNoTapReachesTheView() {
        let suiteName = "TBDAppTests.LatencySeam.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))

        let holder = TerminalViewHolder()
        holder.set(view)
        holder.feed(Array("SEAM-MARKER-4c1\r\n".utf8)[...])

        let text = String(data: view.getBufferAsData(), encoding: .utf8) ?? ""
        #expect(text.contains("SEAM-MARKER-4c1"))
    }

    @Test("with a tap installed, feed both reaches the view and records the chunk")
    func feedWithTapReachesTheViewAndRecords() throws {
        let suiteName = "TBDAppTests.LatencySeam.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))

        let (tap, clock, lines) = makeTap()
        let holder = TerminalViewHolder()
        holder.set(view)
        holder.setTap(tap)
        holder.feed(Array("TAPPED-MARKER-9b2\r\n".utf8)[...])
        clock.advance(ms: 6)
        tap.noteDrawWillBegin(at: clock.seconds, isOnScreen: true)

        let text = String(data: view.getBufferAsData(), encoding: .utf8) ?? ""
        #expect(text.contains("TAPPED-MARKER-9b2"))
        #expect(lines.all.count == 1)
        #expect(fields(try #require(lines.all.first))["chunks"] == "1")
    }

    @Test("with the view cleared, feed records nothing — a dropped batch is not a wait")
    func feedWithClearedViewRecordsNothing() {
        let (tap, clock, lines) = makeTap()
        let holder = TerminalViewHolder()
        holder.setTap(tap)
        holder.feed(Array("dropped".utf8)[...])
        clock.advance(ms: 9)
        tap.noteDrawWillBegin(at: clock.seconds, isOnScreen: true)
        #expect(lines.all.isEmpty)
    }
}
