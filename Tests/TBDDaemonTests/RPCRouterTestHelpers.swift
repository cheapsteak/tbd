import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Shared test fixture for all RPCRouter-* test files.
///
/// Each `@Test` method declared in an extension of this `@Suite` struct gets
/// its own instance, so `db` and `router` are isolated per test. The router
/// is wired with `dryRun=true` tmux so no real tmux server is contacted.
@Suite("RPCRouter Tests")
struct RPCRouterTests {
    let db: TBDDatabase
    let router: RPCRouter

    init() throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date()
        )
    }
}
