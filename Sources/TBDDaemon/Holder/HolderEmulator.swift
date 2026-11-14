import Foundation
import TBDShared
import os

/// The headless terminal behind one holder-backed session, as `HolderReader`
/// uses it.
///
/// `SwiftTermHolderEmulator` and `GhosttyHolderEmulator` implement it. The
/// reader picks its emulator through `HolderEmulatorKind` when the reader is
/// built, and a running session never changes emulator. What every
/// implementation owes the reader:
///
/// - **One lock: the terminal's own.** The drain thread feeds while the actor
///   renders, resizes and snapshots, so every member that reads or changes the
///   terminal is one hold of the lock the terminal parses under, never of a
///   second lock beside it.
/// - **A feed and its stamp are one step.** `feed` and `feedPreamble` call the
///   `HolderEmulatorLedger`'s `stampArrival()` inside the same hold as the
///   parse, and nothing else stamps it, so a screen's lines and its age are
///   read in one hold and always describe the same moment. Each engine needs
///   its own way to run the stamp inside that hold:
///   - **SwiftTerm** publishes `terminalLock`. The emulator takes it around
///     the stamp and `Terminal.feed`, and around every read.
///   - **libghostty**'s `GhosttyTerminal` takes its private, non-recursive
///     lock itself, so no caller can wrap a call in it. The emulator feeds
///     through `GhosttyTerminal.feed(_:muted:resetFirst:underLock:)`, which
///     runs the stamp in its closure, inside the same hold as
///     `ghostty_terminal_vt_write`. Reads go through `withLocked`.
///     `GhosttySnapshotWriter` takes the lock itself, so the emulator calls it
///     outside any other hold.
/// - **Replies and reports are wired at construction.** The reply sink (the
///   session's pty) and the OSC 7501 tap reach the emulator through
///   `HolderEmulatorKind.makeEmulator`, never through a member here.
/// - **A reading never feeds the live terminal**, with one exception: the
///   SwiftTerm emulator's `snapshotPreamble` does, and so says
///   `snapshotNeedsSequenceBoundary`; the reader then calls it only after
///   waiting for the child's output to reach a sequence boundary.
/// - **The child hears from the emulator only in answer to its own output.**
///   A resize and a handback preamble send it nothing.
///
/// A known difference, which the corpus parity suite measures rather than
/// hides: the libghostty emulator answers queries the SwiftTerm one never did
/// (`CSI ? 996 n`, XTGETTCAP and size reports), and nothing here filters those
/// answers.
protocol HolderEmulator: AnyObject, Sendable {
    /// The child's own output — the drain loop's reads, the quiesce remainder.
    /// Stamps the ledger and parses in one hold. Replies to the child's
    /// queries reach the reply sink, and OSC 7501 reaches the tap.
    func feed(_ bytes: ArraySlice<UInt8>)

    /// A departing viewer's handback preamble. Stamps the ledger and parses in
    /// one hold, like `feed`.
    ///
    /// OSC 7501 is always silenced for exactly this feed: no report in it is
    /// delivered and no probe in it is answered, because neither came from
    /// the child now. An emulator may also drop the other replies the preamble
    /// provokes, because they answer questions the child never asked. The
    /// libghostty emulator drops them: it feeds with
    /// `GhosttyTerminal.feed(_:muted:resetFirst:underLock:)`, which mutes that
    /// one parse inside the same hold as the stamp. The SwiftTerm emulator
    /// forwards them, as `feed` does.
    ///
    /// No mode the daemon saw before the attach may survive a preamble that
    /// leaves it unnamed, or the next attach hands it on. The SwiftTerm
    /// emulator relies on the preamble's reset prelude, which names every mode
    /// its writer carries. The libghostty emulator resets its terminal first,
    /// muted, in the same hold, because libghostty's formatter names only the
    /// modes that differ from their defaults, and ends the sequence its parser
    /// may still be inside before that, because the reset does not.
    func feedPreamble(_ bytes: ArraySlice<UInt8>)

