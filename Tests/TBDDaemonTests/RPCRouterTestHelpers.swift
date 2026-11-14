import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TestSupport

/// Shared test fixture for all RPCRouter-* test files.
///
/// Each `@Test` method declared in an extension of this `@Suite` struct gets
/// its own instance, so `db`, `router` and `holder` are isolated per test. The
/// router is wired with `dryRun=true` tmux so no real tmux server is
/// contacted, and with the holder spawn double, so every session it opens
/// lands on the holder transport without starting a process.
@Suite("RPCRouter Tests")
struct RPCRouterTests {
    let db: TBDDatabase
    let router: RPCRouter
    /// Every spawn the router makes, through `terminal.create` or worktree
    /// creation alike, is recorded here. Wired into both the router and its
    /// lifecycle, since `RPCRouter.lifecycle` is a copy.
    let holder: FakeHolderLaunch

    init() throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        let holder = FakeHolderLaunch()
        self.holder = holder
        let registry = makeHolderRegistryDouble(launch: holder)
        var lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )
        lifecycle.holderRegistry = registry
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
        router.holderRegistry = registry
        self.router = router
    }
}
