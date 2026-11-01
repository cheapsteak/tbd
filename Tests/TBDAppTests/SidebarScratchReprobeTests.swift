import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: the 60 s cadence runs on `EventDrivenTestClock`, and the scratch
// directory probe answers from a box the test flips as Finder would, so
// nothing touches the disk. The probe's hop off the main thread and back is
// real scheduling, waited on with `pollUntilTrue`.

/// A scratch folder deleted or restored while the app runs dims or brightens
/// its row once the outline probes again — every 60 s, and on app
/// activation — though no scratch space came or went. Parity item 7.
/// Spec: docs/specs/2026-10-31-native-sidebar-design.md, "Parity checklist".
@MainActor
@Suite("Native sidebar scratch re-probe", .clockDriven)
struct SidebarScratchReprobeTests {
    @Test func slowCadenceFollowsAFolderDeletedAndRestored() async throws {
        let folder = ScratchFolder(exists: true)
        let clock = EventDrivenTestClock()
        let h = OutlineHarness("scratchReprobe.cadence", scratchDirectoryProbe: { _ in folder.exists }, clock: clock)
        defer { h.tearDown() }
        let pad = Self.pad()
        h.state.scratchWorktrees = [pad]
        h.mount()

        // The first probe, for a path it has not seen, finds the folder.
        try await Self.waitForProbes(1, in: h)
        h.controller.flushPendingRebuild()
        #expect(Self.isDimmed(pad, in: h) == false)

        // Deleted in Finder. The set of scratch paths is unchanged, so no
        // rebuild probes it again.
        folder.exists = false
        h.state.devServerRunningWorktreeIDs = [pad.id]
        h.controller.flushPendingRebuild()
        #expect(h.controller.scratchProbeCount == 1, "Only the re-probe may read the folder again")
        #expect(Self.isDimmed(pad, in: h) == false)

        // Sixty seconds on, the re-probe sees it gone and the row dims.
        try await clock.requireAdvanceWhenArmed(
            by: SidebarOutlineController.scratchReprobeInterval, timeout: TestDeadlines.saturatedPass)
        try await Self.waitForProbes(2, in: h)
        h.controller.flushPendingRebuild()
        #expect(Self.isDimmed(pad, in: h) == true)

        // Restored: the next re-probe brightens it again.
        folder.exists = true
        try await clock.requireAdvanceWhenArmed(
            by: SidebarOutlineController.scratchReprobeInterval, timeout: TestDeadlines.saturatedPass)
        try await Self.waitForProbes(3, in: h)
        h.controller.flushPendingRebuild()
        #expect(Self.isDimmed(pad, in: h) == false)
    }

    /// What app activation runs: one probe, off the main thread, and a
    /// rebuild only when an answer changed.
    @Test func activationReprobeFollowsAFolderRestored() async throws {
        let folder = ScratchFolder(exists: false)
        // Never advanced, so the 60 s cadence cannot probe in the meantime.
        let clock = EventDrivenTestClock()
        let h = OutlineHarness("scratchReprobe.activation", scratchDirectoryProbe: { _ in folder.exists },
                               clock: clock)
        defer { h.tearDown() }
        let pad = Self.pad()
        h.state.scratchWorktrees = [pad]
        h.mount()
        try await Self.waitForProbes(1, in: h)
        h.controller.flushPendingRebuild()
        #expect(Self.isDimmed(pad, in: h) == true)

        // An answer that did not change rebuilds nothing.
        let builds = h.controller.buildCount
        h.controller.reprobeScratchDirectories()
        try await Self.waitForProbes(2, in: h)
        h.controller.flushPendingRebuild()
        #expect(h.controller.buildCount == builds, "An unchanged answer scheduled a rebuild")

        folder.exists = true
        h.controller.reprobeScratchDirectories()
        try await Self.waitForProbes(3, in: h)
        h.controller.flushPendingRebuild()
        #expect(h.controller.buildCount == builds + 1)
        #expect(Self.isDimmed(pad, in: h) == false)
    }

    // MARK: Fixtures

    /// An unpromoted scratch space, the kind whose missing folder dims it.
    static func pad() -> Worktree {
        Worktree(repoID: nil, name: "pad", displayName: "pad", branch: "", path: "/tmp/acme-pad",
                 tmuxServer: "acme")
    }

    static func isDimmed(_ pad: Worktree, in h: OutlineHarness) -> Bool? {
        SidebarOutlineControllerTests.worktreeModel(h.controller.tree, pad.id)?.isDimmed
    }

    /// Waits until `count` probes have finished: each reads the disk off the
    /// main thread and lands back on it.
    static func waitForProbes(_ count: Int, in h: OutlineHarness) async throws {
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { h.controller.scratchProbeCount >= count }
        }
        guard outcome == .timedOut else { return }
        throw BoundedWaitTimeout(
            what: "\(count) scratch directory probe(s)",
            observed: "\(h.controller.scratchProbeCount) finished", deadline: TestDeadlines.saturatedPass)
    }
}

/// Whether the scratch folder exists, as the test says Finder left it. Read
/// off the main thread by the probe.
private final class ScratchFolder: @unchecked Sendable {
    private let lock = NSLock()
    private var present: Bool

    init(exists: Bool) {
        present = exists
    }

    var exists: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return present
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            present = newValue
        }
    }
}