    /// Ends any sequence the parser was left inside, before a take-back that
    /// brings no preamble resumes the drain, when a viewer may have read the
    /// pty (`viewerMayHaveRead` in `HolderRegistry.takeBackFromViewer`): that
    /// viewer finished the sequence, so the child's next bytes are not its
    /// tail. Sends the child nothing and does not stamp the ledger. A cut UTF-8
    /// character first prints as U+FFFD.
    ///
    /// The SwiftTerm emulator does nothing: its attach waits, within a
    /// budget, for the child's output to reach a boundary first. The
    /// libghostty emulator's attach does not, so it ends the sequence here.
    ///
    /// Not called where no viewer read the pty, because there the child's
    /// next bytes do finish the sequence: a cancelled attach, a descriptor
    /// delivered to an app already confirmed gone while its attach was still
    /// pending, and a detach with an empty preamble, which the app sends when
    /// it never received the descriptor or tore its view down before its
    /// reader started. Two kinds of case come out the other way, as the lesser
    /// harm: an empty preamble from a viewer that read keeps the sequence, and
    /// a death pass or a sweep after an attach nobody read abandons it. The
    /// first comes from an app whose ack is refused or lost after its reader
    /// started, and from the app's libghostty engine when its snapshot writer
    /// throws; the second from an unacknowledged attach whose reply was lost,
    /// or a lost empty-preamble release. Telling them apart needs the app to
    /// report whether it read, a protocol change outside this flag.
    func abandonOpenSequence()

    /// The kind this emulator is. Fixed at construction; it can differ from
    /// the kind asked for when libghostty could not make its terminal and
    /// `HolderEmulatorKind.makeEmulator` fell back to SwiftTerm.
    var kind: HolderEmulatorKind { get }

    /// Whether a snapshot taken now needs the child's output to reach a
    /// sequence boundary first, asked by the reader before it waits
    /// (`HolderReader.suspendDraining`) and again after each read of the
    /// wait, which runs until `isAtSequenceBoundary`, until this turns false,
    /// or until its budget runs out. Always true for SwiftTerm, whose
    /// `DECRQM` queries would cut a sequence the child is part-way through.
    /// For libghostty, whose snapshot only reads the live terminal and ends
    /// with the bytes of a sequence left open for the viewer to finish, true
    /// only while that sequence is too long for libghostty to have kept its
    /// bytes, which the snapshot could otherwise end only by dropping its rest.
    var snapshotNeedsSequenceBoundary: Bool { get }

    /// Reshapes the grid. Never touches the tty, which is the reader's, and
    /// sends the child nothing: the libghostty emulator mutes the in-band size
    /// report a child asks for with mode 2048, which the SwiftTerm emulator
    /// never had to send.
    func resize(columns: Int, rows: Int)

    /// The grid's dimensions.
    var size: (columns: Int, rows: Int) { get }

    /// Whether the child's output so far ends between sequences, so bytes the
    /// daemon feeds its own emulator cannot cut one of the child's short.
    var isAtSequenceBoundary: Bool { get }

    /// The viewport as text, one line per row, trailing blank rows dropped.
    func renderScreen() -> String

    /// The typed screen: lines, cursor (position and visibility), size and
    /// modes from one hold, stamped by the ledger with provenance and age.
    func screen(maxLines: Int, source: TerminalScreen.Source) throws -> TerminalScreen

    /// The modes, their provenance and their age, without the line walk.
    func modeReading(source: TerminalScreen.Source) -> TerminalModeReading

    /// The retained scrollback plus viewport as styled lines, in the capture
    /// form: trailing blank rows dropped, nothing fed, nothing sent.
    func styledCapture(maxScrollbackLines: Int) -> String

    /// The whole terminal — modes, scrollback, viewport, cursor — as bytes
    /// that rebuild it in a fresh terminal. Nothing it provokes reaches the
    /// child, and it does not stamp the ledger.
    ///
    /// It never fails the attach. An emulator that cannot serialize its
    /// terminal logs an error and returns a preamble that still resets the
    /// receiver.
    func snapshotPreamble(maxScrollbackLines: Int) -> Data
}

