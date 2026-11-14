import Foundation
import os
import TBDGhosttyCore
// Scoped, as `SwiftTermHolderEmulator` does: only the screen model and the
// protocol's constants are needed from TBDShared.
import struct TBDShared.TerminalModeReading
import struct TBDShared.TerminalScreen
import enum TBDShared.ProgramStatusProtocol

/// The libghostty-vt implementation of `HolderEmulator`, chosen by the
/// `ghostty_daemon_emulator_enabled` flag when a reader is built.
///
/// Design: `docs/specs/2026-11-13-swiftterm-retirement-design.md`, stream C.
/// How it meets each of the protocol's rules:
///
/// - **One lock: the terminal's own.** `GhosttyTerminal` keeps a private,
///   non-recursive lock and takes it in every call, so nothing here takes a
///   lock of its own. A feed stamps the ledger through
///   `GhosttyTerminal.feed(_:muted:resetFirst:underLock:)`, whose closure runs
///   in the parse's hold; every read is one `withLocked` hold, which is also where
///   the ledger builds a screen or a mode reading. `GhosttySnapshotWriter`
///   takes the lock itself, so `snapshotPreamble` calls it outside any hold.
/// - **Replies and reports.** libghostty collects what a parse produces and
///   delivers it after the lock drops, still on the feeding thread and before
///   `feed` returns. Replies reach the reply sink with libghostty's OSC 7501
///   probe answer swapped for TBD's (`ProgramStatusProbeAnswer`), and each
///   swapped answer is recorded on the ledger, since libghostty has no event
///   for a probe it saw. Reports reach the tap rebuilt in the wire form TBD
///   parses (`ProgramStatusPayloadBuilder`). Without a tap no `programStatus`
///   callback is set, and libghostty then answers no probe, as the SwiftTerm
///   emulator answers none without one.
/// - **Device identity.** DA1, DA2 and XTVERSION are answered with the frozen
///   `TerminalDeviceIdentity` bytes, the ones the SwiftTerm emulator answers
///   with.
/// - **A handback preamble lands in a cleared, muted terminal.**
///   `feedPreamble` ends any sequence the parser was left inside, resets the
///   terminal and then parses the preamble, all muted, in the same hold as
///   the stamp (`GhosttyTerminal.feed(_:muted:resetFirst:underLock:)`): every
///   reply, report and query the preamble provokes is dropped, and every mode
///   goes back to its default first. The reset is what clears a mode the
///   preamble does not name: libghostty's formatter writes only modes that
///   differ from their defaults, and the writer's reset prelude names a fixed
///   list, so a mode outside it (2048, 2031 and others) would otherwise stay
///   as the daemon last saw it and go out in the next attach. The reset
///   leaves libghostty's stream parser alone, and the attach does not wait for
///   the child to reach a boundary, so the parser can still be inside the
///   child's sequence; the CAN before the reset is what ends it. A probe in a
///   preamble is dropped inside libghostty, unseen, and leaves no record,
///   where the SwiftTerm emulator records it as ignored.
/// - **A take-back with no preamble abandons the open sequence when a viewer
///   may have read the pty** (`viewerMayHaveRead`). That viewer finished
///   whatever sequence the attach left open, so the child's next bytes are
///   not its tail. `abandonOpenSequence` feeds a CAN and an OSC 8 close,
///   muted, in one hold, before the reader resumes. Where no viewer read the
///   pty the sequence is kept, for the child's next bytes to finish. The
///   cases the daemon cannot tell apart, and why they fall as they do, are
///   in `HolderEmulator.abandonOpenSequence`.
/// - **A resize sends the child nothing.** Every resize is muted
///   (`GhosttyTerminal.resize(cols:rows:muted:)`), so a child that asked for
///   in-band size reports with mode 2048 gets none from the daemon, as it got
///   none from the SwiftTerm emulator, which has no mode 2048. While a viewer
///   holds the pty the viewer answers for the terminal, and the daemon must
///   not write into the child's input; while the daemon holds it, the child
///   learns the size from `SIGWINCH`.
/// - **No reading feeds the terminal.** Modes are read with `mode(_:ansi:)`
///   and the snapshot writer feeds only an in-process clone, so the snapshot
///   needs no wait for the child's sequence to end: a sequence left open is
///   carried at the end of the snapshot for the viewer to finish. The one
///   exception is a sequence longer than libghostty keeps the bytes of, which
///   the writer can only end with an opener that drops the rest:
///   `snapshotNeedsSequenceBoundary` is true for exactly that case, so the
///   reader waits only for an over-long sequence to end, where under the
///   SwiftTerm emulator it waits for any.
final class GhosttyHolderEmulator: HolderEmulator {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holder")

