import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// What a holder-backed job inherits from the daemon that started it, measured
/// from inside the job.
///
/// The defect these were written against: the daemon `posix_spawn`s a holder
/// from a Swift-concurrency worker thread, which runs with nearly every signal
/// blocked, and **a signal mask survives `fork` and `execve` unchanged**. So the
/// job at the end of that chain could not be interrupted, suspended, hung up on,
/// terminated by anything but `SIGKILL`, or told its terminal had changed size.
/// The last of those is the one a user sees: a full-screen TUI never relayouts,
/// and "the jiggle" in
/// `docs/specs/2026-08-30-pty-holder-session-transport-design.md` — a forced
/// `SIGWINCH` that makes such a program repaint into an incoming reader's
/// emulator — silently does nothing.
///
/// Dispositions are a separate inheritance from the mask and are covered by
/// their own line in `Holder.spawnChild`; these tests are about the mask.
///
/// **Tier 3.** Each test spawns a real `TBDHolder` through the real
/// `HolderSpawner`, and the job is a real interpreter on a real pty.
@Suite(.serialized)
struct HolderJobSignalTests {

    /// A job that reports its own signal mask, then answers two questions on
    /// demand: what size its terminal is now, and whether it has been signalled
    /// about a change.
    ///
    /// It is an interpreter rather than `/bin/sh` because a shell cannot read
    /// its own mask — there is no builtin for `sigprocmask`, and `ps -o sigmask`
    /// is not an answer either: `kinfo_proc.p_sigmask` is deprecated and reads
    /// `0` on macOS even for a process with nineteen signals blocked (measured
    /// while writing these tests, which is why nothing here consults `ps`).
    ///
    /// Every line ends in `|` so an assertion can pin an **empty** value:
    /// `MASK=|` is a clear mask, while `MASK=` alone is also a prefix of every
    /// mask that is not clear.
    private static let probe = """
        import signal, sys, fcntl, termios, struct
        def size():
            packed = fcntl.ioctl(0, termios.TIOCGWINSZ, bytes(8))
            rows, cols = struct.unpack("hhhh", packed)[:2]
            return "%dx%d" % (rows, cols)
        def on_winch(signum, frame):
            print("WINCH size=" + size() + "|", flush=True)
        signal.signal(signal.SIGWINCH, on_winch)
        blocked = sorted(int(s) for s in signal.pthread_sigmask(signal.SIG_BLOCK, []))
        print("MASK=" + ",".join(str(s) for s in blocked) + "|", flush=True)
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            print("TIOCGWINSZ size=" + size() + "|", flush=True)
        """

    /// The mask is the whole finding of the first test, so it is read directly
    /// rather than inferred from a signal that did or did not arrive.
    @Test func theJobStartsWithAnEmptySignalMask() async throws {
        let fixture = try await Self.startProbe()
        defer { fixture.tearDown() }
        let reader = try await Self.attachReader(to: fixture)
        defer { stopInBackground(reader) }

        _ = await pollUntil("the job to report its signal mask") {
            await reader.renderScreen().contains("MASK=")
        }
        let screen = await reader.renderScreen()
        #expect(
            screen.contains("MASK=|"),
            """
            the job inherited a non-empty signal mask, so it cannot be interrupted, suspended, \
            terminated or resized; screen was: \(screen.debugDescription)
            """)
    }

    /// A resize must reach the job as a `SIGWINCH`, not merely as a new number
    /// in the kernel's `winsize`.
    ///
    /// Both halves are asserted because the bug lived entirely in the second
    /// one. The `TIOCSWINSZ` always landed — the readback below proves the job
    /// sees the new size when it looks — and a test that checked only the size
    /// would have passed throughout, while every full-screen program in a holder
    /// session kept drawing at the size it was born with.
    @Test func aResizeSignalsTheJobAndChangesItsWindowSize() async throws {
        let fixture = try await Self.startProbe()
        defer { fixture.tearDown() }
        let reader = try await Self.attachReader(to: fixture)
        defer { stopInBackground(reader) }

        // `MASK=` is printed after the handler is installed, so its arrival is
        // what makes a `SIGWINCH` from this point on observable at all.
        let armed = await pollUntil("the job to install its SIGWINCH handler") {
            await reader.renderScreen().contains("MASK=")
        }
        #expect(armed)

        await reader.resize(columns: 121, rows: 41)

        // The job's own `TIOCGWINSZ`, asked for over stdin and answered
        // independently of any signal: this is the half that was never broken,
        // and it is what makes the other assertion's failure mean "the ioctl
        // landed and the signal did not".
        try await reader.write(Data("s\n".utf8))
        let sawSize = await pollUntil("the job's own TIOCGWINSZ readback") {
            await reader.renderScreen().contains("TIOCGWINSZ size=41x121|")
        }
        #expect(sawSize)

        let sawSignal = await pollUntil("the job to be signalled about the new size") {
            await reader.renderScreen().contains("WINCH size=41x121|")
        }
        let screen = await reader.renderScreen()
        #expect(
            sawSignal,
            """
            the pty was resized but the job was never signalled; screen was: \
            \(screen.debugDescription)
            """)
    }

    /// The holder's own mask, pinned through the one consequence that is
    /// observable from outside it.
    ///
    /// Two separate lines fix the mask — `HolderSpawner` spawns the holder with
    /// an empty one, and `Holder.spawnChild` clears it again in the `forkpty`
    /// child — and the two tests above pass on either alone, because they watch
    /// the job at the end of the chain. This one watches the holder: a supervisor
    /// that can be reclaimed only with SIGKILL is a defect on its own terms, and
    /// SIGTERM reaching it is what says its own mask is clear.
    ///
    /// `SIGHUP` would not do: the holder ignores that one deliberately, which is
    /// what makes it survive the daemon that spawned it.
    @Test func theHolderItselfCanBeTerminated() async throws {
        let fixture = try await HolderProcessFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }

        kill(fixture.handle.holderPID, SIGTERM)

        // Nothing reaps it here, so a terminated holder is a zombie rather than
        // an absence — and `kill(pid, 0)` cannot tell that from a live one.
        let terminated = await pollUntil("the holder to die of SIGTERM", timeout: 10.0) {
            holderProcessState(fixture.handle.holderPID) == "SZOMB"
        }
        #expect(
            terminated,
            """
            the holder ignored SIGTERM and is \
            \(holderProcessState(fixture.handle.holderPID) ?? "gone"); it can only be reclaimed \
            with SIGKILL
            """)
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
            locateInterpreter(), "no python3 to run the signal probe with")
        return try await HolderProcessFixture.start(
            launch: HolderProcessFixture.launch(
                executable: interpreter, arguments: ["-u", "-c", probe]))
    }

    /// Takes the pty the way the daemon does, and starts draining it. Nothing
    /// is observable until something is reading: the job's own writes would
    /// otherwise fill the terminal queue and stop it.
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
