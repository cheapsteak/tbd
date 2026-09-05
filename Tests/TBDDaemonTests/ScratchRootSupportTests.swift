import Foundation
import TestSupport
import Testing
@testable import TBDShared

/// Where a fixture's own scratch root is minted, and why it has to be there.
///
/// The defect this pins: roots minted straight under `/tmp` sit outside the
/// directory `scripts/test.sh` deletes from its EXIT trap, so a test process
/// that is killed or crashes — the one case no in-process `tearDown` can cover
/// — leaves them behind permanently. Fifty-three of them accumulated that way.
@Suite("Fenced scratch roots")
struct ScratchRootSupportTests {

    /// A root shaped exactly like the one `scripts/test.sh` mints, so the
    /// budget case below measures the real layout rather than a shorter stand-in.
    private static let runRoot = "/tmp/tbd-test-home.aBcDeFgH"

    @Test func nestsDirectlyUnderTheRunRootWhenTheFenceNamesOne() {
        let path = fencedScratchRoot(
            prefix: "tbdh7", environment: ["TBD_TEST_SCRATCH_ROOT": Self.runRoot])
        #expect((path as NSString).deletingLastPathComponent == Self.runRoot)
        #expect((path as NSString).lastPathComponent.hasPrefix("tbdh7-"))
    }

    /// Two fixtures alive at once must not share a root: one's teardown would
    /// pull the rendezvous socket out from under the other's holder.
    @Test func mintsAFreshRootEachCall() {
        let env = ["TBD_TEST_SCRATCH_ROOT": Self.runRoot]
        #expect(fencedScratchRoot(prefix: "tbdh7", environment: env)
            != fencedScratchRoot(prefix: "tbdh7", environment: env))
    }

    /// An unfenced run — SwiftPM invoked directly rather than through
    /// `scripts/test.sh` — still gets a working root. It is the leaky case, and
    /// deliberately so: the fence is what fixes the leak, not this fallback.
    @Test func fallsBackToTmpWithNoFence() {
        let path = fencedScratchRoot(prefix: "tbdh7", environment: [:])
        #expect((path as NSString).deletingLastPathComponent == "/tmp")
        #expect((path as NSString).lastPathComponent.hasPrefix("tbdh7-"))
    }

    /// THE BUDGET. This is why the root goes under the run root and not under
    /// the fenced `TBD_HOME`, which is `<run root>/sanctioned/tbd`: the
    /// rendezvous socket is `<root>/holders/<36-char uuid>.sock`, and the two
    /// candidate layouts come out at 107 bytes under `TBD_HOME` — 106 for the
    /// shortest prefix in use — against 92 under the run root, for a `sun_path`
    /// that must stay below 104. The rejected layout is not asserted on here:
    /// one honest measurement of the layout actually shipped is the thing that
    /// has to keep holding.
    @Test func aSocketUnderTheRunRootFitsSunPath() throws {
        let home = fencedScratchRoot(
            prefix: "tbdh7", environment: ["TBD_TEST_SCRATCH_ROOT": Self.runRoot])
        let socket = try HolderRendezvous.socketPath(
            sessionID: UUID(), environment: ["TBD_HOME": home])
        #expect(socket.utf8.count < HolderRendezvous.sunPathLimit)
    }
}