    /// Builds the libghostty terminal: columns, rows, scrollback lines and the
    /// callbacks. A seam, so a test can make construction fail and reach
    /// `HolderEmulatorKind`'s fallback; production passes `makeTerminal`.
    typealias TerminalFactory = @Sendable (
        _ columns: Int, _ rows: Int, _ scrollback: Int, _ callbacks: GhosttyTerminalCallbacks
    ) throws -> TBDGhosttyCore.GhosttyTerminal

    /// The production factory: `GhosttyTerminal.init`.
    static let makeTerminal: TerminalFactory = { columns, rows, scrollback, callbacks in
        try TBDGhosttyCore.GhosttyTerminal(
            cols: columns, rows: rows, scrollbackLines: scrollback, callbacks: callbacks)
    }

    /// Writes the attach snapshot: the terminal and the most scrollback lines
    /// to keep. A seam, so a test can make the writer fail and reach
    /// `snapshotPreamble`'s fallback; production passes `writeSnapshot`.
    typealias SnapshotWriter = @Sendable (
        _ terminal: TBDGhosttyCore.GhosttyTerminal, _ maxScrollbackLines: Int
    ) throws -> Data

    /// The production writer: `GhosttySnapshotWriter.snapshot`.
    static let writeSnapshot: SnapshotWriter = { terminal, maxScrollbackLines in
        try GhosttySnapshotWriter.snapshot(of: terminal, maxScrollbackLines: maxScrollbackLines)
    }

    private let terminal: TBDGhosttyCore.GhosttyTerminal
    /// Its one mutable field is guarded by the terminal's lock; see the ledger.
    private let ledger: HolderEmulatorLedger
    /// Names the session in the one line this type logs.
    private let sessionID: UUID
    private let snapshotWriter: SnapshotWriter

    let kind: HolderEmulatorKind = .ghostty

    /// Throws what the factory throws, when libghostty cannot make the
    /// terminal. `HolderEmulatorKind.makeEmulator` then builds the SwiftTerm
    /// emulator instead.
    init(
        ledger: HolderEmulatorLedger,
        sessionID: UUID,
        columns: Int, rows: Int, scrollback: Int,
        programStatus: HolderProgramStatusTap?,
        reply: @escaping @Sendable (ArraySlice<UInt8>) -> Void,
        makeTerminal: TerminalFactory = GhosttyHolderEmulator.makeTerminal,
        writeSnapshot: @escaping SnapshotWriter = GhosttyHolderEmulator.writeSnapshot
    ) throws {
        self.ledger = ledger
        self.sessionID = sessionID
        self.snapshotWriter = writeSnapshot
        self.terminal = try makeTerminal(
            max(1, columns), max(1, rows), max(0, scrollback),
            GhosttyHolderEmulator.callbacks(ledger: ledger, programStatus: programStatus, reply: reply))
    }

    /// The terminal's callbacks. Static, so no callback can capture the
    /// emulator; each captures only the ledger, the tap and the reply sink.
    ///
    /// `writePty` runs after the terminal's lock drops, but every other call
    /// that produced a reply waits for it, the drain thread's next `feed`
    /// included. The reply sink is the reader's bounded, best-effort pty write,
    /// the same sink the SwiftTerm emulator writes to from inside its parse, so
    /// a child that is not reading its input costs at most that write's budget
    /// before the reply is dropped and logged.
    private static func callbacks(
        ledger: HolderEmulatorLedger,
        programStatus: HolderProgramStatusTap?,
        reply: @escaping @Sendable (ArraySlice<UInt8>) -> Void
    ) -> GhosttyTerminalCallbacks {
        let probeReply: [UInt8]? = programStatus == nil ? nil : Array(ProgramStatusProtocol.probeReply.utf8)
        var reportProgramStatus: (@Sendable (GhosttyTerminalCallbacks.ProgramStatus) -> Void)?
        if let programStatus {
            reportProgramStatus = { status in
                programStatus.deliver(ProgramStatusPayloadBuilder.payload(for: status))
            }
        }
        return GhosttyTerminalCallbacks(
            writePty: { bytes in
                // In parse order: the answer rides with the replies around it,
                // as the SwiftTerm emulator writes its answer inside the parse.
                let swapped = ProgramStatusProbeAnswer.swappingLibghosttyAnswers(in: bytes, with: probeReply)
                if probeReply != nil {
                    for _ in 0..<swapped.answers { ledger.recordProbeAnswered() }
                }
                guard !swapped.bytes.isEmpty else { return }
                reply(swapped.bytes[...])
            },
            programStatus: reportProgramStatus,
            deviceAttributes: { TerminalDeviceIdentity.deviceAttributes },
            xtversion: { TerminalDeviceIdentity.xtversion })
    }

    /// Bytes from outside — the drain loop's reads, the quiesce remainder.
    /// The ledger's stamp runs in the parse's own hold.
    func feed(_ bytes: ArraySlice<UInt8>) {
        terminal.feed(bytes, underLock: { ledger.stampArrival() })
    }

