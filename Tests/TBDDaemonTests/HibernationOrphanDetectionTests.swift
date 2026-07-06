import Foundation
import Testing
@testable import TBDDaemonLib

/// Regression coverage for the hibernate-path `ps` deadlock: the original
/// `detectOrphanedClaudeProcesses` spawned `/bin/ps -Ao pid=,ppid=,comm=`,
/// called `waitUntilExit()` FIRST, and only then read the pipe. A macOS pipe
/// buffer is 64KB; with ~900+ processes `ps` emits more, blocks writing to the
/// full pipe, and both sides deadlock forever — hanging every hibernation (and
/// every test touching the hibernate path). The fix routes the call through the
/// shared bounded runner, which drains stdout concurrently and enforces a
/// timeout. These tests drive the package-internal seam with a fake `ps`.
@Suite("Hibernation orphan detection")
struct HibernationOrphanDetectionTests {
    @Test func enumerationCompletesWhenPsOutputExceedsPipeBuffer() async {
        // Fake `ps` deterministically emits ~110KB (5000 filler rows well over
        // the 64KB pipe buffer) plus one orphaned-claude row (ppid 1). Before
        // the fix this call never returned; now it must complete and still
        // parse the orphan out of the oversized output.
        let script = """
        awk 'BEGIN { for (i = 0; i < 5000; i++) printf "%d %d some-process\\n", 10000 + i, 500; \
        print "424242 1 claude" }'
        """
        let orphans = await HibernationCoordinator.detectOrphanedClaudeProcesses(
            psExecutable: "/bin/sh",
            arguments: ["-c", script],
            timeout: .seconds(10)
        )
        #expect(orphans == [424242])
    }

    @Test func enumerationIsBoundedByTimeoutWhenPsHangs() async {
        // Best-effort, log-only diagnostic: a wedged `ps` must never block
        // hibernation. A child that never exits yields nil (timeout swallowed),
        // not a hang. Outcome-only assertion — no wall-clock timing (CI load).
        let orphans = await HibernationCoordinator.detectOrphanedClaudeProcesses(
            psExecutable: "/bin/sleep",
            arguments: ["30"],
            timeout: .milliseconds(100)
        )
        #expect(orphans == nil)
    }

    @Test func enumerationParsesRealPsShapedOutput() async {
        // Happy-path parse: pid/ppid/comm rows, only ppid==1 rows whose comm
        // contains "claude" count; everything else (including a claude child
        // with a live parent) is ignored.
        let script = """
        printf '  101 1 /usr/bin/claude\\n  202 500 claude\\n  303 1 /bin/zsh\\n  404 1 claude-code\\n'
        """
        let orphans = await HibernationCoordinator.detectOrphanedClaudeProcesses(
            psExecutable: "/bin/sh",
            arguments: ["-c", script],
            timeout: .seconds(10)
        )
        #expect(orphans == [101, 404])
    }
}
