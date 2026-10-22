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
        process.arguments = ["-c", "sleep 30 & sleep 30 & wait"]
        try process.run()
        let root = process.processIdentifier
        defer {
            // Kill the children before the shell, so none is orphaned.
            let seam = ProductionProcessPriority()
            for pid in seam.subtree(of: root).reversed() { kill(pid, SIGKILL) }
            process.waitUntilExit()
        }
        let seam = ProductionProcessPriority()

        // The shell forks its two sleeps just after it starts.
        let forked = await pollUntilTrue(timeout: .seconds(10)) { seam.subtree(of: root).count == 3 }
        #expect(forked == .satisfied)
        let tree = seam.subtree(of: root)
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

    @Test func aGonePidReadsAsNothing() {
        let seam = ProductionProcessPriority()
        #expect(seam.basePriority(of: 2_000_000_000) == nil)
        #expect(seam.startTimeMicros(of: 2_000_000_000) == nil)
        #expect(seam.subtree(of: 2_000_000_000).isEmpty)
        #expect(seam.lowerToBackground(0) == false)
    }
}
