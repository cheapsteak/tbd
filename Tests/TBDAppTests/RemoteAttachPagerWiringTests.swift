import AppKit
import Foundation
import Testing
import TestSupport
@testable import TBDApp
import TBDShared

// Tier 1: deterministic, in-process state and bare AppKit objects. No
// subprocess, no network, no clock — the one suspension point is a main-queue
// hop, which is an ordering guarantee rather than a wait (see
// `drainMainQueue`).

/// `RemoteAttachPager`'s glue (#884) — the wiring between a mount key, the
/// terminal it builds, and the three `AppState` reports that wiring produces.
///
/// **What this pins that nothing else does.** `RemoteAttachNetworkRecoveryTests`
/// drives every `AppState` mutator directly, with generations and dates it
/// chose; none of them touches the pager, which is what decides *which*
/// generation each report carries and *whether* a removed tab reports at all.
/// Drop `onStarted`'s generation, hand `onDetached` the wrong one, or delete
/// the deferred `markRemoteAttachUnmounted` from the removal loop, and that
/// suite stays entirely green while the feature reports against the wrong
/// child — or, for the unmount, reports nothing and leaves a start time
/// outliving the child it dates.
///
/// **Why it calls the two statics rather than `updateNSViewController`.** That
/// method takes a SwiftUI `Context`, which has no public initializer, so no
/// test can call it. `makeTerminalView` and `reconcile` are the whole of its
/// body, extracted for exactly this reason; what stays untested is the
/// three-line call that joins them plus the `NSHostingController` wrap.
///
/// **Why the tab items are bare.** `reconcile`'s contract is the mount-set
/// diff and the identifier each item carries, and it takes `makeItem` as a
/// parameter precisely so a test can supply an item with no hosting
/// controller behind it. Building the production item instead would resolve
/// `UserDefaults.standard` (through `AppearanceSettings` and
/// `AppState.metalTerminalRendererEnabled()`) — on this unbundled executable
/// that is the developer's real `TBDApp.plist` (root `CLAUDE.md`, "Tests must
/// not touch ~/tbd") — and put a real provider `attach` spawn behind a tier-1
/// test.
///
/// The seeding helpers mirror `RemoteAttachNetworkRecoveryTests`'s, copied
/// rather than shared so that suite's assertions stay exactly as they were.
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite, for the same `TBDApp.plist` reason.
///
/// `.fastPassBounded` because two tests suspend; see it in
/// `Tests/TestSupport/ClockTestSupport.swift`.
@MainActor
@Suite("Remote attach pager wiring", .fastPassBounded)
struct RemoteAttachPagerWiringTests {
    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.RemoteAttachPagerWiring.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    /// The same fixture for a body that has to suspend. Named apart from
    /// `withState` rather than overloaded on `async`, so which one a call site
    /// gets is never a question of inference.
    private func withStateAsync(_ body: (AppState) async -> Void) async {
        let suiteName = "TBDAppTests.RemoteAttachPagerWiring.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await body(AppState(userDefaults: defaults))
    }

    /// The provider config the pager would look up for `providerName`. It
    /// reaches `RemoteAttachTerminalView` as the argv source and nothing in
    /// this suite spawns it.
    private static let providerName = "acme"
    private static let providerConfig = RemoteProviderConfig(name: "acme", exec: "/usr/bin/true")

    private func seedProvider(_ state: AppState, health: ProviderHealth = .ok) {
        state.remoteProviders = state.remoteProviders.filter { $0.config.name != Self.providerName } + [
            RemoteProviderStatus(
                config: Self.providerConfig,
                describe: ProviderDescribe(name: Self.providerName, capabilities: ["attach", "log"]),
                health: health, errorMessage: nil, remediationLabel: nil, remediationCommand: nil
            )
        ]
    }

    private func seedSession(_ state: AppState, id: String) {
        state.remoteSessions = state.remoteSessions.filter {
            !($0.provider == Self.providerName && $0.payload.id == id)
        } + [
            RemoteSessionInfo(
                provider: Self.providerName,
                payload: RemoteSessionPayload(id: id, state: .running),
                gone: false, dismissed: false, lastSeen: Date()
            )
        ]
    }

    private func sel(_ id: String) -> RemoteSessionSelection {
        RemoteSessionSelection(provider: Self.providerName, sessionID: id)
    }

