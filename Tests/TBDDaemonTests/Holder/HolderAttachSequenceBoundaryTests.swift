import Clocks
import Darwin
import Foundation
import SwiftTerm
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
    @Test("a viewer that attaches mid-sequence never prints the sequence's rest", arguments: openSequences)
    func theViewerNeverPrintsTheRest(sequence: OpenSequence) async throws {
        let harness = try Harness(deliveringOnFirstRead: sequence.rest)
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
    @Test("the daemon's screen keeps a sequence an attach found half-written", arguments: openSequences)
    func theDaemonsScreenKeepsTheSequence(sequence: OpenSequence) async throws {
        let harness = try Harness(deliveringOnFirstRead: sequence.rest)
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

    // MARK: - The wait is bounded

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
            /// Reports the read as failing with this errno.
            case fail(Int32)
        }

        private let lock = NSLock()
        private var steps: [Step]
        private let socket: Int32

        init(_ steps: [Step], socket: Int32) {
            self.steps = steps
            self.socket = socket
        }

        func nextErrno() -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            guard !steps.isEmpty else { return nil }
            switch steps.removeFirst() {
            case .deliver(let rest):
                // A few bytes into an empty socket buffer. Were the write ever
                // to fall short, the screens would lack `shows` and the test
                // would say so.
                if !rest.isEmpty {
                    _ = rest.withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
                }
                return EAGAIN
            case .fail(let code):
                return code
            }
        }
    }

    /// A `HolderReader` over one end of a socketpair, never started, on an
    /// `ImmediateClock` so a wait costs no wall time and its length can be
    /// read back.
    private struct Harness {
        let reader: HolderReader
        private let ours: Int32
        private let clock: ImmediateClock<Duration>
        private let start: ImmediateClock<Duration>.Instant

        /// How long the reader has slept on its clock since the harness was
        /// made.
        var elapsed: Duration { start.duration(to: clock.now) }

        /// The child finishes its sequence just after the quiesce looks.
        init(deliveringOnFirstRead rest: [UInt8]) throws {
            try self.init(reads: [.deliver(rest)])
        }

        init(
            reads: [ReadScript.Step],
            waitingAtMost budget: Duration = HolderReader.defaultSequenceBoundaryBudget
        ) throws {
            var pair: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            ours = pair[1]
            let script = ReadScript(reads, socket: pair[1])
            let clock = ImmediateClock<Duration>()
            self.clock = clock
            start = clock.now
            // The reader owns `pair[0]` and its `deinit` closes it, which is
            // safe because the reader is never started.
            reader = HolderReader(
                sessionID: UUID(),
                ptyFD: pair[0],
                columns: 40,
                rows: 8,
                scrollbackLines: 200,
                sequenceBoundaryBudget: budget,
                readFault: HolderReadFault(nextErrno: { script.nextErrno() }),
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