/// Which terminal parses a holder-backed session's output.
///
/// Read once, when the reader is built, so a running session never changes
/// emulator. `CaseIterable` so that the reader's suites can run against every
/// kind the daemon can build.
enum HolderEmulatorKind: CaseIterable, Sendable {
    /// A headless SwiftTerm `Terminal`: `SwiftTermHolderEmulator`.
    case swiftTerm
    /// A libghostty-vt terminal: `GhosttyHolderEmulator`. Chosen by the
    /// `ghostty_daemon_emulator_enabled` flag, default off.
    case ghostty

    /// The kind the daemon's libghostty emulator flag picks:
    /// `Config.ghosttyDaemonEmulatorEnabled`, resolved.
    init(ghosttyDaemonEmulatorEnabled: Bool) {
        self = ghosttyDaemonEmulatorEnabled ? .ghostty : .swiftTerm
    }

    /// The kind the flag picks now, read from the config table: what the
    /// daemon hands its registry, which asks each time it builds a reader.
    ///
    /// A failed read is logged and takes the shipped default, so a database
    /// fault costs the flag for one reader and never the reader itself.
    static func configured(by config: ConfigStore) async -> HolderEmulatorKind {
        let enabled: Bool
        do {
            enabled = try await config.get().ghosttyDaemonEmulatorEnabled
        } catch {
            logger.error(
                """
                could not read ghostty_daemon_emulator_enabled, so this reader takes the shipped \
                default: \(String(describing: error), privacy: .public)
                """)
            enabled = Config.ghosttyDaemonEmulatorDefault
        }
        return HolderEmulatorKind(ghosttyDaemonEmulatorEnabled: enabled)
    }

    /// Builds this kind's emulator for one session, with its ledger stamped
    /// as adopted now and its outbound wiring in place.
    ///
    /// - Parameter reply: bytes the terminal answers the child with —
    ///   device-status replies, cursor-position reports. A reply that never
    ///   reaches the child is a hang in that child, not a cosmetic loss.
    /// - Parameter programStatus: the OSC 7501 tap. With one, the emulator
    ///   answers the `?` probe and hands every report's payload to `deliver`;
    ///   nil leaves OSC 7501 unhandled.
    /// - Parameter makeGhosttyTerminal: how `.ghostty` builds its terminal. A
    ///   test seam; production passes nothing.
    ///
    /// **`.ghostty` falls back to SwiftTerm** when libghostty cannot make the
    /// terminal, with an error in the log naming the session and the reason.
    /// The session still gets an emulator, and its pty is still drained; the
    /// built emulator's `kind` says which one it got.
    func makeEmulator(
        sessionID: UUID,
        columns: Int,
        rows: Int,
        scrollback: Int,
        observedChildFromStart: Bool,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant,
        programStatus: HolderProgramStatusTap?,
        reply: @escaping @Sendable (ArraySlice<UInt8>) -> Void,
        makeGhosttyTerminal: GhosttyHolderEmulator.TerminalFactory = GhosttyHolderEmulator.makeTerminal
    ) -> any HolderEmulator {
        let ledger = HolderEmulatorLedger(
            sessionID: sessionID,
            observedChildFromStart: observedChildFromStart,
            monotonicNow: monotonicNow)
        let swiftTerm = {
            SwiftTermHolderEmulator(
                ledger: ledger,
                columns: columns,
                rows: rows,
                scrollback: scrollback,
                programStatus: programStatus,
                reply: reply)
        }
        switch self {
        case .swiftTerm:
            return swiftTerm()
        case .ghostty:
            do {
                return try GhosttyHolderEmulator(
                    ledger: ledger,
                    sessionID: sessionID,
                    columns: columns,
                    rows: rows,
                    scrollback: scrollback,
                    programStatus: programStatus,
                    reply: reply,
                    makeTerminal: makeGhosttyTerminal)
            } catch {
                Self.logger.error(
                    """
                    session \(sessionID.uuidString, privacy: .public): libghostty could not make \
                    the daemon's terminal, so this session uses SwiftTerm: \
                    \(String(describing: error), privacy: .public)
                    """)
                return swiftTerm()
            }
        }
    }

    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holder")
}

