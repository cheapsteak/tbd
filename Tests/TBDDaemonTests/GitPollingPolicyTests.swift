import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// MARK: - Cadence selection (foreground gate)

@Suite("GitPollCadence Tests")
struct GitPollCadenceTests {

    @Test func statusIntervalForegroundIsFast() {
        #expect(GitPollCadence.statusInterval(isForeground: true) == .seconds(10))
    }

    @Test func statusIntervalBackgroundIsSlow() {
        #expect(GitPollCadence.statusInterval(isForeground: false) == .seconds(60))
    }

    @Test func fetchIntervalForegroundIsFast() {
        #expect(GitPollCadence.fetchInterval(isForeground: true) == .seconds(60))
    }

    @Test func fetchIntervalBackgroundIsSlow() {
        #expect(GitPollCadence.fetchInterval(isForeground: false) == .seconds(300))
    }
}

// MARK: - AppForegroundState

@Suite("AppForegroundState Tests")
struct AppForegroundStateTests {

    @Test func defaultsToBackground() async {
        // A freshly started daemon has no app attached — it must idle at the
        // background cadence until an app reports otherwise.
        let state = AppForegroundState()
        #expect(await state.isForeground == false)
    }

    @Test func setForegroundThenBackground() async {
        let state = AppForegroundState()
        await state.set(isForeground: true)
        #expect(await state.isForeground == true)
        await state.set(isForeground: false)
        #expect(await state.isForeground == false)
    }
}

// MARK: - ConflictSweepCache (dirty gate)

@Suite("ConflictSweepCache Tests")
struct ConflictSweepCacheTests {

    private let id = UUID()
    private let key = ConflictSweepCache.Key(branchTip: "aaa", baseTip: "bbb")

    @Test func firstSightingRequiresCheck() async {
        let cache = ConflictSweepCache()
        #expect(await cache.shouldCheck(worktreeID: id, key: key) == true)
    }

    @Test func unchangedPairSkipsCheck() async {
        let cache = ConflictSweepCache()
        await cache.markChecked(worktreeID: id, key: key)
        #expect(await cache.shouldCheck(worktreeID: id, key: key) == false)
    }

    @Test func movedBranchTipInvalidates() async {
        let cache = ConflictSweepCache()
        await cache.markChecked(worktreeID: id, key: key)
        let moved = ConflictSweepCache.Key(branchTip: "ccc", baseTip: "bbb")
        #expect(await cache.shouldCheck(worktreeID: id, key: moved) == true)
    }

    @Test func movedBaseTipInvalidates() async {
        let cache = ConflictSweepCache()
        await cache.markChecked(worktreeID: id, key: key)
        let moved = ConflictSweepCache.Key(branchTip: "aaa", baseTip: "ddd")
        #expect(await cache.shouldCheck(worktreeID: id, key: moved) == true)
    }

    @Test func invalidationIsPerWorktree() async {
        let cache = ConflictSweepCache()
        let otherID = UUID()
        await cache.markChecked(worktreeID: id, key: key)
        // A different worktree with the same pair still needs its own check.
        #expect(await cache.shouldCheck(worktreeID: otherID, key: key) == true)
        // ...and checking it doesn't disturb the first worktree's entry.
        await cache.markChecked(worktreeID: otherID, key: key)
        #expect(await cache.shouldCheck(worktreeID: id, key: key) == false)
    }

    @Test func retainPrunesRemovedWorktrees() async {
        let cache = ConflictSweepCache()
        let keptID = UUID()
        await cache.markChecked(worktreeID: id, key: key)
        await cache.markChecked(worktreeID: keptID, key: key)
        await cache.retain(worktreeIDs: [keptID])
        #expect(await cache.shouldCheck(worktreeID: id, key: key) == true)
        #expect(await cache.shouldCheck(worktreeID: keptID, key: key) == false)
    }
}

// MARK: - RPC wiring

extension RPCRouterTests {

    @Test("app.setForegroundState updates the shared foreground gate")
    func appSetForegroundStateUpdatesGate() async throws {
        let gate = AppForegroundState()
        router.appForegroundState = gate
        #expect(await gate.isForeground == false)

        let toForeground = try RPCRequest(
            method: RPCMethod.appSetForegroundState,
            params: AppSetForegroundStateParams(isForeground: true)
        )
        #expect(await router.handle(toForeground).success)
        #expect(await gate.isForeground == true)

        let toBackground = try RPCRequest(
            method: RPCMethod.appSetForegroundState,
            params: AppSetForegroundStateParams(isForeground: false)
        )
        #expect(await router.handle(toBackground).success)
        #expect(await gate.isForeground == false)
    }
}
