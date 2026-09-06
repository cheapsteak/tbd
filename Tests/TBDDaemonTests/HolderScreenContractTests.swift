import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// What the daemon's emulator answers when a machine asks it for a screen.
///
/// `HolderRenderProjectionTests` pins the *text*: no invisible holes, no
/// doubled wide glyphs. This pins everything a string could not carry — where
/// the viewport starts, where the cursor is and whether it is visible, what
/// modes the child is in, which store answered, and how stale that store's
/// view is. Each of those exists because a consumer's behaviour turns on it and
/// there was previously no way to ask.
///
/// It exercises the production path rather than a copy of it: `ingest` feeds
/// the reader's emulator synchronously, on the calling thread, and
/// `HolderReader.screen` is the very function the `terminal.output` handler
/// calls. No drain thread and no real pty are involved, so nothing here is
/// timing-dependent — including the ages, which are read from an injected
/// monotonic clock rather than measured.
@Suite struct HolderScreenContractTests {

    private static let esc = "\u{1b}"
    private static let nul = "\u{0}"

    // MARK: - The projection, seen through the type

    /// The whitelist refuses a `U+0000`, so this is two assertions at once: the
    /// render substitutes a space, *and* the screen was constructible at all.
    /// A render that stopped substituting would not return a screen with holes
    /// in it — it would throw.
    @Test("a never-written cell reaches the screen as a space, never a NUL")
    func neverWrittenCellsProjectAsSpaces() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        await harness.reader.ingest(preamble: Self.data("✻\(Self.esc)[3GCogitated"))
        let screen = try await harness.reader.screen(maxLines: 50)

