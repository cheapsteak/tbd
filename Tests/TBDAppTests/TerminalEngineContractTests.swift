import AppKit
import Foundation
import os
import Testing
@testable import TBDApp
import TBDShared
import TBDTerminalSerialization
import TestSupport

/// What every `TerminalEngine` must do, written once and run against each engine
/// this build can make (`TerminalEngineFactory.availableKinds`).
///
/// Each test builds its engine through the factory, the way both coordinators
/// do, and observes it only through the protocol and a recording
/// `TerminalEngineDelegate`, so a second engine joins the suite by joining
/// `availableKinds`, which holds libghostty wherever this machine has a Metal
/// device for it to draw with. The routing test drives its paste through the
/// engine's headless drop entry, the one each view's real drop calls. Design:
/// `docs/specs/2026-11-07-libghostty-terminal-engine-design.md`.
///
/// **Report payloads are compared parsed.** SwiftTerm forwards a report's raw
/// bytes and libghostty hands over parsed fields that the engine writes back,
/// so the two can differ in field order while meaning the same thing; the
/// daemon reads both with `ProgramStatusParser`, and so do these checks.
///
/// **Timing.** Every delegate method arrives on main, and a callback a parse
/// provokes is queued there during the parse and delivered a later main-queue
/// turn. So an assertion about an absence runs after `settle()`, the rule
/// `QuietIngestTests` uses: five main-queue turns with a short real pause
/// between them, which also covers the OSC observer's private queue. An
/// assertion about a presence polls with `waitUntil`, which waits through
/// `pollUntilTrue` within the shared saturated-pass budget, and then settles
/// before it counts, so a second, late delivery is caught too.
///
/// **Absences carry positive controls.** "Nothing reached the delegate" also
/// reads as a pass when the fixture bytes provoke nothing at all, so each such
/// test feeds the same bytes live afterwards and requires the effect.
///
/// **Every fixture settles before it is used.** Building a view can queue
/// callbacks of its own; the fixture waits them out and clears the recorder, so
/// a test sees only what its own bytes caused.
///
/// The suite limit is a hang guard: every wait here is bounded on its own. It
/// takes the shared dial; see `.fastPassBounded` in
/// `Tests/TestSupport/ClockTestSupport.swift`.
@MainActor
@Suite("Terminal engine contract", .fastPassBounded)
struct TerminalEngineContractTests {

    // MARK: - Fixtures

    private static let da1 = "\u{1b}[c"
    private static let probe = "\u{1b}]7501;?\u{07}"
    private static let reportData = "state=working:app=claude-code"
    private static var report: String { "\u{1b}]7501;\(reportData)\u{07}" }
    private static let notify = "\u{1b}]777;notify;Contract;Body\u{07}"
    private static var probeReplyBytes: [UInt8] { Array(ProgramStatusProtocol.probeReply.utf8) }

    /// An engine from the factory, its recorder, and the isolated defaults its
    /// appearance reads. Settled, and the recorder cleared, before it is
    /// returned.
    private func makeFixture(kind: TerminalEngineKind) async -> EngineFixture {
        let fixture = EngineFixture(kind: kind)
        // A kind in `availableKinds` that fell back would run this suite
        // against SwiftTerm twice and pass.
        #expect(fixture.engine.kind == kind, "asked for \(kind), the factory built \(fixture.engine.kind)")
        await settle()
        fixture.recorder.reset()
        return fixture
    }

    // MARK: - Threads

