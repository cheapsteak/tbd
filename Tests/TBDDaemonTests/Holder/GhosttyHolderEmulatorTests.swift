import Darwin
import Foundation
import Testing
// Scoped, so that only these names come from the core: the constants the
// daemon's answers are held to, and a viewer to take a handback from.
import class TBDGhosttyCore.GhosttyTerminal
import struct TBDGhosttyCore.GhosttyTerminalCallbacks
import enum TBDGhosttyCore.GhosttySnapshotWriter
import enum TBDGhosttyCore.TerminalDeviceIdentity

@testable import TBDDaemonLib
import TBDShared

/// What the libghostty holder emulator owes the child and the next viewer
/// beyond the suites both emulators run: the device identity it answers with,
/// a resize that sends the child nothing, a handback that leaves no stale
/// mode for the next attach, a take-back that leaves no sequence open, a
/// snapshot that waits only for a sequence too long to carry, and an attach
/// that survives a writer that fails. Design:
/// `docs/specs/2026-11-13-swiftterm-retirement-design.md`, stream C.
///
/// The reader-level tests drive a real `HolderReader` over a socketpair,
/// never started, as `HolderProgramStatusTests` does: the emulator's replies
/// are written to the reader's end of the pair, so whatever the child would
/// have received is readable from ours as soon as the call returns.
@Suite struct GhosttyHolderEmulatorTests {

    private static let esc = "\u{1b}"

    // MARK: - Device identity

