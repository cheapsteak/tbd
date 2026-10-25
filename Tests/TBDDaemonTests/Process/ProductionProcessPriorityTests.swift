import Darwin
import Foundation
import Testing
import TestSupport

@testable import TBDDaemonLib

/// The one test that touches real processes: a small `sh` tree is lowered and
/// restored through the production seam, and the state is read back from the
/// kernel's base priority.
@Suite("ProductionProcessPriority")
struct ProductionProcessPriorityTests {

    @Test func aRealTreeIsLoweredReadBackAndRestored() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Sleeps far longer than any test pass, so a starved runner cannot see
        // the tree exit before it is read. `tearDown` kills it.
        process.arguments = ["-c", "sleep 600 & sleep 600 & wait"]
        try process.run()
        let root = process.processIdentifier
        // Not a `defer`: the teardown's wait has to suspend, and a `defer`
        // cannot. Both exits reach it, so a failed `#require` still kills the
        // tree.
        do {
            try await lowerReadBackAndRestore(root)
        } catch {
            await tearDown(process, root: root)
            throw error
        }
        await tearDown(process, root: root)
    }

    @Test func aGonePidReadsAsNothing() {
        let seam = ProductionProcessPriority()
        #expect(seam.basePriority(of: 2_000_000_000) == nil)
        #expect(seam.startTimeMicros(of: 2_000_000_000) == nil)
        #expect(seam.subtree(of: 2_000_000_000).isEmpty)
        #expect(seam.lowerToBackground(0) == false)
    }

    private func lowerReadBackAndRestore(_ root: pid_t) async throws {
        let seam = ProductionProcessPriority()

        // The shell forks its two sleeps just after it starts.
        let started = ContinuousClock.now
        switch await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, { seam.subtree(of: root).count == 3 }) {
        case .satisfied: break
        case .cancelled: throw CancellationError()
        case .timedOut:
            throw TreeWaitFailure(
                what: "sh \(root) to show itself and its two sleeps",
                observed: "subtree \(seam.subtree(of: root))",
                elapsed: ContinuousClock.now - started)
        }
        let tree = seam.subtree(of: root)
        try #require(tree.count == 3)
        #expect(tree.first == root)

        for pid in tree { #expect((seam.basePriority(of: pid) ?? 0) > ProductionProcessPriority.backgroundCeiling) }
        let starts = tree.map { seam.startTimeMicros(of: $0) }
        #expect(starts.allSatisfy { $0 != nil })

        for pid in tree { #expect(seam.lowerToBackground(pid)) }
        for pid in tree { #expect(seam.basePriority(of: pid) == 4) }
        for pid in tree { #expect(seam.isBackground(pid) == true) }

        for pid in tree { #expect(seam.restore(pid)) }
        for pid in tree { #expect((seam.basePriority(of: pid) ?? 0) > 4) }
        #expect(tree.map { seam.startTimeMicros(of: $0) } == starts, "start times do not move")
        #expect(seam.parentPID(of: tree[1]) == root)
    }

    /// Kills the tree whatever the walk finds, then waits, bounded, for
    /// Foundation to reap the shell.
    ///
    /// **The kill does not depend on `subtree(of:)`.** Foundation spawns a
    /// child into a new process group, so the shell leads its own group and its
    /// sleeps inherit it: one signal to the group reaches all three. The group is
    /// signalled only while it is provably the shell's — `isRunning` means
    /// Foundation has not reaped the shell, so its pid, and the group named
    /// after it, cannot belong to anyone else. Should a Foundation change ever
    /// leave the shell in the test runner's group, the fallback signals the pids
    /// the walk found, children first, and then the shell itself even when the
    /// walk found nothing. At worst the sleeps are orphaned to launchd; the
    /// wait below is for the shell alone, so it never waits them out.
    ///
    /// **The wait is never `process.waitUntilExit()`.** This runs after an
    /// `await`, so it may be on a different cooperative thread from the one
    /// that called `run()`, and from there Foundation's wait can poll its run
    /// loop forever with the shell already reaped — the hang
    /// `BoundedProcessTeardown` in `TBDDaemonLiveTests` documents, with
    /// `scripts/diag/nstask-waituntilexit-stale-entry.swift` as its repro.
    /// `isRunning` turns false only after Foundation's own `waitpid` has
    /// collected the shell, so polling it is a reap proof that blocks no
    /// thread.
    private func tearDown(_ process: Process, root: pid_t) async {
        let seam = ProductionProcessPriority()
        // Read before anything is signalled, so every pid it names is still
        // alive and still in this tree.
        let tree = seam.subtree(of: root)
        var signalled = "nothing: the shell had already exited"
        // `root > 1`, so neither signal below can become `kill(0, …)` (the
        // test runner's own group), `kill(-1, …)` (every process this user
        // owns) or a signal to launchd.
        if root > 1, process.isRunning {
            if getpgid(root) == root {
                kill(-root, SIGKILL)
                signalled = "process group \(root)"
            } else {
                for pid in tree.reversed() { kill(pid, SIGKILL) }
                if !tree.contains(root) { kill(root, SIGKILL) }
                signalled = "the walk's pids \(tree), children first, and the shell"
            }
        }

        let started = ContinuousClock.now
        guard case .timedOut = await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(50), { !process.isRunning })
        else { return }
        let probe = kill(root, 0)
        let probeErrno = errno
        let alive = probe == 0 ? "answers kill(pid, 0)" : "kill(pid, 0) errno \(probeErrno)"
        Issue.record(TreeWaitFailure(
            what: "Foundation to reap sh \(root) after SIGKILL to \(signalled)",
            observed: "isRunning still true, the shell \(alive), subtree before the kill \(tree), "
                + "subtree now \(seam.subtree(of: root))",
            elapsed: ContinuousClock.now - started))
    }
}

/// Carries what a bounded wait saw on the primary failure line (assertion-hygiene
/// rule 4 in `Tests/CLAUDE.md`: only `Issue.record(_: some Error)`, which a thrown
/// error becomes, survives into the CI summary).
private struct TreeWaitFailure: Error, CustomStringConvertible {
    let what: String
    let observed: String
    let elapsed: Duration
    var description: String {
        "timed out waiting for \(what) — observed \(observed) after \(elapsed)"
    }
}
