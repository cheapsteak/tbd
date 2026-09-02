import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The daemon as default reader, driven against real holders and real jobs.
///
/// The suite exists for one measured fact: **a job cannot finish exiting while
/// anything it wrote is still queued on its terminal.** The job is the pty's
/// session leader, and XNU's `proc_exit` calls `ttywait` before revoking the
/// terminal, so a job that exits with a few bytes unread stops half-exited and
/// the holder's `waitpid` correctly reports nothing. Draining is therefore a
/// liveness requirement, and two tests here — `keepsDrainingPastOneBufferful`
/// and `completesTheExitOfAJobThatWroteUnreadOutput` — are the regression tests
/// for it.
///
/// An exit is observed as the job's pid **disappearing**, which happens only
/// once the holder's `waitpid` has collected it. A wedged job is still there:
/// it has run its last instruction, but it is stuck inside `proc_exit` and
/// nothing has reaped it. That is exactly the distinction these tests need, and
/// the reason a screenful of expected output is never enough on its own.
@Suite(.serialized)
struct HolderReaderTests {

    // MARK: - What a session's history costs

    /// The per-cell size the scrollback budget is computed from.
    ///
    /// `HolderReader.scrollbackLines` is a memory decision as much as a history
    /// one, and the design spec states the worst case it implies. That number is
    /// computed from SwiftTerm's cell layout, so it is only true while the
    /// layout is: a `BufferLine` holds a flat `UnsafeMutableBufferPointer` of
    /// `CharData`, one per column, and `CharData` carries a rune, a width, an
    /// atom and a full `Attribute` (two colours, a style, an underline style and
    /// an optional underline colour).
    ///
    /// This goes red when a SwiftTerm upgrade changes that layout — which is its
    /// whole job. The fix is to recompute the figure in
    /// `docs/specs/2026-08-30-pty-holder-session-transport-design.md` and update
    /// the number here, not to relax the assertion.
    @Test func theScrollbackBudgetIsComputedFromSwiftTermsCellSize() {
        let bytesPerCell = MemoryLayout<CharData>.stride
        #expect(
            bytesPerCell == 40,
            """
            SwiftTerm's per-cell size is now \(bytesPerCell) bytes, so the worst-case scrollback \
            figure in docs/specs/2026-08-30-pty-holder-session-transport-design.md is stale
            """)
    }

    // MARK: - The drain is what lets jobs die

    /// The regression test for the measured wedge, and the reason this task
    /// exists.
    ///
    /// The job writes far more than any kernel tty buffer can hold, so a reader
    /// that stops reading — or never starts — leaves it blocked mid-write and
    /// then blocked in `ttywait` forever. The assertion is not that the output
    /// is pretty: it is that the job **exits**, which it can only do if
    /// somebody drained every byte of it.
    @Test func keepsDrainingPastOneBufferful() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "for i in $(seq 1 5000); do echo line-$i; done")
        defer { fixture.tearDown() }

        let client = fixture.client
        let (_, ptyFD) = try await client.handOverPTY()
        await client.close()
        let reader = HolderReader(
            sessionID: fixture.sessionID, ptyFD: ptyFD, columns: 80, rows: 24)
        try await reader.start()
        defer { stopInBackground(reader) }

        let status = await awaitJobExit(childPID: fixture.handle.childPID, reportedBy: client)
        #expect(status == .exited(code: 0), "the job never finished exiting: \(String(describing: status))")

        // And the emulator holds the tail — draining is not the same as
        // discarding, and a reader that read the bytes without feeding them
        // would satisfy the exit assertion alone.
        let sawTail = await pollUntil("the last line on the emulator's screen") {
            await reader.renderScreen().contains("line-5000")
        }
        #expect(sawTail)
        let history = await reader.renderScreenWithScrollback(maxLines: 500)
        #expect(history.contains("line-4900"), "the scrollback did not keep the recent history")
    }

    /// The `ttywait` case stated directly: a job that exits with output nobody
    /// has read still completes its exit, because a reader is attached.
    ///
    /// The second write is what makes this discriminate. A drain that stopped
    /// after its first read would have emptied the queue before the job wrote
    /// `CHARLIE`, and the job would then die on a clean terminal no matter how
    /// broken the loop was — so the job writes, pauses long enough for that
    /// first read to happen, and writes again immediately before exiting.
    @Test func completesTheExitOfAJobThatWroteUnreadOutput() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "printf 'BRAVO\\n'; sleep 0.4; printf 'CHARLIE\\n'")
        defer { fixture.tearDown() }

        let client = fixture.client
        let (_, ptyFD) = try await client.handOverPTY()
        await client.close()
        let reader = HolderReader(
            sessionID: fixture.sessionID, ptyFD: ptyFD, columns: 80, rows: 24)
        try await reader.start()
        defer { stopInBackground(reader) }

        let status = await awaitJobExit(childPID: fixture.handle.childPID, reportedBy: client)
        #expect(status == .exited(code: 0), "the job never finished exiting: \(String(describing: status))")

        let sawBoth = await pollUntil("both markers on the emulator's screen") {
            let screen = await reader.renderScreen()
            return screen.contains("BRAVO") && screen.contains("CHARLIE")
        }
        #expect(sawBoth)
    }

    // MARK: - Read failures

    /// A read that fails with an errno nobody has classified must not end the
    /// drain — the loop backs off and tries again, and picks the session up
    /// where it left off.
    ///
    /// `ENOMEM` is the case this defends: a machine under memory pressure can
    /// fail a `read` on a perfectly live pty, and a loop that took that as
    /// final would stop draining a job that is still producing output — which
    /// is the `ttywait` wedge this whole task exists to close, arrived at by a
    /// different road.
    ///
    /// The marker written *after* the failures is what discriminates. A drain
    /// that gave up would still have `ALPHA` nowhere and `BRAVO` nowhere, but a
    /// drain that merely swallowed the error and read once more would show
    /// `ALPHA` alone.
    @Test func retriesATransientReadFailureAndKeepsDraining() async throws {
        let fault = ScriptedReadFault(errno: ENOMEM, times: 3)
        let fixture = try await HolderProcessFixture.start(
            command: "printf 'ALPHA\\n'; sleep 0.6; printf 'BRAVO\\n'; sleep 30")
        defer { fixture.tearDown() }

        let client = fixture.client
        let (_, ptyFD) = try await client.handOverPTY()
        await client.close()
        let reader = HolderReader(
            sessionID: fixture.sessionID, ptyFD: ptyFD, columns: 80, rows: 24,
            readFault: fault.seam())
        try await reader.start()
        defer { stopInBackground(reader) }

        let sawBoth = await pollUntil("both markers, across the injected read failures") {
            let screen = await reader.renderScreen()
            return screen.contains("ALPHA") && screen.contains("BRAVO")
        }
        let screen = await reader.renderScreen()
        #expect(sawBoth, "screen was: \(screen.debugDescription)")
        #expect(
            fault.injectedCount == 3,
            "the fault fired \(fault.injectedCount) times, so this proved nothing about retrying")
    }

    /// The bound on retrying is the *cadence*, not a count.
    ///
    /// A scheme that gave up after N attempts would put the descriptor back
    /// where the old code left it — permanently unread, with the job unable to
    /// finish exiting — just later. So a failure that keeps failing keeps being
    /// retried, forever, at a floor of a few attempts a second. Both halves are
    /// asserted: attempts continue well past any plausible give-up point, and
    /// they are paced rather than spun.
    @Test func keepsRetryingAnUnclassifiedReadFailureRatherThanGivingUp() async throws {
        let fault = ScriptedReadFault(errno: ENOMEM, times: nil)
        let fixture = try await HolderProcessFixture.start(
            command: "printf 'ECHO\\n'; sleep 30")
        defer { fixture.tearDown() }

        let client = fixture.client
        let (_, ptyFD) = try await client.handOverPTY()
        await client.close()
        let reader = HolderReader(
            sessionID: fixture.sessionID, ptyFD: ptyFD, columns: 80, rows: 24,
            readFault: fault.seam())
        try await reader.start()
        defer { stopInBackground(reader) }

        let keptTrying = await pollUntil("read attempts to continue past a give-up point") {
            fault.injectedCount > 12
        }
        #expect(keptTrying, "the drain loop stopped retrying after \(fault.injectedCount) attempts")
        // Paced, not spun. The backoff floor is four attempts a second; a loop
        // retrying without one would be four orders of magnitude above this.
        #expect(
            fault.injectedCount < 400,
            "the retry path is spinning: \(fault.injectedCount) attempts")
    }

    /// The other branch: an errno that genuinely cannot recover ends the drain
    /// immediately, with no retries at all.
    ///
    /// `EBADF` means the number is not an open descriptor, so retrying it is
    /// pure waste. The assertion is that exactly one read was ever attempted,
    /// even though the job keeps writing for the whole window — which is what
    /// separates "classified as permanent" from "retried and still failing".
    @Test func stopsDrainingOnAPermanentReadFailure() async throws {
        let fault = ScriptedReadFault(errno: EBADF, times: nil)
        let fixture = try await HolderProcessFixture.start(
            command: "while true; do printf 'TICK\\n'; sleep 0.05; done")
        defer { fixture.tearDown() }

        let client = fixture.client
        let (_, ptyFD) = try await client.handOverPTY()
        await client.close()
        let reader = HolderReader(
            sessionID: fixture.sessionID, ptyFD: ptyFD, columns: 80, rows: 24,
            readFault: fault.seam())
        try await reader.start()
        defer { stopInBackground(reader) }

        let attempted = await pollUntil("the first read attempt") { fault.injectedCount >= 1 }
        #expect(attempted)

        try await Task.sleep(for: .milliseconds(600))
        #expect(
            fault.injectedCount == 1,
            "a permanent errno was retried \(fault.injectedCount) times")
    }

    // MARK: - The emulator

    @Test func drainsChildOutputIntoTheEmulator() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "printf 'ALPHA\\n'; sleep 30")
        defer { fixture.tearDown() }

        let client = fixture.client
        let (_, ptyFD) = try await client.handOverPTY()
        await client.close()
        let reader = HolderReader(
            sessionID: fixture.sessionID, ptyFD: ptyFD, columns: 80, rows: 24)
        try await reader.start()
        defer { stopInBackground(reader) }

        let sawMarker = await pollUntil("the job's output on the emulator's screen") {
            await reader.renderScreen().contains("ALPHA")
        }
        let screen = await reader.renderScreen()
        #expect(sawMarker, "screen was: \(screen.debugDescription)")
    }

    /// Input written to the reader reaches the job.
    ///
    /// The assertion is on the job's *transformation* of the input rather than
    /// on the input itself: a pty in canonical mode echoes what is written to
    /// it, so a screen containing `MARKER` would prove only that the terminal
    /// echoed, not that anything read it. `GOT:MARKER` can only have been
    /// produced by the job.
    @Test func writeReachesTheChild() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done")
        defer { fixture.tearDown() }

        let client = fixture.client
        let (_, ptyFD) = try await client.handOverPTY()
        await client.close()
        let reader = HolderReader(
            sessionID: fixture.sessionID, ptyFD: ptyFD, columns: 80, rows: 24)
        try await reader.start()
        defer { stopInBackground(reader) }

        try await reader.write(Data("MARKER\n".utf8))

        let sawResponse = await pollUntil("the job's answer to the written line") {
            await reader.renderScreen().contains("GOT:MARKER")
        }
        let screen = await reader.renderScreen()
        #expect(sawResponse, "screen was: \(screen.debugDescription)")
    }

    // MARK: - Stopping

    /// `stop()` ends the drain and closes the descriptor without touching the
    /// job. That is what makes a later hand-off to an attached viewer possible:
    /// the daemon is the *default* reader, not the owner.
    ///
    /// The close is the delicate half. It happens on the drain thread, woken by
    /// a self-pipe, precisely so no descriptor is ever closed under a blocked
    /// `read` — and `isDraining` reads the thread's own flag, so this asserts
    /// the thread really left rather than that the actor intended it to.
    @Test func stopEndsTheDrainWithoutKillingTheChild() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "printf 'DELTA\\n'; sleep 30")
        defer { fixture.tearDown() }

        let client = fixture.client
        let (_, ptyFD) = try await client.handOverPTY()
        let reader = HolderReader(
            sessionID: fixture.sessionID, ptyFD: ptyFD, columns: 80, rows: 24)
        try await reader.start()
        defer { stopInBackground(reader) }

        let sawMarker = await pollUntil("the job's output before stopping") {
            await reader.renderScreen().contains("DELTA")
        }
        #expect(sawMarker)

        await reader.stop()
        let stillDraining = await reader.isDraining
        #expect(stillDraining == false, "the drain thread outlived stop()")

        // The job is untouched: the holder still owns its own copy of the pty
        // master, so closing the reader's dup destroys nothing.
        let description = try await client.describe()
        #expect(description.status == .alive)
        #expect(description.childPID == fixture.handle.childPID)
        #expect(holderProcessIsAlive(fixture.handle.holderPID))

        // Idempotent, and still not fatal to anything.
        await reader.stop()
        #expect(holderProcessIsAlive(fixture.handle.childPID))
    }

    /// The other branch of `stop()`: a reader that was never started still owns
    /// a `dup` the holder handed over, and stopping it must release that
    /// descriptor. There is no drain thread to hand the close to, so the actor
    /// does it — the one case where that is safe, because nothing can be
    /// mid-read on a descriptor no thread has ever touched.
    ///
    /// The proof is the far end of a pipe reaching end of file, which happens
    /// only when the last writer is gone. Two details of that are load-bearing
    /// and were both learned the hard way:
    ///
    ///   - The ends are made close-on-exec **immediately**. Every test target
    ///     compiles into one process and its suites run concurrently, so a
    ///     neighbouring test that spawns a long-lived child would otherwise
    ///     hand it an inherited copy of the write end, and the pipe would never
    ///     report EOF however correctly the reader behaved. That is not a
    ///     hypothetical: it reddened this test on its third run.
    ///   - The assertion is not `F_GETFD` on the descriptor number. The kernel
    ///     hands out the lowest free number, so a just-closed one is a *likely*
    ///     pick for the next `open` on any of those concurrent threads — an
    ///     assertion about the number would fail exactly when the code was
    ///     right.
    @Test func stoppingAReaderThatNeverStartedReleasesThePTY() async throws {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0, "could not create a pipe")
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        let readEnd = ends[0]
        defer { Darwin.close(readEnd) }
        // Non-blocking, so a reader that failed to release the write end fails
        // the assertion instead of parking the suite in `read`.
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)

        let reader = HolderReader(
            sessionID: UUID(), ptyFD: ends[1], columns: 80, rows: 24)
        let neverDrained = await reader.isDraining
        #expect(neverDrained == false)

        await reader.stop()

        var scratch: UInt8 = 0
        let outcome = Darwin.read(readEnd, &scratch, 1)
        #expect(outcome == 0, "the reader kept the descriptor open (read returned \(outcome))")
    }
}