    /// DA1, DA2 and XTVERSION are answered with the frozen bytes the SwiftTerm
    /// emulator answers with, byte for byte, so a program that decides what
    /// the terminal is from them decides the same under either emulator.
    @Test func deviceQueriesAreAnsweredWithTheFrozenIdentity() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let queries: [(name: String, query: String, reply: [UInt8])] = [
            ("DA1", "\(Self.esc)[c", TerminalDeviceIdentity.da1Reply),
            ("DA2", "\(Self.esc)[>c", TerminalDeviceIdentity.da2Reply),
            ("XTVERSION", "\(Self.esc)[>q", TerminalDeviceIdentity.xtversionReply),
        ]
        for (name, query, reply) in queries {
            await harness.reader.feedChildOutputForTesting(Data(query.utf8))
            let answered = harness.readReplies()
            #expect(answered == reply, "\(name) was answered with \(Self.describe(answered))")
        }
    }

    // MARK: - A resize sends the child nothing

    /// A child that asked for in-band size reports (mode 2048) gets none from
    /// a resize the daemon makes while a viewer holds the pty: the viewer
    /// answers for the terminal then, and the daemon must not write into the
    /// child's input. The SwiftTerm emulator has no mode 2048, so it never
    /// sent one either.
    @Test func aResizeWhileAViewerHoldsThePtySendsTheChildNothing() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data("\(Self.esc)[?2048h".utf8))
        // Whatever turning the mode on drew is the child's own answer.
        _ = harness.readReplies()
        // The control: the daemon's terminal has the mode on, so a resize it
        // did not mute would report the new size.
        await harness.reader.feedChildOutputForTesting(Data("\(Self.esc)[?2048$p".utf8))
        let mode = String(decoding: harness.readReplies(), as: UTF8.self)
        #expect(mode.contains("\(Self.esc)[?2048;1$y"), "mode 2048 reads back as \(mode.debugDescription)")

        close(try await harness.reader.suspendDraining())
        await harness.reader.resizeGrid(columns: 50, rows: 10)

        let sent = harness.readReplies()
        #expect(sent.isEmpty, "the resize wrote \(Self.describe(sent)) into the child's input")
    }

    /// The same at the emulator, for every resize: nothing reaches the reply
    /// sink, and the grid still takes the new size.
    @Test func theEmulatorsResizeReachesNoReplySink() {
        let replies = ReplyBox()
        let emulator = Self.makeEmulator(reply: { replies.append($0) })
        #expect(emulator.kind == .ghostty)
        emulator.feed(Array("\(Self.esc)[?2048h".utf8)[...])
        let before = replies.all

        emulator.resize(columns: 50, rows: 10)

        #expect(replies.all == before, "the resize sent \(Self.describe(Array(replies.all.dropFirst(before.count))))")
        #expect(emulator.size.columns == 50)
        #expect(emulator.size.rows == 10)
    }

    // MARK: - A handback leaves no stale mode

    /// A viewer turned off two modes the daemon last saw on. libghostty's
    /// formatter writes only modes that differ from their defaults, so the
    /// viewer's handback does not name them, and the writer's reset prelude
    /// does not either. The daemon's terminal is reset before the handback is
    /// parsed, so the next attach hands neither on.
    @Test func aHandbackLeavesNoModeTheViewerTurnedOff() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let on = "\(Self.esc)[?2048h\(Self.esc)[?2031h"
        await harness.reader.feedChildOutputForTesting(Data(on.utf8))
        _ = harness.readReplies()

        // The control: the daemon's snapshot carries both modes, so one that
        // came back without them after the handback is the reset's doing.
        let attach = await harness.reader.snapshotPreamble()
        #expect(Self.contains(attach, "\(Self.esc)[?2048h"), "the attach snapshot lacks mode 2048")
        #expect(Self.contains(attach, "\(Self.esc)[?2031h"), "the attach snapshot lacks mode 2031")

        // The viewer: painted from that snapshot, then the program turns both
        // modes off and writes a line there.
        let viewer = try GhosttyTerminal(
            cols: 80, rows: 24, scrollbackLines: 200, callbacks: GhosttyTerminalCallbacks())
        viewer.feed(Array(attach)[...])
        viewer.feed(Array("\(Self.esc)[?2048l\(Self.esc)[?2031lhello".utf8)[...])
        let handback = try GhosttySnapshotWriter.snapshot(of: viewer, maxScrollbackLines: 200)

        await harness.reader.ingest(preamble: handback)

        #expect(harness.readReplies().isEmpty, "the handback drew a reply")
        let next = await harness.reader.snapshotPreamble()
        #expect(!Self.contains(next, "\(Self.esc)[?2048h"), "the next attach hands on mode 2048")
        #expect(!Self.contains(next, "\(Self.esc)[?2031h"), "the next attach hands on mode 2031")
        let screen = await harness.reader.renderScreen()
        #expect(screen.contains("hello"), "the handback's screen did not land: \(screen.debugDescription)")
    }

    // MARK: - A take-back leaves no sequence open

    /// The attach does not wait for the child's sequence to end, so the
    /// daemon's parser is still inside a cut OSC 8 when the viewer hands back.
    /// The handback's parse starts by ending it: otherwise its first ESC would
    /// dispatch the cut link, every cell it restores would carry it, and the
    /// next attach would hand that link on.
    @Test func aHandbackAfterACutLinkLeavesNoLink() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data("\(Self.esc)]8;;https://exa".utf8))
        close(try await harness.reader.suspendDraining())

        // A viewer that finished the link and wrote a plain line.
        let viewer = try GhosttyTerminal(
            cols: 80, rows: 24, scrollbackLines: 200, callbacks: GhosttyTerminalCallbacks())
        viewer.feed(Array("hello".utf8)[...])
        let handback = try GhosttySnapshotWriter.snapshot(of: viewer, maxScrollbackLines: 200)
        #expect(!Self.contains(handback, "https://exa"))

        await harness.reader.ingest(preamble: handback)

        let next = await harness.reader.snapshotPreamble()
        #expect(!Self.contains(next, "https://exa"), "the next attach hands on the cut link")
        #expect(await harness.reader.renderScreen().contains("hello"))
    }

    /// The twin with no preamble, which a take-back from a viewer that may
    /// have read the pty takes (`viewerMayHaveRead`). The viewer finished the
    /// CSI the daemon's parser was left inside, so the child's next bytes are
    /// new output: `hX` prints, rather than `h` finishing `ESC[4h` and
    /// turning insert mode on.
    @Test func abandoningTheOpenSequenceReadsTheNextBytesAsNewOutput() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data("\(Self.esc)[4".utf8))
        close(try await harness.reader.suspendDraining())

        await harness.reader.abandonOpenSequence()

        await harness.reader.feedChildOutputForTesting(Data("hX".utf8))
        #expect(try await harness.firstLine() == "hX")
        // Insert mode off: a carriage return and a `Y` overwrite the `h`.
        await harness.reader.feedChildOutputForTesting(Data("\rY".utf8))
        #expect(try await harness.firstLine() == "YX", "insert mode is on")
    }

    /// The control: without the abandon, the same bytes finish the cut CSI,
    /// so the test above shows the abandon at work.
    @Test func withoutTheAbandonTheChildsBytesFinishTheSequence() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data("\(Self.esc)[4".utf8))

        await harness.reader.feedChildOutputForTesting(Data("hX".utf8))

        #expect(try await harness.firstLine() == "X")
    }

    /// The abandon is muted. Its CAN dispatches a cut query like any other
    /// way out of one, so a cut program-status probe (`ESC]7501;?`), which
    /// this emulator answers, would put an answer into the child's input
    /// that nobody asked for now.
    @Test func abandoningACutQuerySendsTheChildNothing() async throws {
        let harness = try Harness(answersProbes: true)
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data("\(Self.esc)]7501;?".utf8))
        close(try await harness.reader.suspendDraining())

        await harness.reader.abandonOpenSequence()

        let sent = harness.readReplies()
        #expect(sent.isEmpty, "abandoning a cut query wrote \(Self.describe(sent)) into the child's input")
    }

    /// The control: the same cut probe, ended by a CAN the child sends, is
    /// answered, so the test above shows the mute at work and not a query the
    /// CAN never dispatched.
    @Test func aProbeEndedByACANIsAnswered() async throws {
        let harness = try Harness(answersProbes: true)
        defer { harness.tearDown() }

        await harness.reader.feedChildOutputForTesting(Data("\(Self.esc)]7501;?\u{18}".utf8))

        #expect(!harness.readReplies().isEmpty, "a probe ended by a CAN drew no answer")
    }

    /// CAN alone dispatches a cut `ESC]8;;URL`, which would leave that link on
    /// the pen for everything the child writes next and hand it on at the next
    /// attach. The abandon closes the link after the CAN.
    @Test func abandoningACutLinkLeavesNoLink() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        await harness.reader.feedChildOutputForTesting(Data("\(Self.esc)]8;;https://exa".utf8))
        close(try await harness.reader.suspendDraining())

        await harness.reader.abandonOpenSequence()
        await harness.reader.feedChildOutputForTesting(Data("text".utf8))

        #expect(try await harness.firstLine() == "text")
        let next = await harness.reader.snapshotPreamble()
        #expect(!Self.contains(next, "https://exa"), "the text the child wrote next carries the cut link")
    }

    // MARK: - The snapshot waits only for what it cannot carry

    /// At ground and inside a short sequence the snapshot carries what it
    /// needs, so the reader need not wait. Inside a sequence longer than
    /// libghostty keeps the bytes of, it could only drop the rest, so the
    /// reader waits for the sequence to end.
    @Test func theSnapshotNeedsABoundaryOnlyInsideASequenceTooLongToCarry() {
        let emulator = Self.makeEmulator()
        #expect(emulator.kind == .ghostty)
        #expect(!emulator.snapshotNeedsSequenceBoundary, "at ground")

        emulator.feed(Array("\(Self.esc)]0;short".utf8)[...])
        #expect(!emulator.isAtSequenceBoundary, "the short title should still be open")
        #expect(!emulator.snapshotNeedsSequenceBoundary, "a short open sequence is carried, not waited for")

        emulator.feed(ArraySlice(repeating: UInt8(ascii: "t"), count: 70_000))
        #expect(emulator.snapshotNeedsSequenceBoundary, "a sequence past 64 KiB is waited for")

        emulator.feed(Array("\u{07}".utf8)[...])
        #expect(emulator.isAtSequenceBoundary)
        #expect(!emulator.snapshotNeedsSequenceBoundary, "the sequence ended")
    }

    // MARK: - A writer that fails

    /// When the writer throws, the attach still gets a preamble: the reset
    /// prelude alone, which leaves the viewer blank and reset until the
    /// child's next repaint. The error is logged, not thrown.
    @Test func aSnapshotTheWriterCannotWriteIsTheResetPreludeAlone() throws {
        let calls = CallCount()
        let emulator = try GhosttyHolderEmulator(
            ledger: Self.ledger(),
            sessionID: UUID(),
            columns: 40, rows: 8, scrollback: 100,
            programStatus: nil,
            reply: { _ in },
            writeSnapshot: { _, _ in
                calls.increment()
                throw WriterFailure()
            })
        emulator.feed(Array("on screen".utf8)[...])

        let preamble = emulator.snapshotPreamble(maxScrollbackLines: 100)

        #expect(calls.value == 1, "the snapshot did not go through the writer")
        #expect(preamble == Data(GhosttySnapshotWriter.resetPrelude))
    }

    /// The control: the production writer writes the screen after the same
    /// prelude, so the fallback's output is the prelude because the writer
    /// failed, not because every snapshot is.
    @Test func theProductionWriterWritesTheScreenAfterThePrelude() {
        let emulator = Self.makeEmulator()
        emulator.feed(Array("on screen".utf8)[...])

        let preamble = emulator.snapshotPreamble(maxScrollbackLines: 100)

        #expect(preamble.starts(with: GhosttySnapshotWriter.resetPrelude))
        #expect(Self.contains(preamble, "on screen"))
    }

    // MARK: - Support

    private struct WriterFailure: Error {}

    /// How many times a writer ran. Lock-guarded, because the writer is a
    /// `@Sendable` closure.
    private final class CallCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    /// What reached an emulator's reply sink, in order.
    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8] = []

        func append(_ reply: ArraySlice<UInt8>) { lock.withLock { bytes.append(contentsOf: reply) } }
        var all: [UInt8] { lock.withLock { bytes } }
    }

    private static func ledger() -> HolderEmulatorLedger {
        HolderEmulatorLedger(
            sessionID: UUID(), observedChildFromStart: true, monotonicNow: { ContinuousClock.now })
    }

    /// The libghostty emulator through the production factory, with no tap.
    private static func makeEmulator(
        reply: @escaping @Sendable (ArraySlice<UInt8>) -> Void = { _ in }
    ) -> any HolderEmulator {
        HolderEmulatorKind.ghostty.makeEmulator(
            sessionID: UUID(), columns: 40, rows: 8, scrollback: 100,
            observedChildFromStart: true, monotonicNow: { ContinuousClock.now },
            programStatus: nil, reply: reply)
    }

    private static func contains(_ data: Data, _ text: String) -> Bool {
        data.range(of: Data(text.utf8)) != nil
    }

    private static func describe(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self).debugDescription
    }

    /// A libghostty `HolderReader` over one end of a socketpair, never started.
    private struct Harness {
        static let rows = 24

        let reader: HolderReader
        private let ours: Int32

        /// The viewport's first row. The screen read asks for every row of the
        /// grid: it keeps the newest lines it is asked for and drops blank
        /// ones, so asking for fewer would start below row 0.
        func firstLine() async throws -> String? {
            try await reader.screen(maxLines: Self.rows).lines.first
        }

        /// `answersProbes` gives the reader a program-status tap, without which
        /// it answers no program-status probe.
        init(answersProbes: Bool = false) throws {
            var pair: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            ours = pair[1]
            let flags = fcntl(ours, F_GETFL, 0)
            _ = fcntl(ours, F_SETFL, flags | O_NONBLOCK)
            // The reader owns `pair[0]` and closes it in its `deinit`.
            reader = HolderReader(
                sessionID: UUID(),
                ptyFD: pair[0],
                columns: 80,
                rows: Self.rows,
                scrollbackLines: 200,
                programStatus: answersProbes ? HolderProgramStatusTap(deliver: { _ in }) : nil,
                emulator: .ghostty,
                observedChildFromStart: true)
            try #require(reader.emulatorKind == .ghostty, "libghostty could not make a terminal")
        }

        /// Everything written back to the "child" so far. Replies are written
        /// before the call that drew them returns; `EAGAIN` means none.
        func readReplies() -> [UInt8] {
            var out: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(ours, raw.baseAddress, raw.count)
                }
                if count > 0 {
                    out.append(contentsOf: buffer[0..<count])
                    continue
                }
                if count < 0, errno == EINTR { continue }
                return out
            }
        }

        /// Closes this side only; the reader's `deinit` closes its own.
        func tearDown() {
            close(ours)
        }
    }
}
