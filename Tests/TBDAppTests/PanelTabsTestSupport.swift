import Foundation
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

// Tier 1: deterministic, in-process state only. Every daemon hop goes through
// an injected seam, so no socket is opened, and every `AppState` gets its own
// `UserDefaults` suite so the developer's real `TBDApp.plist` is never touched.

/// Fixtures shared by the panel-tabs app suites: an `AppState` whose panel
/// seams fail loudly unless a test stubs them, surface and tab builders, and
/// the collectors the stubs record into.
@MainActor
enum PanelTabsFixture {

    /// Thrown by a seam the test did not stub, after recording an issue.
    struct UnstubbedSeam: LocalizedError {
        let seam: String
        var errorDescription: String? { "the test reached the unstubbed seam \(seam)" }
    }

    /// A rejection a stub throws on purpose, with the text a toast shows.
    struct Rejected: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs `body` against an `AppState` on a throwaway defaults suite.
    static func withState(
        _ body: @MainActor (AppState) async throws -> Void
    ) async rethrows {
        let suite = TestDefaultsSuite("PanelTabsTests")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        state.panelApplyTrigger = { @MainActor _ in
            Issue.record("unexpected panel.apply")
            throw UnstubbedSeam(seam: "panel.apply")
        }
        state.panelGetFetcher = { @MainActor _ in
            Issue.record("unexpected panel.get")
            throw UnstubbedSeam(seam: "panel.get")
        }
        state.panelSyncTrigger = { @MainActor _ in
            Issue.record("unexpected panel.syncTabs")
            throw UnstubbedSeam(seam: "panel.syncTabs")
        }
        try await body(state)
    }

    // MARK: - Builders

    static func surface(
        tabID: UUID, worktreeID: UUID, revision: UInt64, label: String? = nil
    ) -> WorkspaceTabSurface {
        WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, label: label,
            primary: .terminal(terminalID: tabID), revision: revision)
    }

    static func delta(
        worktreeID: UUID, tabs: [WorkspaceTabSurface] = [], removed: [UUID] = [],
        activeTabID: UUID? = nil
    ) -> PanelSurfaceDelta {
        PanelSurfaceDelta(
            worktreeID: worktreeID, tabs: tabs, removedTabIDs: removed,
            activeTabID: activeTabID, originOperationID: nil)
    }

    static func terminalTab(label: String? = nil) -> TBDShared.Tab {
        let id = UUID()
        return TBDShared.Tab(id: id, content: .terminal(terminalID: id), label: label)
    }

    static var emptySyncResult: PanelSyncTabsResult { syncResult() }

    /// A sync result that names `skippedTabIDs` as left without a surface.
    static func syncResult(skipping skippedTabIDs: [UUID] = []) -> PanelSyncTabsResult {
        PanelSyncTabsResult(
            importedTabIDs: [], reparentedTabIDs: [], removedTabIDs: [],
            skippedTabIDs: skippedTabIDs,
            skipped: skippedTabIDs.map { "tab \($0.uuidString): skipped by the test" })
    }

    // MARK: - Collectors

    /// Stubs `panel.syncTabs` to record every payload it is sent.
    static func collectSyncs(_ state: AppState, into log: PanelEventLog? = nil) -> PanelSyncCollector {
        let collector = PanelSyncCollector()
        state.panelSyncTrigger = { @MainActor params in
            collector.record(params)
            log?.record("sync \(params.worktreeID)")
            return PanelTabsFixture.emptySyncResult
        }
        return collector
    }

    /// Stubs `panel.get` to answer `reply` and record each worktree asked for.
    static func collectGets(
        _ state: AppState, into log: PanelEventLog? = nil,
        reply: @escaping @MainActor (UUID) -> PanelGetResult
    ) -> PanelGetCollector {
        let collector = PanelGetCollector()
        state.panelGetFetcher = { @MainActor worktreeID in
            collector.record(worktreeID)
            log?.record("get \(worktreeID)")
            return reply(worktreeID)
        }
        return collector
    }

    /// Stubs `panel.apply` to record each envelope and answer `tab`.
    static func collectEnvelopes(
        _ state: AppState, replying tab: WorkspaceTabSurface
    ) -> PanelEnvelopeCollector {
        let collector = PanelEnvelopeCollector()
        state.panelApplyTrigger = { @MainActor envelope in
            collector.record(envelope)
            return PanelApplyResult(tab: tab, replayed: false)
        }
        return collector
    }

    /// Stubs the daemon's state stream (`deltaSubscriber`): a subscribe call
    /// stays open until the test ends it, and the daemon acknowledges it only
    /// when the test says so.
    static func stubSubscription(_ state: AppState) -> PanelSubscriptionStub {
        let stub = PanelSubscriptionStub()
        state.deltaSubscriber = { @MainActor onConnected, _ in
            await stub.serve(onRegistered: onConnected)
        }
        return stub
    }

    /// The one element a step was supposed to produce. Fails cleanly, naming
    /// everything that arrived, rather than indexing off the end of an array.
    static func single<Element>(
        _ elements: [Element], sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Element {
        try #require(
            elements.count == 1 ? elements.first : nil,
            "expected exactly one, observed \(elements.count): \(elements)",
            sourceLocation: sourceLocation)
    }

    /// Lets the main-actor `Task`s the code under test enqueued run to
    /// completion. The test body holds the main actor, so handing it back is
    /// all the synchronization needed: no clock and no sleep. Every stub here
    /// answers without suspending, so the chains it drains are a few hops deep.
    static func drainMainActor() async {
        for _ in 0..<64 { await Task.yield() }
    }

    /// A worktree with `tabs` whose tab sources have both been reconciled, with
    /// whatever sync that produced already drained and forgotten.
    static func readyWorktree(
        _ state: AppState, tabs: [TBDShared.Tab], syncs: PanelSyncCollector
    ) async -> UUID {
        let worktreeID = UUID()
        state.tabs[worktreeID] = tabs
        state.markPanelSyncReady(worktreeIDs: [worktreeID])
        await drainMainActor()
        syncs.reset()
        return worktreeID
    }
}

