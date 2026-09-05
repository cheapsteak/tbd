import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The jiggle, measured from inside the job it is supposed to reach.
///
/// A reader taking over a session inherits an emulator that knows nothing of
/// what the job has already drawn. The jiggle is how a full-screen program is
/// asked to draw it again: grow the tty by one column, let the job be
/// scheduled, put the column back. Two `SIGWINCH`es, no net size change.
///
/// What it can and cannot do was measured rather than assumed
/// (`docs/specs/2026-09-01-holder-repaint-measurement.md`): an alt-screen
/// program repaints its entire viewport and none of its scrollback, and a plain
/// shell prompt repaints essentially nothing. The jiggle heals screen state; it
/// cannot recover history, which is why the snapshot preamble exists alongside
/// it and not instead of it.
///
/// Two properties are separable and both are asserted, because a jiggle can
/// fail in either direction:
///
///   - The job must observe the **grown** size. Signals do not queue, so two
///     `TIOCSWINSZ` calls with no scheduling gap between them can be collapsed
///     into a single handler run that reads the final, unchanged size — a
///     jiggle that costs an ioctl and repaints nothing.
///   - The job must be left at the size it started at, on the **tty**, which is
///     the only authority on its geometry. The emulator's grid is not evidence
///     of that: the jiggle deliberately never touches it, so a jiggle that
///     forgot to restore the tty would leave `gridSize` looking perfect.
///
/// **Tier 3.** A real `TBDHolder`, a real pty, and a real interpreter as the
/// job.
@Suite(.serialized)
struct HolderJiggleTests {

    /// A job that reports every `SIGWINCH` with the size it sees at handler
    /// time, and answers a separate `TIOCGWINSZ` on demand over stdin.
    ///
    /// The size is read inside the handler on purpose: it is what distinguishes
    /// "the job saw the tty grow" from "the job was signalled once, after the
    /// column was already back".
    ///
    /// An interpreter rather than `/bin/sh` for the same reason the signal
    /// probe next door uses one — a shell cannot install a `SIGWINCH` handler
    /// that prints anything useful. Every line ends in `|` so an assertion can
    /// pin a whole value rather than a prefix of a longer one.
    private static let probe = """
        import signal, sys, fcntl, termios, struct
        def size():
            packed = fcntl.ioctl(0, termios.TIOCGWINSZ, bytes(8))
            rows, cols = struct.unpack("hhhh", packed)[:2]
            return "%dx%d" % (rows, cols)
        def on_winch(signum, frame):
            print("WINCH size=" + size() + "|", flush=True)
        signal.signal(signal.SIGWINCH, on_winch)
        print("ARMED|", flush=True)
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            print("TIOCGWINSZ size=" + size() + "|", flush=True)
        """

    @Test func aJiggleIsSeenByTheJobAsTwoSizeChangesThatCancelOut() async throws {
        let fixture = try await Self.startProbe()
        defer { fixture.tearDown() }
        let reader = try await Self.attachReader(to: fixture)
        defer { stopInBackground(reader) }

        // Nothing before this line is observable as a signal: the handler is
        // installed immediately before `ARMED|` is printed, so a `SIGWINCH`
        // sent earlier would have killed the job rather than been reported.
        let armed = await pollUntil("the job to install its SIGWINCH handler") {
            await reader.renderScreen().contains("ARMED|")
        }
        #expect(armed)

        await reader.jiggle()

        // The grown size. This is the assertion the scheduling gap exists for:
        // without it the two ioctls coalesce into one observation of 24x80 and
        // this line never appears.
        let sawGrown = await pollUntil("the job to observe the grown tty size") {
            await reader.renderScreen().contains("WINCH size=24x81|")
        }
        let afterGrow = await reader.renderScreen()
        #expect(
            sawGrown,
            """
            the job was never signalled at the grown size, so the two size changes were \
            coalesced into one and nothing would repaint; screen was: \
            \(afterGrow.debugDescription)
            """)

        let sawRestored = await pollUntil("the job to observe the restored tty size") {
            await reader.renderScreen().contains("WINCH size=24x80|")
        }
        #expect(sawRestored)

        // Exactly two, in a session where nothing else resizes anything: a
        // jiggle is one grow and one restore, not a burst.
        let screen = await reader.renderScreen()
        let winches = screen.components(separatedBy: "WINCH").count - 1
        #expect(
            winches == 2,
            "expected exactly two SIGWINCHes, saw \(winches); screen was: \(screen.debugDescription)")

        // The tty's own answer, asked for over stdin and independent of any
        // signal. This is what pins "net zero" on the descriptor rather than on
        // the emulator, which the jiggle never touches and which would therefore
        // read correctly even if the restoring ioctl had been dropped.
        try await reader.write(Data("s\n".utf8))
        let readback = await pollUntil("the job's own TIOCGWINSZ readback") {
            await reader.renderScreen().contains("TIOCGWINSZ size=24x80|")
        }
        let afterReadback = await reader.renderScreen()
        #expect(
            readback,
            """
            the tty was left at a size it did not start at; screen was: \
            \(afterReadback.debugDescription)
            """)

        // The emulator's grid never moved. Resizing it too would reflow its
        // contents out and back for nothing, and land the repaint at a size the
        // grid was never at.
        let grid = await reader.gridSize
        #expect(grid.columns == 80 && grid.rows == 24)
    }

    // MARK: - Support

    /// Where the probe interpreter is. `/usr/bin/python3` is the one every
    /// machine that can build this package has, and the others are there so a
    /// developer box with a different layout still runs the suite.
    private static func locateInterpreter() -> String? {
        ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func startProbe() async throws -> HolderProcessFixture {
        let interpreter = try #require(
            locateInterpreter(), "no python3 to run the jiggle probe with")
        return try await HolderProcessFixture.start(
            launch: HolderProcessFixture.launch(
                executable: interpreter, arguments: ["-u", "-c", probe]))
    }

    /// Takes the pty the way the daemon does, and starts draining it. Nothing
    /// is observable until something is reading: the job's own writes would
    /// otherwise fill the terminal queue and stop it.
    ///
    /// The reader's grid is created at the pty's own 80x24, because the jiggle
    /// derives the tty size it restores from the grid — a reader whose grid
    /// disagreed with its pty would be resizing the job, not jiggling it.
    private static func attachReader(to fixture: HolderProcessFixture) async throws -> HolderReader {
        let (_, ptyFD) = try await fixture.client.handOverPTY()
        await fixture.client.close()
        let reader = HolderReader(
            sessionID: fixture.sessionID, ptyFD: ptyFD, columns: 80, rows: 24)
        try await reader.start()
        return reader
    }
}

/// Stops a reader from a `defer`, which cannot `await`. A reader left running
/// leaks a thread and a pty descriptor for the rest of the suite; the stop is
/// idempotent.
private func stopInBackground(_ reader: HolderReader) {
    Task.detached { await reader.stop() }
}
