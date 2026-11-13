import Foundation
import SwiftTerm
// Scoped, not a whole-module import: `TBDShared.Terminal` is the DB row model
// and `SwiftTerm.Terminal` is the emulator, and this file is full of the
// second. Naming the types it needs keeps every bare `Terminal` here meaning
// the emulator.
import struct TBDShared.TerminalModeReading
import struct TBDShared.TerminalScreen
import enum TBDShared.ProgramStatusParser
import enum TBDShared.ProgramStatusProtocol
import TBDTerminalSerialization

/// The headless terminal, and the lock discipline it demands.
///
/// `Terminal` is not `Sendable`, carries no `@MainActor`, and does not lock
/// itself: it publishes `terminalLock` and expects every feed and every read of
/// its state to hold it. The drain thread and a rendering caller are genuinely
/// concurrent, so this box exists to make that impossible to get wrong — no
/// path reaches the `Terminal` except through a method here, and every method
/// here takes the lock. Getting it wrong garbles output rather than crashing,
/// which is why it must be structural instead of remembered.
///
/// The SwiftTerm implementation of `HolderEmulator`. The facts no grid
/// holds — when it began, when it last took in bytes, whether it watched its
/// child from birth — live in its `HolderEmulatorLedger`, under `terminalLock`
/// like everything else here.
final class SwiftTermHolderEmulator: HolderEmulator, @unchecked Sendable {
    private let terminal: Terminal
    /// Held strongly: `Terminal.tdel` is `weak`, so a delegate nobody else
    /// retains is deallocated and the child's terminal queries go unanswered.
    private let delegate: ReplyForwardingDelegate
    /// Its one mutable field is guarded by `terminalLock`; see the ledger.
    private let ledger: HolderEmulatorLedger
    /// True only while `feedPreamble` is parsing a handback preamble, so the
    /// OSC 7501 handler can tell a replay from the child speaking. Read and
    /// written only under `terminalLock` — the handler runs inside the parse,
    /// which `feedPreamble` holds that lock around — like everything else here.
    private var ingestingPreamble = false

    let kind: HolderEmulatorKind = .swiftTerm
    /// The snapshot's `DECRQM` queries and alt-screen toggle feed the live
    /// terminal; see `snapshotPreamble`.
    let snapshotNeedsSequenceBoundary = true

    init(
        ledger: HolderEmulatorLedger,
        columns: Int, rows: Int, scrollback: Int,
        programStatus: HolderProgramStatusTap?,
        reply: @escaping @Sendable (ArraySlice<UInt8>) -> Void
    ) {
        let delegate = ReplyForwardingDelegate(reply: reply)
        self.delegate = delegate
        self.ledger = ledger
        self.terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(
                cols: max(1, columns),
                rows: max(1, rows),
                scrollback: max(0, scrollback)))

