import Clocks
import Darwin
import Foundation
import SwiftTerm
// Scoped, beside SwiftTerm: only the writer's overlong-sequence opener.
import enum TBDGhosttyCore.GhosttySnapshotWriter
import Testing
import TestSupport

@testable import TBDDaemonLib

/// An attach that lands while the child is part-way through a sequence.
///
/// The quiesce reads what the pty holds and stops there, and a child writing
/// a frame larger than the pty buffer is routinely mid-sequence at that point,
/// with the rest a moment behind. The snapshot that follows feeds the
/// emulator bytes of its own — a `DECRQM` query per mode, and on an alt screen
/// a toggle to the primary — and the first `ESC` among them ends the child's
/// sequence early. The rest of it then prints as text twice over: in the
/// daemon's emulator when the drain resumes, and in the viewer, which starts
/// reading the pty with its parser in the ground state. So the quiesce waits
/// for the rest before the snapshot is taken.
///
/// Driven through a `HolderReader` over a socketpair, never started, as
/// `HolderScreenContractTests` does: `suspendDraining` on an idle reader runs
/// the same quiesce the attach path runs, and `snapshotPreamble` is the
/// snapshot the attach sends. The rest of the sequence is delivered by the
/// read-fault seam: the first read the quiesce makes finds nothing and puts
/// the rest on the socket, which is a child finishing its write just after
/// the attach looked. A reader that does not wait has taken its snapshot
/// before reading again, so the rest reaches whoever reads the pty next.
///
/// The two emulators meet this differently, and the screen tests run against
/// both. The SwiftTerm emulator's snapshot feeds its own terminal, so the
/// quiesce waits for the sequence to end first. The libghostty emulator's
/// snapshot only reads its terminal and ends with the open sequence's bytes,
/// so its quiesce does not wait: the viewer's parser is left where the
/// daemon's was, and the rest, read from the pty, finishes the sequence there.
/// The one sequence it waits for is one longer than libghostty keeps the bytes
/// of, which the snapshot could end only by dropping the rest. The other
/// bounded-wait tests are the SwiftTerm emulator's.
@Suite(.fastPassBounded) struct HolderAttachSequenceBoundaryTests {

    /// One kind of sequence a child can be part-way through, split where an
    /// attach can find it.
    struct OpenSequence: Sendable, CustomTestStringConvertible {
        let name: String
        /// What the child has written when the attach looks.
        let opened: [UInt8]
        /// What the child writes next, ending in visible text.
        let rest: [UInt8]
        /// Text that appears on the screen only if the sequence was cut short.
        let leak: String
        /// Text the screen must show once the rest has arrived.
        let shows: String

        var testDescription: String { name }

        init(_ name: String, opened: String, rest: String, leak: String, shows: String = "AFTER") {
            self.init(name, opened: Array(opened.utf8), rest: Array(rest.utf8), leak: leak, shows: shows)
        }

        init(_ name: String, opened: [UInt8], rest: [UInt8], leak: String, shows: String) {
            self.name = name
            self.opened = opened
            self.rest = rest
            self.leak = leak
            self.shows = shows
        }
    }

    private static let esc = "\u{1b}"

    static let openSequences: [OpenSequence] = [
        OpenSequence(
            "an OSC title", opened: "\(esc)]0;HALF-OF-A-", rest: "TITLE-PAYLOAD\u{07}AFTER",
            leak: "PAYLOAD"),
        OpenSequence(
            "an OSC 8 link", opened: "\(esc)]8;;https://example.com/",
            rest: "LINK-PAYLOAD\(esc)\\AFTER", leak: "PAYLOAD"),
        OpenSequence(
            "a sixel DCS", opened: "\(esc)Pq#0;2;0;0;0", rest: "#0!4~PAYLOAD\(esc)\\AFTER",
            leak: "PAYLOAD"),
        OpenSequence(
            "a kitty APC", opened: "\(esc)_Ga=q,i=31;AAAA", rest: "PAYLOAD\(esc)\\AFTER",
            leak: "PAYLOAD"),
        OpenSequence(
            "a CSI's parameters", opened: "\(esc)[38;5;", rest: "196mAFTER", leak: "196m"),
        OpenSequence("a lone ESC", opened: "\(esc)", rest: "[1mAFTER", leak: "[1m"),
        // U+20AC split after its second byte. Cut short, the third byte prints
        // on its own as U+00AC.
        OpenSequence(
            "a UTF-8 character", opened: [0xE2, 0x82], rest: [0xAC] + Array("AFTER".utf8),
            leak: "\u{AC}", shows: "\u{20AC}AFTER"),
    ]

