import Foundation
import Testing
@testable import TBDDaemonLib

/// Where a real holder fixture actually puts its scratch root, and that the
/// root goes away again.
///
/// **Tier 3**: it spawns a real `TBDHolder` through the real `HolderSpawner`,
/// like every other suite in this directory.
///
/// The unit-level properties of `fencedScratchRoot(prefix:environment:)` are
/// pinned in `TBDDaemonTests`. This suite exists because those say nothing
/// about the fixture: `scratchHome()` reads the *process* environment, so only
/// a run under `scripts/test.sh` can show that the root a live fixture creates
/// is the one the wrapper's EXIT trap will reclaim if this process is killed.
@Suite(.serialized)
struct HolderFixtureScratchRootTests {

    @Test func scratchRootSitsUnderTheRunsReclaimedRoot() async throws {
        let fixture = try await HolderProcessFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }

        // Under the wrapper this is the directory `trap cleanup EXIT` deletes;
        // outside it there is no fence and `/tmp` is all the fixture can use.
        let expectedRoot = ProcessInfo.processInfo.environment["TBD_TEST_SCRATCH_ROOT"] ?? "/tmp"
        #expect((fixture.home as NSString).deletingLastPathComponent == expectedRoot)
        #expect(FileManager.default.fileExists(atPath: fixture.home))
    }

    /// The in-process half still has to work: the fence covers the runs that
    /// never reach a teardown, not the ordinary ones.
    @Test func tearDownRemovesTheScratchRoot() async throws {
        let fixture = try await HolderProcessFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }

        let home = fixture.home
        #expect(FileManager.default.fileExists(atPath: home))
        fixture.tearDown()
        #expect(!FileManager.default.fileExists(atPath: home))
    }
}