        // Program Status Protocol (OSC 7501). A registered handler rather than
        // `observeOscEvents`, because the probe reply must be written *inside*
        // the parse: Claude Code queues the probe ahead of its DA1 query and
        // settles the protocol off if DA1's answer arrives first, and SwiftTerm
        // answers DA1 synchronously in the same parse. The handler runs under
        // `terminalLock`, so it must not block or re-enter the emulator: the
        // reply is one best-effort pty write through the delegate, the same
        // path DA1's reply takes, and a report is copied out of the borrowed
        // slice and handed to the tap, whose `deliver` only enqueues. Each
        // probe, answered or not, is recorded with one log call.
        //
        // During a handback preamble nothing is answered and nothing is
        // delivered; a probe there is recorded all the same, because a replay
        // that carried one would otherwise leave no trace of why it went
        // unanswered.
        //
        // Weak `self`: the terminal owns the handler and `self` owns the
        // terminal, so a strong capture would be a cycle.
        if let programStatus {
            terminal.registerOscHandler(code: ProgramStatusProtocol.oscCode) { [weak self] data in
                guard let self else { return }
                let isProbe = ProgramStatusParser.isProbe(data)
                if self.ingestingPreamble {
                    if isProbe { self.ledger.recordProbeIgnoredInPreamble() }
                    return
                }
                if isProbe {
                    self.terminal.sendResponse(text: ProgramStatusProtocol.probeReply)
                    self.ledger.recordProbeAnswered()
                    return
                }
                programStatus.deliver([UInt8](data))
            }
        }
    }

    /// Bytes from outside — the drain loop's reads, the quiesce remainder.
    /// The ledger's stamp and the parse share one `terminalLock` hold; the
    /// stamp moves no provenance (see `HolderEmulatorLedger.stampArrival`).
    func feed(_ bytes: ArraySlice<UInt8>) {
        terminal.terminalLock.withLock {
            ledger.stampArrival()
            terminal.feed(buffer: bytes)
        }
    }

    /// `feed`, for a handback preamble: identical, except that the OSC 7501
    /// handler stays silent for the duration. A preamble is a serialized screen
    /// and should never carry OSC 7501; the flag makes that structural rather
    /// than assumed, so a replay can neither answer a probe nor deliver a
    /// report. Set and cleared inside the same `terminalLock` hold the parse
    /// runs under.
    ///
    /// Only OSC 7501 is silenced: any other reply the preamble provoked would
    /// reach the child through the delegate exactly as `feed`'s do. A
    /// preamble restates a screen rather than asking the terminal anything.
    func feedPreamble(_ bytes: ArraySlice<UInt8>) {
        terminal.terminalLock.withLock {
            ledger.stampArrival()
            ingestingPreamble = true
            defer { ingestingPreamble = false }
            terminal.feed(buffer: bytes)
        }
    }

    /// Whether the child's output so far ends between sequences, so bytes of
    /// the daemon's own — `snapshotPreamble`'s mode queries and alt-screen
    /// toggle — can be fed without cutting one of the child's short.
    var isAtSequenceBoundary: Bool {
        terminal.terminalLock.withLock { terminal.isAtSequenceBoundary }
    }

    /// The viewport as text, through the same projection `screen` uses — so
    /// the diagnostic render and the typed screen cannot disagree about what a
    /// cell projects to or where the trailing blanks stop.
    func renderScreen() -> String {
        terminal.terminalLock.withLock {
            TerminalScreenProjection.viewportLines(of: terminal).joined(separator: "\n")
        }
    }

    /// The typed screen, taken as **one observation** under a single
    /// `terminalLock` hold.
    ///
    /// The lock is what makes lines, cursor, modes and size one fact rather
    /// than four. Taken separately, a drain-thread feed between two of them
    /// would produce a screen that never existed — modes from after a mode
    /// change beside lines from before it, which is exactly the pairing the
    /// input path must not compose against.
    ///
    /// **The walk itself is not here.** Lines, `viewportStart`, the cursor's
    /// position, the size and the three modes come from
    /// `TerminalScreenProjection`, the one projection both stores share, so a
    /// viewer's answer to a screen pull and this emulator's answer differ in
    /// nothing but the facts the ledger adds — which is the screen contract's
    /// "the two stores project identically by construction", held structurally
    /// rather than by two implementations agreeing. What stays here is the one
    /// fact a grid cannot tell and this emulator must supply: whether the
    /// cursor is visible. Which store answered, how stale it is, whether it
    /// watched the child from birth and the construction that enforces the
    /// whitelist are the ledger's.
    ///
    /// **Nothing in the projection feeds the terminal**, which is why the cursor's
    /// visibility is read from a flag the delegate keeps rather than probed
    /// with a `DECRQM` 25 query. `Terminal.cursorHidden` is not public, but
    /// SwiftTerm calls `showCursor`/`hideCursor` on its delegate every time the
    /// child sets or resets `DECTCEM`, so the fact arrives without asking.
    ///
    /// A probe here would be fed into a live parser: this method runs on every
    /// `terminal.output`, including against a reader whose drain thread is
    /// mid-stream, and SwiftTerm's parser carries its state across `feed` calls
    /// while an `ESC` in any state aborts whatever sequence is pending. A read
    /// whose last chunk ended mid-sequence — routine when a TUI repaint exceeds
    /// the pty buffer — would therefore truncate the child's sequence, print
    /// its remainder into the screen model as literal text, and swallow the
    /// reply to a query the child was in the middle of asking. `snapshotPreamble`
    /// still probes, once per attach, after the quiesce has waited for the
    /// child's output to reach a sequence boundary.
    ///
    /// It does not stamp the ledger either — a daemon reading its own
    /// emulator must not make a stale screen look fresh.
    func screen(maxLines: Int, source: TerminalScreen.Source) throws -> TerminalScreen {
        try terminal.terminalLock.withLock {
            try ledger.screen(
                TerminalScreenProjection.project(terminal, maxLines: maxLines),
                cursorVisible: delegate.cursorVisible,
                source: source)
        }
    }

    /// The modes, their provenance and their age, without the line walk.
    func modeReading(source: TerminalScreen.Source) -> TerminalModeReading {
        terminal.terminalLock.withLock {
            ledger.modeReading(TerminalScreenProjection.modes(of: terminal), source: source)
        }
    }

    /// Serializes the whole terminal — modes, scrollback, viewport, cursor —
    /// into bytes that reconstruct it elsewhere.
    ///
    /// Everything happens inside one `terminalLock`, and only `Data` comes out.
    /// That is not tidiness: `TerminalSnapshotWriter` reads the buffer, *feeds*
    /// the terminal (the alt-screen toggle, and a DECRQM query per mode it
    /// cannot read from a public property) and feeds it again to put the alt
    /// screen back, so a drain-thread feed interleaved with any of that would
    /// garble both. It also means the lock is held across the whole walk, which
    /// is the longest this lock is ever held — bounded by the retained
    /// scrollback, and paid once per attach.
    ///
    /// **The replies those queries provoke must not reach the child.** They are
    /// answers to questions nobody asked: a program reading its stdin would
    /// receive `\u{1b}[?7;1$y` as if somebody had typed it. So the delegate is
    /// switched from forwarding to collecting for the duration, which is also
    /// how `DelegateModeReader` reads the answers at all. This is the
    /// daemon-side twin of the app's quiet ingest, in the opposite direction.
    ///
    /// Those queries feed the `Terminal` directly rather than through `feed`,
    /// so they do not stamp the ledger — an attach must not make a session
    /// that has been silent for an hour report an age of zero.
    ///
    /// **Call it between sequences.** The first `ESC` those feeds carry ends
    /// whatever sequence the child is part-way through, and its remainder
    /// then prints as text here and in the viewer. The attach path calls this
    /// after `HolderReader.suspendDraining`, which waits for
    /// `isAtSequenceBoundary`.
    func snapshotPreamble(maxScrollbackLines: Int) -> Data {
        terminal.terminalLock.withLock {
            let reader = DelegateModeReader(terminal: terminal, delegate: delegate)
            delegate.beginCollectingReplies()
            defer { delegate.endCollectingReplies() }
            return TerminalSnapshotWriter.snapshot(
                of: terminal, reply: reader, maxScrollbackLines: maxScrollbackLines)
        }
    }

    /// The active buffer's retained scrollback plus viewport as styled lines,
    /// in the capture form of the cell walk: `snapshotPreamble`'s history walk
    /// without anything around it, and with trailing blank rows dropped,
    /// because a capture is printed rather than replayed.
    ///
    /// A pure read: no mode query is fed and no alt-screen toggle runs, so
    /// nothing reaches the child and the model is left exactly as it was. On
    /// an alt screen the active buffer has no scrollback of its own, so this is
    /// the alt viewport alone — what `capture-pane` answers for a tmux pane in
    /// the same state.
    func styledCapture(maxScrollbackLines: Int) -> String {
        terminal.terminalLock.withLock {
            TerminalCellWalk.styledCapture(
                of: terminal, maxScrollbackLines: maxScrollbackLines)
        }
    }

    func resize(columns: Int, rows: Int) {
        terminal.terminalLock.withLock {
            terminal.resize(cols: columns, rows: rows)
        }
    }

    /// The grid's dimensions, read under the same lock as everything else here.
    var size: (columns: Int, rows: Int) {
        terminal.terminalLock.withLock { (terminal.cols, terminal.rows) }
    }
}