    /// `feed`, for a handback preamble: a CAN, a full reset and then the
    /// parse, all muted, in the same hold as the stamp. The CAN ends any
    /// sequence the parser was left inside and returns it to ground, which the
    /// reset does not. Whether libghostty dispatches a cut OSC on the CAN is
    /// not relied on: the reset after it puts the screen model back to its
    /// initial state either way. Nothing the preamble provokes reaches the
    /// child or the tap, and no mode the preamble leaves unnamed survives from
    /// before it.
    func feedPreamble(_ bytes: ArraySlice<UInt8>) {
        terminal.feed(bytes, muted: true, resetFirst: true, underLock: { ledger.stampArrival() })
    }

    /// A CAN, which ends any open sequence and returns the parser to ground,
    /// then an OSC 8 close. libghostty drops a cut OSC 7501 probe on the CAN
    /// rather than answering it. Whether it dispatches any other cut OSC is
    /// not relied on: the CAN is muted, and the close ends the link a
    /// dispatched `ESC]8;;URL` would leave on the pen for every cell the child
    /// writes next. Muted, so nothing either could provoke reaches the child or
    /// the tap, and not stamped: no byte came from the child. A cut UTF-8
    /// character first prints as U+FFFD.
    func abandonOpenSequence() {
        terminal.feed(Self.abandonSequence[...], muted: true, underLock: {})
    }

    /// CAN, then `ESC ] 8 ; ; ESC \`.
    private static let abandonSequence: [UInt8] = [0x18] + Array("\u{1b}]8;;\u{1b}\\".utf8)

    /// Muted, on every call, so libghostty's in-band size report (mode 2048)
    /// never reaches the child from the daemon, as none ever did from the
    /// SwiftTerm emulator. A viewer that holds the pty answers for the
    /// terminal, and the daemon must not write into the child's input then.
    func resize(columns: Int, rows: Int) {
        terminal.resize(cols: max(1, columns), rows: max(1, rows), muted: true)
    }

    /// True only while the child is inside a sequence too long for the
    /// snapshot to carry (`GhosttySnapshotWriter.endsInOverlongSink`). Any
    /// shorter open sequence is carried at the end of the snapshot, so the
    /// reader need not wait for it.
    var snapshotNeedsSequenceBoundary: Bool {
        terminal.withLocked { GhosttySnapshotWriter.endsInOverlongSink($0) }
    }

    var size: (columns: Int, rows: Int) {
        terminal.withLocked { ($0.cols, $0.rows) }
    }

    var isAtSequenceBoundary: Bool {
        terminal.withLocked { $0.isAtSequenceBoundary }
    }

    /// The viewport as text, one line per row, trailing blank rows dropped:
    /// `GhosttyTerminalState.viewportLines()`.
    func renderScreen() -> String {
        terminal.withLocked { $0.viewportLines().joined(separator: "\n") }
    }

    /// The typed screen from one `withLocked` hold: the projection the app's
    /// libghostty viewer answers screen pulls with, the cursor's visibility as
    /// the terminal holds it (DECTCEM), and the ledger's facts. Stamps nothing.
    func screen(maxLines: Int, source: TerminalScreen.Source) throws -> TerminalScreen {
        try terminal.withLocked { state in
            try ledger.screen(
                GhosttyScreenProjection.project(state, maxLines: maxLines),
                cursorVisible: state.isCursorVisible,
                source: source)
        }
    }

    /// The modes, their provenance and their age. The projection with no
    /// lines reads only the modes, the cursor and the size.
    func modeReading(source: TerminalScreen.Source) -> TerminalModeReading {
        terminal.withLocked { state in
            ledger.modeReading(GhosttyScreenProjection.project(state, maxLines: 0).modes, source: source)
        }
    }

    func styledCapture(maxScrollbackLines: Int) -> String {
        terminal.withLocked { state in
            GhosttyScreenProjection.styledCapture(state, maxScrollbackLines: maxScrollbackLines)
        }
    }

    /// The handback writer's bytes, which rebuild the terminal in a libghostty
    /// or a SwiftTerm viewer. The writer takes the terminal's lock itself and
    /// only reads the live terminal, so nothing reaches the child and the
    /// ledger is not stamped.
    ///
    /// When the writer fails, the attach still goes ahead: the error is logged
    /// and the viewer gets the writer's reset prelude alone, which every
    /// snapshot opens with. The viewer starts as a blank, reset terminal, and
    /// the child's next repaint fills it.
    func snapshotPreamble(maxScrollbackLines: Int) -> Data {
        do {
            return try snapshotWriter(terminal, maxScrollbackLines)
        } catch {
            Self.logger.error(
                """
                session \(self.sessionID.uuidString, privacy: .public): the libghostty snapshot \
                failed, so the attaching viewer gets a blank, reset screen: \
                \(String(describing: error), privacy: .public)
                """)
            return Data(GhosttySnapshotWriter.resetPrelude)
        }
    }
}