    /// Main reads row 0 under `withScreen` while a detached task feeds, and
    /// every read must be one whole line some feed wrote. Each feed is
    /// `ESC[H ESC[2K` then `line N`, so a read that lands between the erase and
    /// the text, or part way through the text, comes back torn.
    ///
    /// The overlap is built in rather than hoped for. Main starts reading only
    /// once the first feed has finished, and the feeder keeps going until it
    /// has fed 1,000 times **and** main has read 50 times while it was still
    /// feeding. A lock that works can therefore never fail this test.
    ///
    /// A missing lock is likely to fail it, with a torn read or a crash, but
    /// not certain to: whether an unlocked read lands inside a parse is up to
    /// the scheduler.
    @Test("Every screen read made while a background task feeds sees a whole line",
          arguments: TerminalEngineFactory.availableKinds)
    func feedFromBackgroundWhileReadingIsConsistent(kind: TerminalEngineKind) async {
        let fixture = await makeFixture(kind: kind)
        defer { fixture.tearDown() }
        let engine = fixture.engine
        let progress = OSAllocatedUnfairLock(initialState: FeedProgress())
        let end = ContinuousClock.now + TestDeadlines.saturatedPass

        // Only the engine, which is `Sendable`, the lock and the deadline
        // cross into the task; `feed` is the one requirement callable off main.
        // The loop never suspends, so it runs on a thread these tests own
        // instead of holding a cooperative-pool thread for as long as main is
        // slow to read. A task executor preference does not reach into a
        // detached task from outside (SE-0417), so the task takes it itself,
        // and records its thread so a preference that stops applying goes red.
        let feeder = Task.detached { [engine, progress, end] in
            await withTaskExecutorPreference(GateExecutor.shared) {
                let thread = runningThreadName()
                progress.withLock { $0.feederThread = thread }
                var index = 0
                while ContinuousClock.now < end {
                    guard index < 1_000 || progress.withLock({ $0.overlappingReads }) < 50 else { break }
                    engine.feed(Array("\u{1b}[H\u{1b}[2Kline \(index)".utf8)[...])
                    let fed = index
                    progress.withLock { $0.lastFed = fed }
                    index += 1
                }
                progress.withLock { $0.finished = true }
            }
        }

        // The start barrier: until the first feed is in, row 0 is blank.
        while progress.withLock({ $0.lastFed == nil }), ContinuousClock.now < end {
            await mainQueueTurn()
        }

        var reads = 0
        var torn: [String] = []
        while !progress.withLock({ $0.finished }), ContinuousClock.now < end {
            for _ in 0..<10 {
                let text = engine.withScreen { $0.lineText(row: 0) } ?? "<no row 0>"
                if !Self.isWholeLine(text) { torn.append(text) }
                reads += 1
                progress.withLock { state in
                    if !state.finished { state.overlappingReads += 1 }
                }
            }
            await mainQueueTurn()
        }
        await feeder.value

        let outcome = progress.withLock { $0 }
        #expect(outcome.feederThread == GateExecutor.threadName,
                "the feeder ran on \(outcome.feederThread ?? "an unnamed thread"), not on a thread these tests own")
        #expect(outcome.overlappingReads >= 50,
                "main read only \(outcome.overlappingReads) times while the feeder ran, so the reads did not overlap the feeds")
        #expect(torn.isEmpty, "\(torn.count) of \(reads) reads were torn, for example \(torn.prefix(3))")
        let last = engine.withScreen { $0.lineText(row: 0) }
        let expected = outcome.lastFed.map { "line \($0)" }
        #expect(last == expected, "the screen must end on the last line fed")
    }

    // MARK: - Snapshot ingest

    @Test("A snapshot's DA1 and OSC 7501 probe produce no send",
          arguments: TerminalEngineFactory.availableKinds)
    func ingestSnapshotDropsReplies(kind: TerminalEngineKind) async {
        let fixture = await makeFixture(kind: kind)
        defer { fixture.tearDown() }
        fixture.engine.setProgramStatusReporting(enabled: true)
        let bytes = Self.probe + Self.da1

        fixture.engine.ingestSnapshot(Data(bytes.utf8))
        await settle()
        #expect(fixture.recorder.sent.isEmpty, "replayed queries were answered: \(fixture.recorder.sent)")
        #expect(!fixture.engine.isIngestingSnapshot)

        // Positive control: live, the same bytes are answered, probe first.
        feed(bytes, into: fixture.engine)
        let answered = await waitUntil("the probe and DA1 fixture to be answered live", observing: fixture.recorder) {
            fixture.recorder.sent.count > Self.probeReplyBytes.count
        }
        guard answered else { return }
        #expect(fixture.recorder.sent.starts(with: Self.probeReplyBytes), "observed \(fixture.recorder.sent)")
    }

    @Test("A snapshot's OSC 777 and OSC 7501 report reach no delegate method",
          arguments: TerminalEngineFactory.availableKinds)
    func ingestSnapshotSuppressesOscEvents(kind: TerminalEngineKind) async {
        let fixture = await makeFixture(kind: kind)
        defer { fixture.tearDown() }
        fixture.engine.setProgramStatusReporting(enabled: true)
        let bytes = Self.notify + Self.report

        fixture.engine.ingestSnapshot(Data(bytes.utf8))
        await settle()
        #expect(fixture.recorder.calls.isEmpty, "a replayed OSC event reached the delegate: \(fixture.recorder.calls)")

        // Positive control: once the ingest is over, the same bytes fed live
        // raise one notification and forward one report.
        feed(bytes, into: fixture.engine)
        let delivered = await waitUntil("the OSC fixture to reach the delegate live", observing: fixture.recorder) {
            !fixture.recorder.notifications.isEmpty && !fixture.recorder.programStatusPayloads.isEmpty
        }
        guard delivered else { return }
        await settle()
        #expect(fixture.recorder.notifications.count == 1)
        #expect(fixture.recorder.notifications.first?.title == "Contract")
        #expect(fixture.recorder.notifications.first?.body == "Body")
        #expect(Self.parsed(fixture.recorder.programStatusPayloads) == [Self.parsedReport])
    }

    // MARK: - Parser replies

    /// The answer is written inside the parse, so it is queued ahead of the DA1
    /// reply that follows the probe in the same chunk. Its delivery is pinned as
    /// it is today: SwiftTerm hops every reply through `TerminalView.onMain`, an
    /// unconditional `DispatchQueue.main.async`, so nothing has reached `send`
    /// when `feed` returns, and both replies, probe first, have reached it one
    /// main-queue turn later.
    @Test("The OSC 7501 probe is answered inside the parse, ahead of DA1, and reaches send one main-queue turn after feed returns",
          arguments: TerminalEngineFactory.availableKinds)
    func programStatusProbeIsAnsweredInsideTheParseAndDeliveredOneMainTurnLater(kind: TerminalEngineKind) async {
        let fixture = await makeFixture(kind: kind)
        defer { fixture.tearDown() }
        fixture.engine.setProgramStatusReporting(enabled: true)

        feed(Self.probe + Self.da1, into: fixture.engine)
        #expect(fixture.recorder.sent.isEmpty,
                "a reply reached send inside feed; the main-queue hop this pins is gone: \(fixture.recorder.sent)")

        await mainQueueTurn()
        #expect(fixture.recorder.sent.starts(with: Self.probeReplyBytes), "observed \(fixture.recorder.sent)")
        #expect(fixture.recorder.sent.count > Self.probeReplyBytes.count,
                "the DA1 reply must land in the same main-queue turn; observed \(fixture.recorder.sent)")
    }

    // MARK: - Live events

    /// The clipboard payload is a per-run marker, and the recorder never writes
    /// the pasteboard: a test must not overwrite the developer's.
    @Test("A BEL, an OSC 52 copy and an OSC 777 notification each reach the delegate once",
          arguments: TerminalEngineFactory.availableKinds)
    func bellClipboardAndNotificationReachTheDelegate(kind: TerminalEngineKind) async {
        let fixture = await makeFixture(kind: kind)
        defer { fixture.tearDown() }
        let marker = "tbd-engine-contract-\(UUID().uuidString)"
        let osc52 = "\u{1b}]52;c;\(Data(marker.utf8).base64EncodedString())\u{07}"

        feed("\u{07}", into: fixture.engine)
        feed(osc52, into: fixture.engine)
        feed(Self.notify, into: fixture.engine)
        let arrived = await waitUntil(
            "a BEL, an OSC 52 copy and an OSC 777 notification to reach the delegate",
            observing: fixture.recorder
        ) {
            fixture.recorder.bells >= 1
                && !fixture.recorder.clipboardCopies.isEmpty
                && !fixture.recorder.notifications.isEmpty
        }
        guard arrived else { return }
        await settle()
        #expect(fixture.recorder.bells == 1)
        #expect(fixture.recorder.clipboardCopies == [Data(marker.utf8)])
        #expect(fixture.recorder.notifications.count == 1)
        #expect(fixture.recorder.notifications.first?.title == "Contract")
    }

    // MARK: - Geometry

    @Test("The grid is resized before sizeChanged reports it",
          arguments: TerminalEngineFactory.availableKinds)
    func resizeHappensBeforeSizeChanged(kind: TerminalEngineKind) async throws {
        let fixture = await makeFixture(kind: kind)
        defer { fixture.tearDown() }
        let before = fixture.engine.gridSize

        fixture.engine.view.setFrameSize(NSSize(width: 400, height: 240))
        let reported = await waitUntil("a frame change to report a new grid size", observing: fixture.recorder) {
            !fixture.recorder.sizeChanges.isEmpty
        }
        guard reported else { return }

        let change = try #require(fixture.recorder.sizeChanges.last)
        #expect(change.cols != before.cols || change.rows != before.rows,
                "the fixture frame must change the grid; it was \(before.cols)x\(before.rows)")
        #expect(change.gridCols == change.cols, "gridSize inside sizeChanged read \(change.gridCols) columns")
        #expect(change.gridRows == change.rows, "gridSize inside sizeChanged read \(change.gridRows) rows")
    }

    /// libghostty changes its grid for DECCOLM inside the parse, and the
    /// engine reads the grid back after the feed and reports it a main-queue
    /// turn later. A resize of the view in between applies a grid of its own
    /// and reports it at once, so the late report must not put the DECCOLM
    /// grid back: the delegate's last word is the grid as the terminal has
    /// it. Only libghostty, the engine that reads its grid back after a feed.
    /// DECCOLM needs `CSI ? 40 h` first.
    @Test("A view resize just after a DECCOLM leaves the delegate with the grid the terminal has, not the DECCOLM one",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice))
    func resizeJustAfterDeccolmReportsTheCurrentGrid() async throws {
        let fixture = await makeFixture(kind: .ghostty)
        defer { fixture.tearDown() }
        feed("\u{1b}[?40h", into: fixture.engine)
        await settle()
        fixture.recorder.reset()
        let before = fixture.engine.gridSize

        // One main-queue turn: the program changes the grid, and the view is
        // resized before the engine's report of that change runs.
        feed("\u{1b}[?3h", into: fixture.engine)
        let deccolm = fixture.engine.gridSize
        try #require(deccolm.cols != before.cols, "DECCOLM left the grid at \(deccolm.cols) columns")
        fixture.engine.view.setFrameSize(NSSize(width: 400, height: 240))
        let resized = fixture.engine.gridSize
        try #require(resized.cols != deccolm.cols, "the frame change left the grid at \(resized.cols) columns")
        await settle()

        let last = try #require(fixture.recorder.sizeChanges.last, "neither change was reported")
        let lastCols = last.cols
        let lastRows = last.rows
        #expect(lastCols == resized.cols && lastRows == resized.rows, """
            the delegate last heard \(lastCols)x\(lastRows), the DECCOLM grid being \(deccolm.cols)x\(deccolm.rows), \
            while the terminal has \(resized.cols)x\(resized.rows)
            """)
    }

    // MARK: - Preamble into a used engine

    /// A viewer can be reused: the engine a preamble lands in may hold a
    /// full-screen program that never left, still on the alternate screen with
    /// a coloured attribute open and its modes set. After `prepareForPreamble`,
    /// the preamble must leave it exactly as it leaves a fresh engine. On
    /// SwiftTerm `prepareForPreamble` does nothing, and the snapshot writer's
    /// reset prelude is what makes this hold.
    @Test("prepareForPreamble on a reused engine gives the preamble a fresh screen",
          arguments: TerminalEngineFactory.availableKinds)
    func prepareForPreambleOnAReusedEngineGivesAFreshScreen(kind: TerminalEngineKind) async {
        let source = await makeFixture(kind: kind)
        let used = await makeFixture(kind: kind)
        let fresh = await makeFixture(kind: kind)
        defer {
            source.tearDown()
            used.tearDown()
            fresh.tearDown()
        }

        var vimLife = "$ vim notes.txt\r\n\u{1b}[?1049h\u{1b}[?1h\u{1b}[?2004h\u{1b}[44m\u{1b}[2J\u{1b}[H"
        for line in 1...10 {
            vimLife += "~ vim line \(line)\r\n"
        }
        feed(vimLife, into: used.engine)
        let usedBefore = used.engine.withScreen { ($0.isAlternateScreen, $0.lineText(row: 0)) }
        #expect(usedBefore.0, "the used engine must be left on the alternate screen")
        #expect(usedBefore.1?.hasPrefix("~ vim line 1") == true, "the program's screen must have landed: \(usedBefore.1 ?? "nil")")

        feed("hello\r\n\u{1b}[31mworld\u{1b}[0m\r\n$ ", into: source.engine)
        let preamble = await source.engine.handbackPreamble(maxScrollbackLines: 100)
        #expect(!preamble.isEmpty)

        used.engine.prepareForPreamble()
        used.engine.ingestSnapshot(preamble)
        fresh.engine.ingestSnapshot(preamble)
        await settle()

        let usedScreen = used.engine.withScreen { $0.projection(maxLines: 200) }
        let freshScreen = fresh.engine.withScreen { $0.projection(maxLines: 200) }
        #expect(freshScreen.lines.contains("world"), "the preamble must carry the source's screen: \(freshScreen.lines)")
        #expect(!usedScreen.modes.alternateScreen)
        #expect(usedScreen == freshScreen)
    }

    // MARK: - Appearance

    @Test("Applying an appearance with a larger font grows the cell",
          arguments: TerminalEngineFactory.availableKinds)
    func appearanceIsApplied(kind: TerminalEngineKind) async {
        let fixture = await makeFixture(kind: kind)
        defer { fixture.tearDown() }
        let before = fixture.engine.cellSize

        let largerSuite = TestDefaultsSuite("TBDAppTests.TerminalEngineContract.Larger")
        defer { largerSuite.tearDown() }
        let larger = AppearanceSettings(defaults: largerSuite.defaults)
        larger.fontSize = fixture.appearance.fontSize + 6

        fixture.engine.apply(appearance: larger)
        let after = fixture.engine.cellSize
        #expect(after.height > before.height, "cell height \(before.height) -> \(after.height)")
        #expect(after.width > before.width, "cell width \(before.width) -> \(after.width)")
    }

    // MARK: - What the engine swallows

    @Test("The handback's mode-probe replies never reach send",
          arguments: TerminalEngineFactory.availableKinds)
    func handbackRepliesNeverReachSend(kind: TerminalEngineKind) async {
        let fixture = await makeFixture(kind: kind)
        defer { fixture.tearDown() }
        feed("hello\r\n$ ", into: fixture.engine)
        await settle()
        fixture.recorder.reset()

        let preamble = await fixture.engine.handbackPreamble(maxScrollbackLines: 100)
        await settle()
        #expect(!preamble.isEmpty)
        #expect(!fixture.engine.isCollectingHandbackReplies)
        #expect(fixture.recorder.sent.isEmpty, "the handback's replies reached send: \(fixture.recorder.sent)")

        // Positive control: the same probe fed live is answered through send,
        // so the empty `sent` above means the replies were kept, not that the
        // probe provoked none.
        feed(HolderHandback.modeProbe, into: fixture.engine)
        await waitUntil("the mode probe to be answered when fed live", observing: fixture.recorder) {
            !fixture.recorder.sent.isEmpty
        }
    }

    /// What the holder reader asks before the handback's probe goes in: whether
    /// the session's output so far ends between sequences. The cases are the
    /// daemon's (`HolderAttachSequenceBoundaryTests.openSequences`), so both
    /// ends of a holder attach read an open sequence alike.
    @Test("isAtSequenceBoundary is false part-way through an escape sequence or a UTF-8 character, and true once it ends",
          arguments: TerminalEngineFactory.availableKinds)
    func sequenceBoundaryFollowsTheParser(kind: TerminalEngineKind) async {
        let fixture = await makeFixture(kind: kind)
        defer { fixture.tearDown() }
        #expect(fixture.engine.isAtSequenceBoundary, "a fresh \(kind) engine reads as mid-sequence")

        let esc = "\u{1b}"
        let cases: [(name: String, opened: [UInt8], rest: [UInt8])] = [
            ("an OSC title", Array("\(esc)]0;HALF-OF-A-".utf8), Array("TITLE\u{07}".utf8)),
            ("an OSC 8 link", Array("\(esc)]8;;https://example.com/".utf8), Array("page\(esc)\\".utf8)),
            ("a sixel DCS", Array("\(esc)Pq#0;2;0;0;0".utf8), Array("#0!4~\(esc)\\".utf8)),
            ("a kitty APC", Array("\(esc)_Ga=q,i=31;AAAA".utf8), Array("\(esc)\\".utf8)),
            ("a CSI's parameters", Array("\(esc)[38;5;".utf8), Array("196m".utf8)),
            ("a lone ESC", Array(esc.utf8), Array("[1m".utf8)),
            // U+20AC split after its second byte.
            ("a UTF-8 character", [0xE2, 0x82], [0xAC]),
        ]
        for sequence in cases {
            fixture.engine.feed(sequence.opened[...])
            #expect(!fixture.engine.isAtSequenceBoundary,
                    "\(kind) reads as between sequences part-way through \(sequence.name)")
            fixture.engine.feed(sequence.rest[...])
            #expect(fixture.engine.isAtSequenceBoundary,
                    "\(kind) still reads as mid-sequence after \(sequence.name) ended")
        }
        feed("plain text, then a complete \(esc)[0m reset", into: fixture.engine)
        #expect(fixture.engine.isAtSequenceBoundary, "\(kind) reads plain output as mid-sequence")
    }

    /// DECCOLM needs `CSI ? 40 h` first: that is what enables it in this
    /// emulator (xterm's `allowC132`), as `QuietIngestTests` records.
    @Test("A snapshot's BEL, OSC 52 copy and DECCOLM ring nothing, copy nothing and report no size",
          arguments: TerminalEngineFactory.availableKinds)
    func ingestSnapshotMutesBellClipboardAndResize(kind: TerminalEngineKind) async {
        let muted = await makeFixture(kind: kind)
        let live = await makeFixture(kind: kind)
        defer {
            muted.tearDown()
            live.tearDown()
        }
        let marker = "tbd-engine-contract-\(UUID().uuidString)"
        let bytes = "\u{07}"
            + "\u{1b}]52;c;\(Data(marker.utf8).base64EncodedString())\u{07}"
            + "\u{1b}[?40h\u{1b}[?3h"

        muted.engine.ingestSnapshot(Data(bytes.utf8))
        await settle()
        #expect(muted.recorder.bells == 0, "a replayed BEL rang")
        #expect(muted.recorder.clipboardCopies.isEmpty, "a replayed OSC 52 reached clipboardCopy")
        #expect(muted.recorder.sizeChanges.isEmpty, "a replayed DECCOLM reported a size change")

        // Positive control: the same bytes fed live, into a second engine. Not
        // the first one: SwiftTerm coalesces bells 100 ms apart and counts the
        // muted BEL, and a settle lasts about that long, so a live BEL there
        // could be coalesced away and read as a muted one.
        feed(bytes, into: live.engine)
        let delivered = await waitUntil(
            "the fixture bytes to ring, copy and resize when fed live",
            observing: live.recorder
        ) {
            live.recorder.bells >= 1
                && !live.recorder.clipboardCopies.isEmpty
                && !live.recorder.sizeChanges.isEmpty
        }
        guard delivered else { return }
        #expect(live.recorder.clipboardCopies.first == Data(marker.utf8))
    }

    @Test("With program status reporting off, an OSC 7501 report is not delivered; on, it is",
          arguments: TerminalEngineFactory.availableKinds)
    func programStatusReportingOffDeliversNoPayload(kind: TerminalEngineKind) async {
        let fixture = await makeFixture(kind: kind)
        defer { fixture.tearDown() }

        fixture.engine.setProgramStatusReporting(enabled: false)
        // The gate is read where OSC events are delivered, on SwiftTerm's
        // observer queue, so a report still queued there when the gate turns
        // on would be delivered late. The OSC 777 behind it is the barrier:
        // that queue is serial, so once the notification has arrived, the
        // report ahead of it has been decided with the gate off.
        feed(Self.report + Self.notify, into: fixture.engine)
        let drained = await waitUntil("the OSC 777 barrier to arrive", observing: fixture.recorder) {
            !fixture.recorder.notifications.isEmpty
        }
        guard drained else { return }
        await settle()
        #expect(fixture.recorder.programStatusPayloads.isEmpty, "a report was delivered with reporting off")

        // Positive control: reporting on, the same bytes are delivered.
        fixture.engine.setProgramStatusReporting(enabled: true)
        feed(Self.report, into: fixture.engine)
        let delivered = await waitUntil("the report to be delivered with reporting on", observing: fixture.recorder) {
            !fixture.recorder.programStatusPayloads.isEmpty
        }
        guard delivered else { return }
        await settle()
        #expect(Self.parsed(fixture.recorder.programStatusPayloads) == [Self.parsedReport])
    }

    // MARK: - Routing

    /// A click is a left mouse-down and its release; a focus change is the view
    /// becoming first responder and giving it up. Both run for every engine.
    ///
    /// A control-mode paste is driven as a drop, which asks the same paste
    /// hook a pasteboard paste does, because a paste reads the general
    /// pasteboard and a test must not write it. The drop goes through the
    /// engine's `deliverDroppedText`, the entry each view's real drop calls.
    @Test("With click routing and paste interception off, no click, focus change or paste reaches the delegate; on, each does",
          arguments: TerminalEngineFactory.availableKinds)
    func routingOffReportsNoClickFocusOrPaste(kind: TerminalEngineKind) async throws {
        let fixture = await makeFixture(kind: kind)
        defer { fixture.tearDown() }
        let window = Self.mount(fixture.engine.view)
        defer {
            window.contentView = nil
            window.close()
        }
        await settle()
        fixture.recorder.reset()

        fixture.engine.setClickRouting(enabled: false)
        try await clickAndMoveFocus(on: fixture.engine, in: window)
        let clickCallsWhileOff = fixture.recorder.calls.filter { Self.clickRoutedCalls.contains($0) }
        #expect(clickCallsWhileOff.isEmpty, "click routing is off, yet the delegate was asked: \(clickCallsWhileOff)")

        // Positive control: on, the same gestures reach the delegate.
        fixture.recorder.reset()
        fixture.engine.setClickRouting(enabled: true)
        try await clickAndMoveFocus(on: fixture.engine, in: window)
        let clickCalls = fixture.recorder.calls
        #expect(clickCalls.contains("mouseDownClaimsFocus"), "a click with routing on must ask the delegate; observed \(clickCalls)")
        #expect(clickCalls.contains("focusChanged"), "a focus change with routing on must be reported; observed \(clickCalls)")

        fixture.recorder.reset()
        fixture.engine.setControlModePasteInterception(enabled: false)
        fixture.engine.deliverDroppedText("/tmp/tbd-engine-contract-drop.txt")
        await settle()
        #expect(!fixture.recorder.calls.contains("controlModePaste"),
                "paste interception is off, yet the paste was offered: \(fixture.recorder.calls)")

        // Positive control: on, the same drop is offered to the delegate.
        fixture.recorder.reset()
        fixture.engine.setControlModePasteInterception(enabled: true)
        fixture.engine.deliverDroppedText("/tmp/tbd-engine-contract-drop.txt")
        await settle()
        #expect(fixture.recorder.calls.contains("controlModePaste"),
                "a paste with interception on must be offered; observed \(fixture.recorder.calls)")
    }

    // MARK: - Factory

    /// Not parameterised: it is about what a libghostty request yields on this
    /// machine. With a Metal device it is libghostty and no fallback; without
    /// one it is SwiftTerm and one fallback that says why. The fallback is
    /// observed through the factory's `onFallback`.
    @Test("A libghostty request yields libghostty where it can start and SwiftTerm, reported once, where it cannot; a SwiftTerm request reports none")
    func ghosttyRequestFallsBackToSwiftTerm() {
        let suite = TestDefaultsSuite("TBDAppTests.TerminalEngineContract")
        defer { suite.tearDown() }
        let appearance = AppearanceSettings(defaults: suite.defaults)
        var fallbacks: [(requested: TerminalEngineKind, reason: String)] = []

        let ghostty = TerminalEngineFactory.make(
            kind: .ghostty,
            font: appearance.font,
            appearance: appearance,
            configuration: TerminalEngineConfiguration(),
            experimentEnabled: false,
            onFallback: { fallbacks.append((requested: $0, reason: $1)) })
        if TerminalEngineFactory.availableKinds.contains(.ghostty) {
            #expect(ghostty.kind == .ghostty)
            #expect(fallbacks.isEmpty, "a libghostty request that could start reported a fallback: \(fallbacks)")
        } else {
            #expect(ghostty.kind == .swiftTerm)
            #expect(fallbacks.count == 1)
            #expect(fallbacks.first?.requested == .ghostty)
            #expect(fallbacks.first?.reason.contains("Metal") == true, "reason: \(fallbacks.first?.reason ?? "none")")
        }

        fallbacks = []
        let swiftTerm = TerminalEngineFactory.make(
            kind: .swiftTerm,
            font: appearance.font,
            appearance: appearance,
            configuration: TerminalEngineConfiguration(),
            experimentEnabled: false,
            onFallback: { fallbacks.append((requested: $0, reason: $1)) })
        #expect(swiftTerm.kind == .swiftTerm)
        #expect(fallbacks.isEmpty, "a SwiftTerm request reported a fallback: \(fallbacks)")
    }

    // MARK: - Helpers

    /// The fixture report, parsed as the daemon parses it.
    private static var parsedReport: ProgramStatusPayload? {
        ProgramStatusParser.parse(Array(reportData.utf8))
    }

    private static func parsed(_ payloads: [[UInt8]]) -> [ProgramStatusPayload?] {
        payloads.map { ProgramStatusParser.parse($0) }
    }

    /// The delegate methods only click routing reaches.
    private static let clickRoutedCalls: Set<String> = ["mouseDownClaimsFocus", "focusChanged"]

    /// Puts `view` in a borderless window far off every display, never ordered
    /// front: the window exists so the view has one, not so anything is seen.
    private static func mount(_ view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let ground = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        ground.addSubview(view)
        window.contentView = ground
        return window
    }

    /// One click, then one focus change each way, then a settle. Events go
    /// straight to the view's overrides: nothing dispatches events to a window
    /// that is never key.
    private func clickAndMoveFocus(on engine: any TerminalEngine, in window: NSWindow) async throws {
        let view = engine.view
        let location = view.convert(CGPoint(x: 10, y: 10), to: nil)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        view.mouseUp(with: up)

        window.makeFirstResponder(nil)
        window.makeFirstResponder(view)
        window.makeFirstResponder(nil)
        await settle()
    }

    /// `line N`, exactly: what one whole feed leaves on row 0.
    private static func isWholeLine(_ text: String) -> Bool {
        guard text.hasPrefix("line ") else { return false }
        let number = text.dropFirst("line ".count)
        return Int(number) != nil
    }

    private func feed(_ text: String, into engine: any TerminalEngine) {
        engine.feed(Array(text.utf8)[...])
    }

    /// One main-queue turn: resumes behind everything already queued on main.
    private func mainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// `QuietIngestTests`' settle rule: five main-queue turns with a short real
    /// pause between them. The turns are what the delegate hops need; the
    /// pauses cover the OSC observer's private serial queue.
    private func settle() async {
        for _ in 0..<5 { await hop() }
    }

    /// Polls `condition` on main through `pollUntilTrue` until it holds,
    /// bounded by the shared saturated-pass budget. Only positive assertions
    /// use it, so the budget is spent only by a failing test.
    ///
    /// Returns `true` once the condition holds, and the caller goes on. On a
    /// timeout it records a `ContractWaitTimedOut` naming what was awaited,
    /// what `recorder` holds at that moment and how long the wait took: an
    /// error, because only an error's text reaches the primary failure line
    /// that CI summaries keep (Tests/CLAUDE.md, rule 4). On cancellation it
    /// records nothing, because the harness ended the test. Both return
    /// `false`, and the caller stops there.
    @discardableResult
    private func waitUntil(
        _ what: String,
        observing recorder: RecordingEngineDelegate,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        let outcome = await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(20)
        ) { @Sendable in
            await MainActor.run { condition() }
        }
        switch outcome {
        case .satisfied:
            return true
        case .cancelled:
            return false
        case .timedOut:
            Issue.record(ContractWaitTimedOut(
                what: what, observed: recorder.summary, elapsed: ContinuousClock.now - start))
            return false
        }
    }

    private func hop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                continuation.resume()
            }
        }
    }
}

// MARK: - Fixture

/// What the background feed test's two sides share: the thread the feeder ran
/// on, the last line fed, whether the feeder is done, and how many of main's
/// reads it overlapped.
private struct FeedProgress: Sendable {
    var feederThread: String?
    var lastFed: Int?
    var finished = false
    var overlappingReads = 0
}

/// A `waitUntil` timeout, as the error its issue records, so what was awaited,
/// what was observed and how long the wait took all reach the primary failure
/// line.
private struct ContractWaitTimedOut: Error, CustomStringConvertible {
    let what: String
    let observed: String
    let elapsed: Duration

    var description: String {
        "Timed out after \(elapsed) waiting for \(what); observed \(observed)"
    }
}

/// Which thread is running this code.
///
/// Synchronous on purpose: `Thread.current` is unavailable from an async
/// context, because the answer can change across a suspension point. The
/// feeder calls it with no suspension between it and its loop, so it names the
/// thread the loop runs on.
private func runningThreadName() -> String? {
    Thread.current.name
}

/// One engine built the way the coordinators build theirs, with a recorder as
/// its delegate and isolated defaults behind its appearance.
@MainActor
private final class EngineFixture {
    let suite: TestDefaultsSuite
    let appearance: AppearanceSettings
    let engine: any TerminalEngine
    let recorder: RecordingEngineDelegate

    init(kind: TerminalEngineKind) {
        // Isolated defaults: `UserDefaults.standard` on this unbundled
        // executable is the developer's real TBDApp.plist.
        let suite = TestDefaultsSuite("TBDAppTests.TerminalEngineContract")
        let appearance = AppearanceSettings(defaults: suite.defaults)
        let engine = TerminalEngineFactory.make(
            kind: kind,
            font: appearance.font,
            appearance: appearance,
            configuration: TerminalEngineConfiguration(),
            experimentEnabled: false)
        let recorder = RecordingEngineDelegate()
        engine.delegate = recorder
        self.suite = suite
        self.appearance = appearance
        self.engine = engine
        self.recorder = recorder
    }

    func tearDown() {
        engine.delegate = nil
        suite.tearDown()
    }
}

/// Records every `TerminalEngineDelegate` call, in order, and what it carried.
/// Acts on nothing: no pty, no pasteboard, no beep.
@MainActor
private final class RecordingEngineDelegate: TerminalEngineDelegate {
    /// One `sizeChanged`, with the engine's `gridSize` as read inside the call.
    struct SizeChange {
        let cols: Int
        let rows: Int
        let gridCols: Int
        let gridRows: Int
    }

    private(set) var calls: [String] = []
    private(set) var sent: [UInt8] = []
    private(set) var sizeChanges: [SizeChange] = []
    private(set) var bells = 0
    private(set) var clipboardCopies: [Data] = []
    private(set) var notifications: [(title: String, body: String)] = []
    private(set) var programStatusPayloads: [[UInt8]] = []

    /// Every call in order and the bytes sent, for a timeout's message.
    var summary: String {
        "calls \(calls), sent bytes \(sent)"
    }

    func reset() {
        calls = []
        sent = []
        sizeChanges = []
        bells = 0
        clipboardCopies = []
        notifications = []
        programStatusPayloads = []
    }

    func engine(_ e: any TerminalEngine, send data: ArraySlice<UInt8>) {
        calls.append("send")
        sent.append(contentsOf: data)
    }

    func engine(_ e: any TerminalEngine, sizeChanged cols: Int, rows: Int) {
        calls.append("sizeChanged")
        let grid = e.gridSize
        sizeChanges.append(SizeChange(cols: cols, rows: rows, gridCols: grid.cols, gridRows: grid.rows))
    }

    func engineBell(_ e: any TerminalEngine) {
        calls.append("bell")
        bells += 1
    }

    func engine(_ e: any TerminalEngine, clipboardCopy content: Data) {
        calls.append("clipboardCopy")
        clipboardCopies.append(content)
    }

    func engine(_ e: any TerminalEngine, openLink link: String, params: [String: String]) {
        calls.append("openLink")
    }

    func engine(_ e: any TerminalEngine, notification title: String, body: String) {
        calls.append("notification")
        notifications.append((title: title, body: body))
    }

    func engine(_ e: any TerminalEngine, programStatusPayload payload: [UInt8], observedAt: Date) {
        calls.append("programStatusPayload")
        programStatusPayloads.append(payload)
    }

    func engine(_ e: any TerminalEngine, filePathClicked path: String) {
        calls.append("filePathClicked")
    }

    func engineRequestsCloseTab(_ e: any TerminalEngine) {
        calls.append("requestsCloseTab")
    }

    func engineReady(_ e: any TerminalEngine) {
        calls.append("ready")
    }

    func engine(_ e: any TerminalEngine, focusChanged focused: Bool) {
        calls.append("focusChanged")
    }

    func engineMouseDownClaimsFocus(_ e: any TerminalEngine) -> Bool {
        calls.append("mouseDownClaimsFocus")
        return false
    }

    func engineMovedToWindow(_ e: any TerminalEngine) {
        calls.append("movedToWindow")
    }

    func engine(_ e: any TerminalEngine, controlModePaste data: Data) -> Bool {
        calls.append("controlModePaste")
        return false
    }
}