/// The emulator's delegate: the terminal's outbound wire, plus the one piece of
/// its state that is not readable from a public property.
///
/// `send` is the required hook — bytes the terminal itself wants to send back:
/// device-status replies, cursor-position reports, the answers to `DECRQM`.
/// `TerminalDelegate` declares 31 methods and a public extension defaults 30 of
/// them; `send` is the one that has no default, and routing it anywhere but the
/// child would turn every terminal query into a hang.
///
/// `showCursor`/`hideCursor` are overridden from that default set, because
/// being *told* about `DECTCEM` is the only way to know the cursor's visibility
/// without asking the terminal — and asking is what
/// `SwiftTermHolderEmulator.screen` must never do.
private final class ReplyForwardingDelegate: TerminalDelegate {
    private let reply: @Sendable (ArraySlice<UInt8>) -> Void
    /// While true, replies are kept here instead of being written to the pty.
    ///
    /// Raised only for the duration of a snapshot, and only from a caller
    /// already holding `terminalLock` — which is also the lock every `send`
    /// arrives under, since the terminal calls its delegate from inside a parse.
    /// So the flag needs no lock of its own; the terminal's is doing the work.
    private var collecting = false
    private var collected: [UInt8] = []

    /// Whether the child's cursor is currently visible — `DECTCEM`, mode 25.
    ///
    /// `Terminal.cursorHidden` is not public, and the emulator must not ask for
    /// it: a `DECRQM` probe fed into a parser that is mid-sequence aborts the
    /// child's sequence (see `SwiftTermHolderEmulator.screen`). So the fact is
    /// taken where SwiftTerm volunteers it instead — `showCursor`/`hideCursor`
    /// are called on the delegate whenever the child sets or resets the mode.
    /// Starts `true`, the mode's own default: a terminal shows its cursor until
    /// a program hides it.
    ///
    /// Like `collecting`, this needs no lock of its own. The terminal calls its
    /// delegate from inside a parse, which always runs under `terminalLock`,
    /// and `SwiftTermHolderEmulator.screen` reads the flag under that same
    /// lock.
    ///
    /// **Both resets leave it true, by different mechanisms**, and each is
    /// worth stating because a reset that moved the cursor silently would leave
    /// this reading wrong for the rest of the session. A soft reset (`DECSTR`,
    /// `CSI ! p`, `Terminal.cmdSoftReset`) shows the cursor and calls
    /// `showCursor` on the delegate as its last act, so the flag follows it out
    /// of hidden. A full reset (`RIS`, `ESC c`) makes no cursor call at all and
    /// needs none: `resetToInitialState` saves `cursorHidden` around the
    /// `setup(isReset:)` that clears it and restores it afterwards, so the
    /// terminal ends where the flag already is.
    ///
    /// What a silent change *would* cost is why both are pinned in
    /// `HolderScreenContractTests` rather than assumed. A divergence here does
    /// not self-correct on a bare `DECSET 25`: `Terminal.showCursor` returns
    /// early when `cursorHidden` is already false, so the delegate call the
    /// flag needs never happens until something sets it true again, and only a
    /// hide-then-show pair puts it back.
    private(set) var cursorVisible = true