    /// Seeds one attach-capable session and attaches it, so it is mounted.
    private func attached(_ state: AppState, id: String = "s1") -> RemoteSessionSelection {
        seedProvider(state)
        seedSession(state, id: id)
        state.selectRemoteSession(provider: Self.providerName, sessionID: id, reattach: true)
        return sel(id)
    }

    private func key(_ selection: RemoteSessionSelection, _ generation: Int) -> RemoteAttachMountKey {
        RemoteAttachMountKey(selection: selection, generation: generation)
    }

    /// The tab view controller `makeNSViewController` builds, minus the
    /// `Context` it takes. The two settings are production's, so the items
    /// this suite adds land in the same tab style and transition mode they do
    /// in the app.
    private func makeTabViewController() -> NSTabViewController {
        let vc = NSTabViewController()
        vc.tabStyle = .unspecified
        vc.transitionOptions = []
        return vc
    }

    /// A tab item with nothing behind it but an already-materialized empty
    /// view — the stand-in for the production `NSHostingController` (see the
    /// suite comment). The view is assigned rather than left to `loadView`,
    /// so selecting the item can never reach a nib lookup.
    private func plainItem(for key: RemoteAttachMountKey) -> NSTabViewItem {
        let host = NSViewController()
        host.view = NSView(frame: .zero)
        let item = NSTabViewItem(viewController: host)
        item.identifier = key
        return item
    }

    /// Lets the main queue run one turn. `reconcile` defers each unmount
    /// report with `DispatchQueue.main.async`; the main queue is serial and
    /// FIFO, so a block enqueued after `reconcile` returns runs after those
    /// reports have run. That makes this an ordering guarantee rather than a
    /// poll — there is no window here to mistake for a bug. Suspending is also
    /// the only thing that hands the queue back to be drained at all
    /// (`Tests/CLAUDE.md`, "`@MainActor` tests: suspend to drain, never
    /// pump").
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: - The spawn report

    /// The pager is the only thing that decides which generation a spawn is
    /// reported under. Reddens if `makeTerminalView` stops closing over the
    /// key's generation — passing `0`, or reading
    /// `appState.remoteAttachGeneration(for:)` at report time, which would
    /// make a superseded child's late report date the live one.
    @Test("onStarted records the spawn under the key's generation")
    func onStartedRecordsTheSpawnUnderTheKeysGeneration() {
        withState { state in
            let s1 = attached(state)
            state.reconnectRemoteSession(s1)
            #expect(state.remoteAttachGeneration(for: s1) == 1)
            let spawnedAt = Date()

            let live = RemoteAttachPager.makeTerminalView(
                for: key(s1, 1), provider: Self.providerConfig, appState: state)
            live.onStarted(spawnedAt)

            #expect(state.remoteAttachStartedAt(for: s1) == spawnedAt)

            // The superseded key's own view: its child was killed by the swap,
            // and a late report from it must not re-date the live child.
            let superseded = RemoteAttachPager.makeTerminalView(
                for: key(s1, 0), provider: Self.providerConfig, appState: state)
            superseded.onStarted(spawnedAt.addingTimeInterval(60))

            #expect(state.remoteAttachStartedAt(for: s1) == spawnedAt)
        }
    }

    // MARK: - The exit report

    /// Same wiring on the exit side. Reddens if `onDetached` stops carrying
    /// the key's generation: a superseded child's exit would put the live
    /// child's session into reconnect backoff, unmounting the pane that
    /// replaced it.
    @Test("onDetached reports the exit under the key's generation")
    func onDetachedReportsTheExitUnderTheKeysGeneration() {
        withState { state in
            let s1 = attached(state)

            let live = RemoteAttachPager.makeTerminalView(
                for: key(s1, 0), provider: Self.providerConfig, appState: state)
            live.onDetached(255)

            #expect(state.pendingReconnectRemoteSessions[s1] != nil)
        }

        // A fresh state, so the pending entry below can only have come from
        // the superseded view's own report.
        withState { state in
            let s1 = attached(state)
            state.reconnectRemoteSession(s1)

            let superseded = RemoteAttachPager.makeTerminalView(
                for: key(s1, 0), provider: Self.providerConfig, appState: state)
            superseded.onDetached(255)

            #expect(state.pendingReconnectRemoteSessions[s1] == nil, "the corpse's exit is dropped whole")
        }
    }

