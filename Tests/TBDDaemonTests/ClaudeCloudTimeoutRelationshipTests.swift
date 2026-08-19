import Foundation
import Testing
@testable import TBDDaemonLib

// Tier 1: pure constant comparison, no I/O.
//
// Pins the numeric relationship between `RPCRouter.remoteCreateTimeout`
// (`RPCRouter+RemoteHandlers.swift`) and `ClaudeCloudInvoker.pendingFailureWindow`
// (`ClaudeCloudList.swift`). The two live in different files and nothing else
// ties them together mechanically — this test is that mechanism. If a create
// timeout can reach or exceed the pending-failure window, a `create` still
// running past its own timeout budget can have its ledger row reclaimed by
// `claimForSpawn` and re-spawned while the first invocation is still in
// flight: the double-spawn `claude_cloud_session` exists to prevent.
@Suite("ClaudeCloudTimeoutRelationship")
struct ClaudeCloudTimeoutRelationshipTests {
    @Test func createTimeoutStaysStrictlyBelowThePendingFailureWindow() {
        let createTimeout = RPCRouter.remoteCreateTimeout
        let pendingFailureWindow = ClaudeCloudInvoker.pendingFailureWindow
        #expect(
            createTimeout < pendingFailureWindow,
            """
            RPCRouter.remoteCreateTimeout (\(createTimeout)s) must stay strictly \
            below ClaudeCloudInvoker.pendingFailureWindow (\(pendingFailureWindow)s): \
            a single create invocation must give up and throw well before the ledger \
            gives up on its row — otherwise `claimForSpawn` can reclaim and re-spawn \
            a `pending` row whose original create is still running past its own \
            timeout budget, spawning a second real cloud session under the same \
            idempotency key.
            """)
    }
}