/// What a holder emulator knows about itself that no grid can tell: when it
/// began, when it last took in bytes, and whether it watched its child from
/// birth — and the screen and mode reading built from those facts and a
/// projection. One type that every `HolderEmulator` uses, each emulator with
/// its own instance, so the arithmetic and the handshake records exist once.
///
/// `@unchecked Sendable` because the one mutable field, `lastByteAt`, is
/// guarded by the **owning emulator's lock** — the terminal's own, so that a
/// feed and its stamp are one step and a screen reads lines and age in one
/// hold. `stampArrival`, `screen` and `modeReading` are called only under that
/// lock. Every other field is immutable, so the program-status records may run
/// inside a parse or after it.
final class HolderEmulatorLedger: @unchecked Sendable {
    /// Where the Program Status Protocol handshake records go — `.notice`, the
    /// one level macOS keeps, because an agent decides once at startup whether
    /// to report, and a session that missed the answer stays silent for its
    /// whole life. One line per probe, so about one per session start.
    private static let programStatusLog = Logger(subsystem: "com.tbd.daemon", category: "programStatus")

    /// The session this emulator belongs to, which is the terminal's ID. Read
    /// only to name the session in the handshake records.
    private let sessionID: UUID
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    /// When this emulator started existing — the floor for a screen's age.
    ///
    /// A store that has never consumed a byte reports its own age rather than
    /// no age at all, so a fresh, silent session reads as exactly as old as it
    /// is instead of as instantly current.
    private let adoptedAt: ContinuousClock.Instant
    /// When this emulator last took in bytes that came from outside the daemon.
    ///
    /// Under the owning emulator's lock, and stamped by `stampArrival()`, which
    /// an emulator calls from `feed` and its preamble twin `feedPreamble`
    /// only — which is the whole definition, because it is what decides the
    /// answer for each of the three things that reach them and the one that
    /// does not:
    ///
    /// - **The drain loop's reads** and **the quiesce remainder** stamp it.
    ///   They are the child's own output; this is the measurement's subject.
    /// - **A handback preamble** (`HolderReader.ingest(preamble:)`) stamps it,
    ///   deliberately. A returning viewer hands back the screen as it stood a
    ///   moment ago, so the emulator's view really is fresh again, and
    ///   reporting it as an hour old would make a take-back look like a session
    ///   nobody had watched.
    /// - **`snapshotPreamble`** does not. The SwiftTerm emulator's `DECRQM`
    ///   probes feed the `Terminal` directly rather than through `feed`. The
    ///   daemon asking its own emulator a question must never make a stale
    ///   screen look fresh. Keep it that way — routing a probe through `feed`
    ///   would make every read reset the age it was taken to measure.
    ///
    /// A screen reading stamps nothing at all.
    private var lastByteAt: ContinuousClock.Instant?
    /// Whether this emulator was built with its child, so that both its mode
    /// flags and its grid are observations rather than a fresh terminal's
    /// defaults over a blank screen.
    ///
    /// One fact with two consequences, and it is reported as both: as
    /// `modesObserved` on every screen and mode reading, and as
    /// `contentObserved` on every screen. Unobserved modes are a terminal's
    /// defaults; unobserved content is a grid whose cells the child has not
    /// repainted since this emulator existed, and a TUI repaints only what it
    /// is changing.
    ///
    /// Set at construction by whoever knows how this emulator came to exist,
    /// and never moved afterwards: nothing this emulator can be fed carries
    /// provenance it was not built with, because every preamble in the system
    /// originates from a daemon emulator's own snapshot.
    private let observedChildFromStart: Bool