/// Every `panel.syncTabs` payload, in the order sent.
@MainActor
final class PanelSyncCollector {
    private(set) var sent: [PanelSyncTabsParams] = []
    func record(_ params: PanelSyncTabsParams) { sent.append(params) }
    func reset() { sent.removeAll() }
}

/// Every worktree `panel.get` was asked for, in order.
@MainActor
final class PanelGetCollector {
    private(set) var worktreeIDs: [UUID] = []
    func record(_ worktreeID: UUID) { worktreeIDs.append(worktreeID) }
}

/// Every `panel.apply` envelope, in order.
@MainActor
final class PanelEnvelopeCollector {
    private(set) var envelopes: [PanelOperationEnvelope] = []
    func record(_ envelope: PanelOperationEnvelope) { envelopes.append(envelope) }
}

/// Holds a stubbed seam's call until the test releases it, so a test can act
/// while that call is in flight. Once released it lets every later call
/// straight through. Main-actor isolated rather than a semaphore, so nothing
/// blocks a thread (`Tests/CLAUDE.md`, "Thread-blocking gates").
@MainActor
final class PanelCallGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    /// A call is parked here now.
    var isHolding: Bool { waiter != nil }

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

/// The daemon's end of a state subscription, for `PanelTabsFixture.stubSubscription`.
/// Holds each subscribe call open on a gate, so the subscription stays in
/// flight until `end()`, and calls the app's registration callback when the
/// test plays the daemon's ack with `register()`.
@MainActor
final class PanelSubscriptionStub {
    private var onRegistered: (@Sendable () -> Void)?
    private let stream = PanelCallGate()

    /// A subscribe call is open.
    var isOpen: Bool { stream.isHolding }

    func serve(onRegistered: @escaping @Sendable () -> Void) async {
        self.onRegistered = onRegistered
        await stream.wait()
    }

    /// The daemon's ack: the open subscription is registered.
    func register() {
        onRegistered?()
    }

    /// Ends the open subscribe call, and lets any later one return at once.
    func end() {
        stream.release()
    }
}

/// One ordered log across several seams, for tests that pin the order of
/// calls to different RPCs.
@MainActor
final class PanelEventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}