        #expect(screen.lines.first == "✻ Cogitated")
        #expect(!screen.output.contains(Self.nul))
    }

    /// The trailing cell of a two-column glyph carries code 0 as well, and it
    /// is not an unwritten cell: padding it to a space would double the width
    /// of every CJK character and every emoji. The line is one grapheme per
    /// glyph.
    @Test("a wide glyph's trailing half is omitted rather than padded")
    func wideGlyphTrailingHalfIsOmitted() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        await harness.reader.ingest(preamble: Self.data("日本 x"))
        let screen = try await harness.reader.screen(maxLines: 50)

        #expect(screen.lines.first == "日本 x")
        // One grapheme per glyph: 日, 本, the space, x. A trailing half padded
        // to a space would make it six.
        #expect(screen.lines.first?.count == 4, "the wide glyphs were padded out")
    }

    // MARK: - Modes

    /// The three modes the input path composes against. Each is asserted in
    /// both directions, because a reader wired to a constant would satisfy
    /// either half alone.
    @Test("bracketed paste follows the child's DECSET 2004")
    func bracketedPasteFollowsTheChild() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        #expect(try await harness.reader.screen(maxLines: 8).modes.bracketedPaste == false)
        await harness.reader.ingest(preamble: Self.data("\(Self.esc)[?2004h"))
        #expect(try await harness.reader.screen(maxLines: 8).modes.bracketedPaste == true)
        await harness.reader.ingest(preamble: Self.data("\(Self.esc)[?2004l"))
        #expect(try await harness.reader.screen(maxLines: 8).modes.bracketedPaste == false)
    }

    @Test("application cursor follows the child's DECCKM")
    func applicationCursorFollowsTheChild() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        #expect(try await harness.reader.screen(maxLines: 8).modes.applicationCursor == false)
        await harness.reader.ingest(preamble: Self.data("\(Self.esc)[?1h"))
        #expect(try await harness.reader.screen(maxLines: 8).modes.applicationCursor == true)
        await harness.reader.ingest(preamble: Self.data("\(Self.esc)[?1l"))
        #expect(try await harness.reader.screen(maxLines: 8).modes.applicationCursor == false)
    }

    @Test("the alternate screen flag follows 1049")
    func alternateScreenFollowsTheChild() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        #expect(try await harness.reader.screen(maxLines: 8).modes.alternateScreen == false)
        await harness.reader.ingest(preamble: Self.data("\(Self.esc)[?1049h"))
        #expect(try await harness.reader.screen(maxLines: 8).modes.alternateScreen == true)
        await harness.reader.ingest(preamble: Self.data("\(Self.esc)[?1049l"))
        #expect(try await harness.reader.screen(maxLines: 8).modes.alternateScreen == false)
    }

    // MARK: - Cursor

    @Test("the cursor reports its viewport row and column")
    func cursorPosition() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        // `ESC[3;5H` is row 3, column 5, both 1-based; the screen reports them
        // 0-based, so 2 and 4.
        await harness.reader.ingest(preamble: Self.data("\(Self.esc)[3;5H"))
        let screen = try await harness.reader.screen(maxLines: 8)
        #expect(screen.cursor.row == 2)
        #expect(screen.cursor.column == 4)
    }

    /// `cursorHidden` is not a public property, so visibility is tracked on the
    /// delegate: SwiftTerm calls `showCursor`/`hideCursor` whenever the child
    /// sets or resets mode 25. Asserted in both directions, because a reader
    /// wired to the mode's default would satisfy either half alone.
    @Test("cursor visibility follows DECTCEM")
    func cursorVisibility() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        #expect(try await harness.reader.screen(maxLines: 8).cursor.visible == true)
        await harness.reader.ingest(preamble: Self.data("\(Self.esc)[?25l"))
        #expect(try await harness.reader.screen(maxLines: 8).cursor.visible == false)
        await harness.reader.ingest(preamble: Self.data("\(Self.esc)[?25h"))
        #expect(try await harness.reader.screen(maxLines: 8).cursor.visible == true)
    }

    /// **A screen read must not feed the terminal.** This is the case that
    /// separates a tracked flag from a `DECRQM` probe.
    ///
    /// `screen` runs on every `terminal.output`, including against a reader
    /// whose drain thread is mid-stream. SwiftTerm's parser carries its state
    /// across `feed` calls and an `ESC` in any state aborts the pending
    /// sequence, so a probe issued while the last read ended mid-sequence would
    /// truncate the child's — routine, since a TUI repaint larger than the pty
    /// buffer arrives split.
    ///
    /// Here the first ingest ends inside an SGR's parameters. Read the screen,
    /// then deliver the rest: the halves must join and colour the `X`. A probe
    /// would have aborted the `ESC[38;5;`, leaving `196m` to print as literal
    /// text — so the whole line, not just its colour, is the assertion.
    @Test("reading a screen does not abort a sequence split across two reads")
    func readingDoesNotAbortASplitSequence() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        await harness.reader.ingest(preamble: Self.data("\(Self.esc)[?25l"))
        await harness.reader.ingest(preamble: Self.data("\(Self.esc)[38;5;"))

        // Reading mid-sequence answers with the visibility last set, and the
        // half-parsed sequence has printed nothing.
        let midParse = try await harness.reader.screen(maxLines: 8)
        #expect(midParse.cursor.visible == false)
        #expect(midParse.lines.isEmpty)

        await harness.reader.ingest(preamble: Self.data("196mX"))
        let screen = try await harness.reader.screen(maxLines: 8)
        #expect(
            screen.lines.first == "X",
            "the split SGR did not complete — it printed as text: \(screen.lines)")
        #expect(screen.cursor.visible == false)
    }

    // MARK: - viewportStart

    /// The field exists because it cannot be derived. Trailing blank rows are
    /// dropped, so `lines.count - size.rows` is the wrong answer, and a
    /// consumer that subtracted would land in the wrong row.
    ///
    /// Ten numbered lines on a four-row grid, asked for six: the tail is lines
    /// 5 through 10, the viewport is the last four of them, and the cursor sits
    /// on the last line of all.
    @Test("viewportStart indexes the viewport's first row inside lines")
    func viewportStartLocatesTheViewport() async throws {
        let harness = try Harness(columns: 40, rows: 4)
        defer { harness.tearDown() }

        let numbered = (1...10).map { "line \($0)" }.joined(separator: "\r\n")
        await harness.reader.ingest(preamble: Self.data(numbered))
        let screen = try await harness.reader.screen(maxLines: 6)

        #expect(screen.lines.count == 6)
        #expect(screen.lines == (5...10).map { "line \($0)" })
        #expect(screen.viewportStart == 2)
        #expect(screen.size.rows == 4)
        #expect(
            screen.lines[screen.viewportStart + screen.cursor.row] == "line 10",
            """
            viewportStart + cursor.row does not land on the cursor's line: \
            \(screen.lines) start \(screen.viewportStart) cursor \(screen.cursor.row)
            """)
    }

    // MARK: - Age

    /// One rule for every source: how long ago the answering store last
    /// consumed a byte, and — before it ever has — how long ago the store
    /// itself was adopted. So a fresh, silent session reads as exactly as old
    /// as it is rather than as instantly current.
    @Test("before any byte, the age is the age of the store itself")
    func ageBeforeTheFirstByteIsTheStoresOwn() async throws {
        let clock = SteppedMonotonicClock()
        let harness = try Harness(columns: 40, rows: 8, monotonicNow: clock.read)
        defer { harness.tearDown() }

        clock.advance(by: .seconds(30))
        #expect(try await harness.reader.screen(maxLines: 8).ageMilliseconds == 30_000)
    }

    /// After a byte the measurement moves to that byte, which is what makes the
    /// number mean "how stale is this view" rather than "how old is this
    /// session".
    @Test("after a byte, the age is measured from that byte")
    func ageAfterAByteIsMeasuredFromIt() async throws {
        let clock = SteppedMonotonicClock()
        let harness = try Harness(columns: 40, rows: 8, monotonicNow: clock.read)
        defer { harness.tearDown() }

        clock.advance(by: .seconds(30))
        await harness.reader.ingest(preamble: Self.data("hello"))
        #expect(try await harness.reader.screen(maxLines: 8).ageMilliseconds == 0)

        // The spec's own example of a stale answer worth acting on.
        clock.advance(by: .seconds(41 * 60))
        #expect(try await harness.reader.screen(maxLines: 8).ageMilliseconds == 2_460_000)
    }

    /// A read is not a byte the child sent. If anything a read did counted,
    /// every read would reset the age it was taken to measure and no screen
    /// could ever be reported stale.
    @Test("reading a screen does not make the screen look fresher")
    func readingDoesNotResetTheAge() async throws {
        let clock = SteppedMonotonicClock()
        let harness = try Harness(columns: 40, rows: 8, monotonicNow: clock.read)
        defer { harness.tearDown() }

        await harness.reader.ingest(preamble: Self.data("hello"))
        clock.advance(by: .seconds(41 * 60))
        _ = try await harness.reader.screen(maxLines: 8)
        _ = await harness.reader.modeReading()
        #expect(try await harness.reader.screen(maxLines: 8).ageMilliseconds == 2_460_000)
    }

    // MARK: - Source

    /// An idle reader is holding a screen it is not updating, so it must not
    /// claim to be the live store — a consumer told `daemon` would apply a
    /// live-screen policy to a frozen one.
    ///
    /// **`.daemon` is not reachable here**, and no fake is built to pretend it
    /// is: it requires a reader whose drain thread is actually running, which
    /// needs a real pty and a real job. It is asserted live, in
    /// `HolderAttachHandoffTests` and `HolderDetachHandbackTests`, on both
    /// sides of an attach.
    @Test("a reader that is not draining answers staleDaemon")
    func anIdleReaderIsStale() async throws {
        let harness = try Harness(columns: 40, rows: 8)
        defer { harness.tearDown() }

        #expect(try await harness.reader.screen(maxLines: 8).source == .staleDaemon)
        #expect(await harness.reader.modeReading().source == .staleDaemon)
    }

    /// The oracle's answer and the screen's are one observation of one store,
    /// so they cannot be allowed to drift apart — pairing one store's modes
    /// with another's screen is exactly what the `source` field exists to make
    /// impossible.
    @Test("modeReading agrees with the screen it is a narrower view of")
    func modeReadingAgreesWithTheScreen() async throws {
        let clock = SteppedMonotonicClock()
        let harness = try Harness(columns: 40, rows: 8, monotonicNow: clock.read)
        defer { harness.tearDown() }

        await harness.reader.ingest(
            preamble: Self.data("\(Self.esc)[?2004h\(Self.esc)[?1h"))
        clock.advance(by: .seconds(7))

        let screen = try await harness.reader.screen(maxLines: 8)
        #expect(await harness.reader.modeReading() == screen.modeReading)
        #expect(screen.modeReading.modes.bracketedPaste == true)
        #expect(screen.modeReading.modes.applicationCursor == true)
        #expect(screen.modeReading.ageMilliseconds == 7_000)
    }

    // MARK: - Harness

    private static func data(_ text: String) -> Data { Data(text.utf8) }

    /// A monotonic clock a test moves by hand.
    ///
    /// The reader's `monotonicNow` seam is separate from its `clock` because
    /// `any Clock<Duration>` pins `Duration` and not `Instant`, so it cannot do
    /// the instant arithmetic an age is. `ContinuousClock.Instant` can, which is
    /// what lets these tests assert an exact number of milliseconds instead of
    /// a tolerance window on a loaded box.
    private final class SteppedMonotonicClock: @unchecked Sendable {
        private let lock = NSLock()
        private let base = ContinuousClock.now
        private var offset: Duration = .zero

        var read: @Sendable () -> ContinuousClock.Instant {
            { [self] in lock.withLock { base + offset } }
        }

        func advance(by duration: Duration) {
            lock.withLock { offset += duration }
        }
    }

    /// A `HolderReader` over one end of a socketpair, never started — the same
    /// shape `HolderRenderProjectionTests` uses, and for the same reason:
    /// nothing on this path reads a tty's ioctls, and starting the drain would
    /// only add a thread and a wait to a test whose whole subject is what the
    /// emulator answers. `ingest` feeds the same emulator the drain loop feeds,
    /// on the calling thread.
    private struct Harness {
        let reader: HolderReader
        private let ours: Int32

        init(
            columns: Int, rows: Int,
            monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = {
                ContinuousClock.now
            }
        ) throws {
            var pair: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            ours = pair[1]
            // The reader owns `pair[0]` and closes it in `tearDown`.
            reader = HolderReader(
                sessionID: UUID(),
                ptyFD: pair[0],
                columns: columns,
                rows: rows,
                scrollbackLines: 200,
                monotonicNow: monotonicNow)
        }

        /// Closes this side only. The reader's own end is closed by its
        /// `deinit`, which is safe precisely because the reader is `.idle`:
        /// no thread was ever started, so none can be inside a read on it.
        func tearDown() {
            close(ours)
        }
    }
}