    init(
        sessionID: UUID,
        observedChildFromStart: Bool,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.sessionID = sessionID
        self.observedChildFromStart = observedChildFromStart
        self.monotonicNow = monotonicNow
        self.adoptedAt = monotonicNow()
    }

    /// Records that bytes from outside the daemon arrived now. Caller holds
    /// the owning emulator's lock, in the same hold as the parse of those
    /// bytes.
    ///
    /// **It moves no provenance**: the child's running output says nothing
    /// about the modes it set or the cells it painted before this emulator
    /// existed, so a session that happens to print a lot must not talk its
    /// way into a provenance it never earned. A busy child repaints some of
    /// the grid and leaves the rest exactly as blank as it found it, which is
    /// the state `contentObserved` exists to name.
    func stampArrival() {
        lastByteAt = monotonicNow()
    }

    /// The typed screen from a projection and the cursor's visibility, with
    /// the facts a grid cannot tell: which store answered, how stale it is,
    /// and whether it watched the child from birth. Caller holds the owning
    /// emulator's lock, in the same hold as the projection.
    ///
    /// Throws only what `TerminalScreen`'s construction refuses, which is
    /// where the whitelist is enforced.
    func screen(
        _ projected: ProjectedScreen, cursorVisible: Bool, source: TerminalScreen.Source
    ) throws -> TerminalScreen {
        let cursor = TerminalScreen.Cursor(
            row: projected.cursorRow,
            column: projected.cursorColumn,
            visible: cursorVisible)

        return try TerminalScreen(
            lines: projected.lines,
            viewportStart: projected.viewportStart,
            cursor: cursor,
            size: projected.size,
            modes: projected.modes,
            modesObserved: observedChildFromStart,
            contentObserved: observedChildFromStart,
            source: source,
            ageMilliseconds: ageMilliseconds())
    }

    /// The modes, their provenance and their age. Caller holds the owning
    /// emulator's lock, in the same hold as the read of `modes`.
    func modeReading(
        _ modes: TerminalScreen.ChildModes, source: TerminalScreen.Source
    ) -> TerminalModeReading {
        TerminalModeReading(
            modes: modes,
            modesObserved: observedChildFromStart, source: source,
            ageMilliseconds: ageMilliseconds())
    }

    /// Records a probe the emulator answered: whether it was there when the
    /// child started, and how long after it began existing the probe came.
    /// Reads only immutable fields, so it may run inside the parse or after
    /// it; it only logs.
    func recordProbeAnswered() {
        Self.programStatusLog.notice(
            """
            program-status probe answered terminal=\(self.sessionID.uuidString, privacy: .public) \
            observedChildFromStart=\(self.observedChildFromStart, privacy: .public) \
            sinceAdoptMs=\(self.milliseconds(since: self.adoptedAt), privacy: .public)
            """)
    }

    /// Records a probe left unanswered because it arrived inside a handback
    /// preamble. Reads only immutable fields; it only logs.
    func recordProbeIgnoredInPreamble() {
        Self.programStatusLog.notice(
            "program-status probe ignored terminal=\(self.sessionID.uuidString, privacy: .public) reason=preamble")
    }

    /// How long ago this emulator last consumed a byte, in milliseconds, never
    /// negative. Caller holds the owning emulator's lock.
    private func ageMilliseconds() -> Int {
        milliseconds(since: lastByteAt ?? adoptedAt)
    }

    /// Milliseconds from `instant` to now on `monotonicNow`, never negative.
    ///
    /// Clamped at zero rather than trusted: the clock is injected, and a seam
    /// that ever moved backwards would otherwise produce an age the screen type
    /// refuses — turning a test double's mistake into a failed machine read.
    private func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        let elapsed = instant.duration(to: monotonicNow())
        let total =
            elapsed.components.seconds * 1_000
            + elapsed.components.attoseconds / 1_000_000_000_000_000
        return Int(max(0, total))
    }
}