// MARK: - Support

/// A programmable `read` failure for the drain loop.
///
/// The failures it stands in for — `ENOMEM` above all — cannot be provoked on a
/// healthy machine, and a test that tried to would be measuring the machine
/// rather than the loop. It counts what it injects, because "the fault fired"
/// is the difference between a test that proves retrying happens and one that
/// passes because nothing ever went wrong.
///
/// Consulted on the drain thread while the test reads its counter, so every
/// field is under the lock.
private final class ScriptedReadFault: @unchecked Sendable {
    private let lock = NSLock()
    private let code: Int32
    /// How many reads to fail. `nil` means every read, forever.
    private let budget: Int?
    private var injected = 0

    init(errno code: Int32, times: Int?) {
        self.code = code
        self.budget = times
    }

    var injectedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return injected
    }

    func seam() -> HolderReadFault {
        HolderReadFault { [self] in
            lock.lock()
            defer { lock.unlock() }
            if let budget, injected >= budget { return nil }
            injected += 1
            return code
        }
    }
}

/// Waits for a job to finish exiting, and returns the status the holder
/// collected for it.
///
/// The wait itself is on the **pid disappearing**, not on a status. That is
/// what discriminates: a job wedged in `ttywait` has run its last instruction
/// and still answers `kill(pid, 0)` exactly like a healthy one, because it is
/// stuck inside `proc_exit` and has not been reaped. The pid only goes away
/// once the holder's `waitpid` has collected it, which cannot happen until the
/// exit completes — which cannot happen until somebody drained the terminal.
///
/// Nothing stays connected to the holder while this waits, deliberately. The
/// holder *pushes* a status at a client that happens to be connected when its
/// job exits, and then winds itself down; a poller that raced that push would
/// sometimes collect the status and sometimes find the holder already gone.
/// With no client attached the holder arms its exit-report window instead and
/// waits to be asked, which is the same path a restarted daemon takes.
private func awaitJobExit(
    childPID: Int32,
    reportedBy client: HolderClient,
    timeout: TimeInterval = 25.0
) async -> HolderChildStatus? {
    let reaped = await pollUntil("the job to finish exiting", timeout: timeout) {
        !holderProcessIsAlive(childPID)
    }
    guard reaped else { return nil }
    return try? await client.describe().status
}

/// Stops a reader from a `defer`, which cannot `await`.
///
/// Every test needs this on every exit path — a reader left running leaks a
/// thread and a pty descriptor for the rest of the suite — and a detached task
/// is the only way to reach an actor method from a non-async context. The stop
/// is idempotent, so a test that already stopped its reader loses nothing.
private func stopInBackground(_ reader: HolderReader) {
    Task.detached { await reader.stop() }
}
