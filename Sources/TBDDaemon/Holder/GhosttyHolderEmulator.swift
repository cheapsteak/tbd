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
///   `GhosttyTerminal.feed(_:muted:underLock:)`, whose closure runs in the
///   parse's hold; every read is one `withLocked` hold, which is also where
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
/// - **A handback preamble is muted.** `feedPreamble` mutes exactly its own
///   parse, inside the same hold as the stamp: every reply, report and query
///   the preamble provokes is dropped. A probe in a preamble is therefore
///   dropped inside libghostty, unseen, and leaves no record, where the
///   SwiftTerm emulator records it as ignored.
/// - **No reading feeds the terminal.** Modes are read with `mode(_:ansi:)`
///   and the snapshot writer feeds only an in-process clone, so the snapshot
///   needs no wait for the child's sequence to end: a sequence left open is
///   carried at the end of the snapshot for the viewer to finish
///   (`snapshotNeedsSequenceBoundary` is false).
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

    private let terminal: TBDGhosttyCore.GhosttyTerminal
    /// Its one mutable field is guarded by the terminal's lock; see the ledger.
    private let ledger: HolderEmulatorLedger
    /// Names the session in the one line this type logs.
    private let sessionID: UUID

    let kind: HolderEmulatorKind = .ghostty
    let snapshotNeedsSequenceBoundary = false

    /// Throws what the factory throws, when libghostty cannot make the
    /// terminal. `HolderEmulatorKind.makeEmulator` then builds the SwiftTerm
    /// emulator instead.
    init(
        ledger: HolderEmulatorLedger,
        sessionID: UUID,
        columns: Int, rows: Int, scrollback: Int,
        programStatus: HolderProgramStatusTap?,
        reply: @escaping @Sendable (ArraySlice<UInt8>) -> Void,
        makeTerminal: TerminalFactory = GhosttyHolderEmulator.makeTerminal
    ) throws {
        self.ledger = ledger
        self.sessionID = sessionID
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

    /// `feed`, for a handback preamble, muted for exactly this parse inside
    /// the same hold as the stamp: nothing the preamble provokes reaches the
    /// child or the tap.
    func feedPreamble(_ bytes: ArraySlice<UInt8>) {
        terminal.feed(bytes, muted: true, underLock: { ledger.stampArrival() })
    }

    func resize(columns: Int, rows: Int) {
        terminal.resize(cols: max(1, columns), rows: max(1, rows))
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
            return try GhosttySnapshotWriter.snapshot(of: terminal, maxScrollbackLines: maxScrollbackLines)
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