    init(reply: @escaping @Sendable (ArraySlice<UInt8>) -> Void) {
        self.reply = reply
    }

    func showCursor(source: Terminal) {
        cursorVisible = true
    }

    func hideCursor(source: Terminal) {
        cursorVisible = false
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard collecting else {
            reply(data)
            return
        }
        collected.append(contentsOf: data)
    }

    func beginCollectingReplies() {
        collecting = true
        collected.removeAll(keepingCapacity: true)
    }

    func endCollectingReplies() {
        collecting = false
        collected.removeAll(keepingCapacity: false)
    }

    /// Drops whatever has been collected and hands back what arrives next.
    /// Used to read one query's answer without the previous one's bytes in it.
    ///
    /// Bytes that are not valid UTF-8 are no answer at all rather than a
    /// mangled one: every reply this reads is a `CSI` sequence of digits and
    /// punctuation, so anything undecodable is not the reply that was asked
    /// for, and an empty string is what the caller reads as "the terminal did
    /// not answer".
    func takeCollected(after query: (Terminal) -> Void, from terminal: Terminal) -> String {
        collected.removeAll(keepingCapacity: true)
        query(terminal)
        return String(bytes: collected, encoding: .utf8) ?? ""
    }
}

/// Reads a terminal's mode state by asking the terminal itself.
///
/// `TerminalModeCapture` needs `DECRQM` answers for every mode SwiftTerm keeps
/// private, and the only way to get one is to feed the query and catch what the
/// terminal tries to send back. That is what makes this a *collecting* delegate
/// rather than a suppressing one: the same switch that keeps the answers away
/// from the child is what makes them readable here.
///
/// The caller must hold `terminal.terminalLock` — the lock every parse, and so
/// every `send`, arrives under — and must have put the delegate in collecting
/// mode with `beginCollectingReplies`, or the answers go to the child and this
/// reads nothing. `SwiftTermHolderEmulator.snapshotPreamble` is the only
/// construction site, and it does both. Deliberately only that one: a probe is
/// safe there because the attach's quiesce first waits for the child's output
/// to reach a sequence boundary, and unsafe on the per-`terminal.output` path,
/// where nothing waits and it would abort a sequence the child is mid-way
/// through sending.
private struct DelegateModeReader: ModeReplyReader {
    let terminal: Terminal
    let delegate: ReplyForwardingDelegate

    func requestMode(_ mode: Int, decPrivate: Bool) -> Int? {
        let prefix = decPrivate ? "?" : ""
        let reply = delegate.takeCollected(
            after: { $0.feed(text: "\u{1b}[\(prefix)\(mode)$p") }, from: terminal)
        // `CSI ? Pd ; Ps $y`, where `Ps` is 1 set, 2 reset, 4 permanently reset
        // and 0 unknown. Located rather than matched whole, because a terminal
        // may answer a query the caller did not ask for on the same wire — but
        // anchored on the CSI introducer, so that "mode 7" cannot be found
        // inside the answer for mode 1007.
        guard let head = reply.range(of: "\u{1b}[\(prefix)\(mode);"),
              let tail = reply[head.upperBound...].range(of: "$y")
        else { return nil }
        return Int(reply[head.upperBound..<tail.lowerBound])
    }
}