    // MARK: - The mount-set diff

    /// The removal loop's report is the only thing that tells `AppState` a
    /// child died without an exit being reported — the dismantle terminates it
    /// with its own exit callback suppressed. Reddens if the deferred
    /// `markRemoteAttachUnmounted` is dropped: the start time would outlive
    /// the child it dates, and the next network change would "restart" a pane
    /// with nothing running behind it.
    @Test("reconcile mounts a key, unmounts one that left, and reports the unmount")
    func reconcileMountsAndUnmountsAndReportsTheUnmount() async {
        await withStateAsync { state in
            let s1 = attached(state)
            let key0 = key(s1, 0)
            let spawnedAt = Date().addingTimeInterval(-60)
            state.markRemoteAttachStarted(s1, generation: 0, at: spawnedAt)
            let vc = makeTabViewController()

            RemoteAttachPager.reconcile(
                vc, mounts: [key0], activeSelection: nil, appState: state, makeItem: { plainItem(for: $0) })

            #expect(vc.tabViewItems.count == 1)
            #expect(vc.tabViewItems.first?.identifier as? RemoteAttachMountKey == key0)

            RemoteAttachPager.reconcile(
                vc, mounts: [], activeSelection: nil, appState: state, makeItem: { plainItem(for: $0) })

            #expect(vc.tabViewItems.isEmpty)
            #expect(state.remoteAttachStartedAt(for: s1) == spawnedAt,
                    "the report is deferred a main-queue turn, so it cannot have landed yet")

            await drainMainQueue()

            #expect(state.remoteAttachStartedAt(for: s1) == nil)
            #expect(state.remoteAttachGeneration(for: s1) == 0, "an unmount supersedes nothing")
        }
    }

    /// A reconnect's swap is one diff, not two: the superseded key's item is
    /// removed in the same call that adds the replacement's. Reddens if the
    /// removal loop stops keying on the generation (the old item would survive
    /// and the pane would own two live children), and equally if the deferred
    /// unmount stops carrying the key's generation — the old key's teardown
    /// would then erase the replacement child's start, which is recorded here
    /// before the hop for exactly that reason.
    @Test("reconcile replaces an item whose generation changed")
    func reconcileReplacesAnItemWhoseGenerationChanged() async {
        await withStateAsync { state in
            let s1 = attached(state)
            let vc = makeTabViewController()

            RemoteAttachPager.reconcile(
                vc, mounts: [key(s1, 0)], activeSelection: nil, appState: state,
                makeItem: { plainItem(for: $0) })
            #expect(vc.tabViewItems.count == 1)

            state.reconnectRemoteSession(s1)
            let key1 = key(s1, 1)

            RemoteAttachPager.reconcile(
                vc, mounts: [key1], activeSelection: nil, appState: state,
                makeItem: { plainItem(for: $0) })

            #expect(vc.tabViewItems.count == 1)
            #expect(vc.tabViewItems.first?.identifier as? RemoteAttachMountKey == key1)

            // The replacement child spawns and reports before the superseded
            // key's deferred unmount lands — the race the generation tag on
            // that report exists for.
            let spawnedAt = Date()
            state.markRemoteAttachStarted(s1, generation: 1, at: spawnedAt)

            await drainMainQueue()

            #expect(state.remoteAttachStartedAt(for: s1) == spawnedAt)
        }
    }

    /// Step 3 of the diff. Reddens if the selection sync is dropped, or if it
    /// matches on the whole key rather than the selection — a restarted pane's
    /// generation has already moved on by the time the app asks for it to be
    /// shown.
    @Test("reconcile selects the active selection")
    func reconcileSelectsTheActiveSelection() {
        withState { state in
            let s1 = attached(state, id: "s1")
            let s2 = attached(state, id: "s2")
            let vc = makeTabViewController()

            RemoteAttachPager.reconcile(
                vc, mounts: [key(s1, 0), key(s2, 0)], activeSelection: s2, appState: state,
                makeItem: { plainItem(for: $0) })

            #expect(vc.tabViewItems.count == 2)
            #expect(vc.selectedTabViewItemIndex == 1)
        }
    }
}