    // MARK: - The viewer

    /// What a viewer paints: the snapshot, then whatever is still on the pty
    /// for it to read. Cut short, the sequence's rest is the first thing the
    /// viewer reads, and its parser has no way to know a sequence was open.
    @Test(
        "a viewer that attaches mid-sequence never prints the sequence's rest",
        arguments: openSequences, HolderEmulatorKind.allCases)
    func theViewerNeverPrintsTheRest(sequence: OpenSequence, emulator: HolderEmulatorKind) async throws {
        let harness = try Harness(deliveringOnFirstRead: sequence.rest, emulator: emulator)
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data(Array("BEFORE\r\n".utf8) + sequence.opened))

        let vended = try await harness.reader.suspendDraining()
        defer { close(vended) }
        let preamble = await harness.reader.snapshotPreamble()

        let viewer = ViewerTerminal(columns: 40, rows: 8)
        viewer.feed(preamble)
        viewer.feed(Self.readAvailable(from: vended))
        let painted = viewer.screenText()

        #expect(painted.contains("BEFORE"), "the viewer painted: \(painted.debugDescription)")
        #expect(painted.contains(sequence.shows), "the viewer painted: \(painted.debugDescription)")
        #expect(
            !painted.contains(sequence.leak),
            """
            the attach cut \(sequence.name) short, so the viewer printed its rest as text: \
            \(painted.debugDescription)
            """)
    }

    // MARK: - The daemon's model

    /// The daemon's own emulator, which keeps answering `terminal.output`
    /// while a viewer holds the pty and goes back to reading it when an attach
    /// is cancelled. A second quiesce is that next read: it drains what has
    /// arrived since, as a resumed drain would.
    @Test(
        "the daemon's screen keeps a sequence an attach found half-written",
        arguments: openSequences, HolderEmulatorKind.allCases)
    func theDaemonsScreenKeepsTheSequence(sequence: OpenSequence, emulator: HolderEmulatorKind) async throws {
        let harness = try Harness(deliveringOnFirstRead: sequence.rest, emulator: emulator)
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data(Array("BEFORE\r\n".utf8) + sequence.opened))

        close(try await harness.reader.suspendDraining())
        _ = await harness.reader.snapshotPreamble()
        close(try await harness.reader.suspendDraining())
        let screen = await harness.reader.renderScreen()

        #expect(screen.contains("BEFORE"), "the daemon's screen: \(screen.debugDescription)")
        #expect(screen.contains(sequence.shows), "the daemon's screen: \(screen.debugDescription)")
        #expect(
            !screen.contains(sequence.leak),
            """
            the snapshot's queries cut \(sequence.name) short, so the daemon's screen printed \
            its rest as text: \(screen.debugDescription)
            """)
    }

    // MARK: - libghostty does not wait

    /// The libghostty emulator's snapshot carries an open sequence instead of
    /// waiting for it: the quiesce hands the pty over at once, logs no
    /// abandoned wait, and the viewer that replays the snapshot shows the
    /// screen and none of the sequence's payload.
    @Test("a libghostty attach hands the pty over without waiting for an open sequence")
    func libghosttyDoesNotWaitForTheSequence() async throws {
        let budget: Duration = .milliseconds(20)
        let harness = try Harness(reads: [], waitingAtMost: budget, emulator: .ghostty)
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data("BEFORE\r\n\(Self.esc)]0;never-ends".utf8))

        let vended = try await harness.reader.suspendDraining()
        defer { close(vended) }
        let waited = harness.elapsed
        let abandoned = await harness.reader.abandonedSequenceBoundaryWaits
        let preamble = await harness.reader.snapshotPreamble()

        #expect(waited == .zero, "the libghostty attach waited \(waited) for the child's sequence")
        #expect(abandoned == 0, "the libghostty attach logged a wait it should never have started")
        let viewer = ViewerTerminal(columns: 40, rows: 8)
        viewer.feed(preamble)
        let painted = viewer.screenText()
        #expect(painted.contains("BEFORE"), "the viewer painted: \(painted.debugDescription)")
        #expect(!painted.contains("never-ends"), "the viewer printed the open title: \(painted.debugDescription)")
    }

    /// A sequence longer than libghostty keeps the bytes of cannot be carried,
    /// so the libghostty attach waits for it, as the SwiftTerm attach waits
    /// for any. When the rest arrives the snapshot is taken at ground, and the
    /// writer has no need for the opener that would drop it.
    @Test("a libghostty attach waits for a sequence too long to carry")
    func libghosttyWaitsForASequenceTooLongToCarry() async throws {
        let budget: Duration = .milliseconds(20)
        let harness = try Harness(
            reads: [.deliver(Array("PAYLOAD\u{07}AFTER".utf8))], waitingAtMost: budget, emulator: .ghostty)
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Self.overlongTitle)

        let vended = try await harness.reader.suspendDraining()
        defer { close(vended) }
        let abandoned = await harness.reader.abandonedSequenceBoundaryWaits
        let preamble = await harness.reader.snapshotPreamble()

        #expect(harness.script.reads > 1, "the attach never read on toward the end of the sequence")
        #expect(abandoned == 0, "the attach gave up on a sequence whose rest arrived")
        #expect(
            !preamble.suffix(GhosttySnapshotWriter.overlongSequenceSink.count)
                .elementsEqual(GhosttySnapshotWriter.overlongSequenceSink),
            "the snapshot ends in the opener that drops the rest, so the attach did not wait")
        let viewer = ViewerTerminal(columns: 40, rows: 8)
        viewer.feed(preamble)
        viewer.feed(Self.readAvailable(from: vended))
        let painted = viewer.screenText()
        #expect(painted.contains("BEFORE"), "the viewer painted: \(painted.debugDescription)")
        #expect(painted.contains("AFTER"), "the viewer painted: \(painted.debugDescription)")
        #expect(!painted.contains("PAYLOAD"), "the viewer printed the title's rest: \(painted.debugDescription)")
    }

    /// The wait is for the over-long sequence, not for ground: the read that
    /// ends it can open a short one in the same breath, which the snapshot
    /// carries. The wait stops there rather than running out its budget and
    /// logging an abandoned wait for a sequence it never needed to see end.
    @Test("a libghostty attach stops waiting once only a short sequence is open")
    func libghosttyStopsWaitingAtAShortSequence() async throws {
        let budget: Duration = .milliseconds(20)
        let rest = Array("PAYLOAD\u{07}AFTER\(Self.esc)]0;short".utf8)
        let harness = try Harness(reads: [.deliver(rest)], waitingAtMost: budget, emulator: .ghostty)
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Self.overlongTitle)

        let vended = try await harness.reader.suspendDraining()
        defer { close(vended) }
        let waited = harness.elapsed
        let abandoned = await harness.reader.abandonedSequenceBoundaryWaits
        let preamble = await harness.reader.snapshotPreamble()

        #expect(harness.script.reads > 1, "the attach never read on toward the end of the over-long title")
        #expect(abandoned == 0, "the attach waited out its budget for a sequence the snapshot carries")
        #expect(waited < budget, "the attach waited \(waited) after the over-long title ended")
        let open = Array("\(Self.esc)]0;short".utf8)
        #expect(
            preamble.suffix(open.count).elementsEqual(open),
            "the snapshot does not end with the short title, for the viewer to finish")
    }

    /// The wait for a sequence too long to carry is bounded like any other.
    /// When it runs out, the snapshot ends with the opener that takes in the
    /// rest, and the viewer still gets the screen.
    @Test("a libghostty attach still hands the pty over when a sequence too long to carry never ends")
    func libghosttysWaitIsBounded() async throws {
        let budget: Duration = .milliseconds(20)
        let harness = try Harness(reads: [], waitingAtMost: budget, emulator: .ghostty)
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Self.overlongTitle)

        let vended = try await harness.reader.suspendDraining()
        defer { close(vended) }
        let waited = harness.elapsed
        let abandoned = await harness.reader.abandonedSequenceBoundaryWaits
        let preamble = await harness.reader.snapshotPreamble()

        #expect(waited == budget, "the attach waited \(waited) for a sequence that never ends")
        #expect(abandoned == 1, "the attach gave up waiting without logging that it had")
        #expect(
            preamble.suffix(GhosttySnapshotWriter.overlongSequenceSink.count)
                .elementsEqual(GhosttySnapshotWriter.overlongSequenceSink),
            "a snapshot inside a sequence too long to carry should end with the opener that drops the rest")
        let viewer = ViewerTerminal(columns: 40, rows: 8)
        viewer.feed(preamble)
        let painted = viewer.screenText()
        #expect(painted.contains("BEFORE"), "the viewer painted: \(painted.debugDescription)")
        #expect(!painted.contains("tttt"), "the viewer printed the open title: \(painted.debugDescription)")
    }

    /// A line, then a window title longer than the 64 KiB libghostty keeps of
    /// an open sequence, left open.
    private static let overlongTitle = Data(
        Array("BEFORE\r\n\(esc)]2;".utf8) + [UInt8](repeating: UInt8(ascii: "t"), count: 70_000))

    // MARK: - The wait is bounded (SwiftTerm)

    /// A child can leave a sequence open for good. The attach waits a bounded
    /// time for it and then hands the pty over anyway, because an attach that
    /// never returned would be worse than a remainder printed as text.
    @Test("an attach still hands the pty over when the child never finishes the sequence")
    func theWaitIsBounded() async throws {
        // Four polls' worth of budget, which tells a wait that ran out from
        // one that never started; each `ImmediateClock` sleep costs a
        // `megaYield`, so no more than that.
        let budget: Duration = .milliseconds(20)
        let harness = try Harness(reads: [], waitingAtMost: budget)
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data("BEFORE\r\n\(Self.esc)]0;never-ends".utf8))

        let vended = try await harness.reader.suspendDraining()
        defer { close(vended) }
        let waited = harness.elapsed
        let abandoned = await harness.reader.abandonedSequenceBoundaryWaits
        let preamble = await harness.reader.snapshotPreamble()

        #expect(waited == budget, "the attach waited \(waited) for a sequence that never ends")
        #expect(abandoned == 1, "the attach gave up waiting without logging that it had")
        let viewer = ViewerTerminal(columns: 40, rows: 8)
        viewer.feed(preamble)
        let painted = viewer.screenText()
        #expect(painted.contains("BEFORE"), "the viewer painted: \(painted.debugDescription)")
    }

    /// A child that exits part-way through a sequence will never finish it,
    /// so the attach stops waiting the moment the pty says so, and says
    /// nothing about a remainder that cannot come.
    @Test("an attach stops waiting at once when the child is gone before the wait")
    func childGoneBeforeTheWait() async throws {
        let budget: Duration = .milliseconds(20)
        let harness = try Harness(reads: [.fail(EIO)], waitingAtMost: budget)
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data("BEFORE\r\n\(Self.esc)]0;cut-off".utf8))

        close(try await harness.reader.suspendDraining())
        let waited = harness.elapsed
        let abandoned = await harness.reader.abandonedSequenceBoundaryWaits

        #expect(waited == .zero, "the attach waited \(waited) for a child that had already gone")
        #expect(abandoned == 0, "the attach logged a remainder that a gone child cannot send")
    }

    @Test("an attach stops waiting at once when the child goes during the wait")
    func childGoneDuringTheWait() async throws {
        let budget: Duration = .milliseconds(20)
        // The quiesce finds nothing, and the first poll of the wait finds the
        // child gone.
        let harness = try Harness(reads: [.deliver([]), .fail(EIO)], waitingAtMost: budget)
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data("BEFORE\r\n\(Self.esc)]0;cut-off".utf8))

        close(try await harness.reader.suspendDraining())
        let waited = harness.elapsed
        let abandoned = await harness.reader.abandonedSequenceBoundaryWaits

        #expect(
            waited == HolderReader.stopPollInterval,
            "the attach waited \(waited) after the child had gone")
        #expect(abandoned == 0, "the attach logged a remainder that a gone child cannot send")
    }

    /// A cancelled attach waits for nothing: the first sleep the wait
    /// reaches throws, and the wait ends there, saying nothing about a
    /// remainder.
    @Test("a cancelled attach stops waiting for the child's sequence at once")
    func aCancelledAttachDoesNotWait() async throws {
        let harness = try Harness(reads: [], waitingAtMost: .milliseconds(20))
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data("BEFORE\r\n\(Self.esc)]0;never-ends".utf8))

        let reader = harness.reader
        let handOver = Task {
            // Cancelled before it asks, so every sleep it reaches throws.
            withUnsafeCurrentTask { task in
                task?.cancel()
                return
            }
            return try await reader.suspendDraining()
        }
        close(try await handOver.value)
        let waited = harness.elapsed
        let abandoned = await harness.reader.abandonedSequenceBoundaryWaits

        #expect(waited == .zero, "a cancelled attach waited \(waited) for the child's sequence")
        #expect(abandoned == 0, "a cancelled attach logged that it had given up waiting")
    }

    /// A child that never stops writing, and never finishes its sequence,
    /// cannot hold the attach past its budget: the budget is time on the
    /// reader's clock, checked before every read. Each reading of that clock
    /// is a millisecond later than the last, and the child has ten thousand
    /// writes to give. A wait that read until the pty would block, or that
    /// counted polls rather than time, would take hundreds of them.
    @Test("a child that never stops writing cannot hold the attach past its budget")
    func aNonstopWriterIsCutOff() async throws {
        let chunk = [UInt8](repeating: UInt8(ascii: "A"), count: 512)
        let harness = try Harness(
            reads: Array(repeating: .write(chunk), count: 10_000),
            waitingAtMost: .milliseconds(20),
            on: SteppingClock(step: .milliseconds(1)))
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data("BEFORE\r\n\(Self.esc)]0;never-ends".utf8))

        close(try await harness.reader.suspendDraining())
        let reads = harness.script.reads
        let abandoned = await harness.reader.abandonedSequenceBoundaryWaits

        #expect(abandoned == 1, "the attach stopped waiting without logging that it had")
        #expect(reads < 200, "the attach made \(reads) reads of a child that never stops writing")
    }

    // MARK: - Support

    /// Everything a vended descriptor will give right now. The descriptor is
    /// non-blocking (the flag lives on the open file description the reader
    /// set it on), so this stops at the first `EAGAIN` rather than waiting.
    private static func readAvailable(from fd: Int32) -> Data {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
                continue
            }
            if count < 0, errno == EINTR { continue }
            return collected
        }
    }

    /// Scripted results for the reader's first reads, in order; every read
    /// after the script runs out is a real one.
    private final class ReadScript: @unchecked Sendable {
        enum Step: Sendable {
            /// Puts the bytes on the socket and reports the read as finding
            /// nothing: the child finishing its write a moment after the
            /// reader looked.
            case deliver([UInt8])
            /// Puts the bytes on the socket and lets the read happen, so it
            /// finds them: a child writing as fast as the reader reads.
            case write([UInt8])
            /// Reports the read as failing with this errno.
            case fail(Int32)
        }

        private let lock = NSLock()
        private let steps: [Step]
        private var nextStep = 0
        private var readCount = 0
        private let socket: Int32

        init(_ steps: [Step], socket: Int32) {
            self.steps = steps
            self.socket = socket
        }

        /// How many reads the reader has made.
        var reads: Int { lock.withLock { readCount } }

        func nextErrno() -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            readCount += 1
            guard nextStep < steps.count else { return nil }
            let step = steps[nextStep]
            nextStep += 1
            switch step {
            case .deliver(let bytes):
                put(bytes)
                return EAGAIN
            case .write(let bytes):
                put(bytes)
                return nil
            case .fail(let code):
                return code
            }
        }

        /// A few bytes into an empty socket buffer: every read drains it.
        /// Were a write ever to fall short, the screens would lack `shows`
        /// and the test would say so.
        private func put(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            _ = bytes.withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
        }
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
            try Task.checkCancellation()
            lock.withLock {
                if current < deadline { current = deadline }
            }
        }
    }

    /// A `HolderReader` over one end of a socketpair, never started, on an
    /// `ImmediateClock` by default so a wait costs no wall time and its length
    /// can be read back.
    private struct Harness {
        let reader: HolderReader
        /// The reader's scripted reads, and the count of every read it made.
        let script: ReadScript
        private let ours: Int32
        private let measure: @Sendable () -> Duration

        /// How far the reader's clock has moved since the harness was made.
        var elapsed: Duration { measure() }

        /// The child finishes its sequence just after the quiesce looks.
        init(deliveringOnFirstRead rest: [UInt8], emulator: HolderEmulatorKind = .swiftTerm) throws {
            try self.init(reads: [.deliver(rest)], emulator: emulator)
        }

        init(
            reads: [ReadScript.Step],
            waitingAtMost budget: Duration = HolderReader.defaultSequenceBoundaryBudget,
            emulator: HolderEmulatorKind = .swiftTerm
        ) throws {
            try self.init(
                reads: reads, waitingAtMost: budget, on: ImmediateClock<Duration>(), emulator: emulator)
        }

        init<C: Clock>(
            reads: [ReadScript.Step], waitingAtMost budget: Duration, on clock: C,
            emulator: HolderEmulatorKind = .swiftTerm
        ) throws where C.Duration == Duration {
            var pair: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            ours = pair[1]
            let readScript = ReadScript(reads, socket: pair[1])
            script = readScript
            let origin = clock.now
            measure = { origin.duration(to: clock.now) }
            // The reader owns `pair[0]` and its `deinit` closes it, which is
            // safe because the reader is never started.
            reader = HolderReader(
                sessionID: UUID(),
                ptyFD: pair[0],
                columns: 40,
                rows: 8,
                scrollbackLines: 200,
                sequenceBoundaryBudget: budget,
                readFault: HolderReadFault(nextErrno: { readScript.nextErrno() }),
                emulator: emulator,
                observedChildFromStart: true,
                clock: clock)
        }

        func tearDown() {
            close(ours)
        }
    }

    /// A terminal that has never seen the session, for replaying a snapshot
    /// into. `Terminal.tdel` is weak, so the delegate is held here.
    private final class ViewerTerminal {
        private let terminal: SwiftTerm.Terminal
        private let delegate = SilentDelegate()

        init(columns: Int, rows: Int) {
            terminal = SwiftTerm.Terminal(
                delegate: delegate, options: TerminalOptions(cols: columns, rows: rows))
        }

        func feed(_ data: Data) {
            terminal.terminalLock.withLock { terminal.feed(byteArray: [UInt8](data)) }
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
}
