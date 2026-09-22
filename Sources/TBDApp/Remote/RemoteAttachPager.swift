import SwiftUI
import AppKit
import TBDShared

/// NSViewControllerRepresentable wrapping NSTabViewController for keep-alive
/// remote-session attach terminals — the remote analogue of `WorktreePager`
/// (see that type's doc comment for why NSTabViewController, not a plain
/// SwiftUI ZStack, is required for correct hit-testing/hidden-state).
///
/// Each mounted tab item owns exactly one live PTY connection to a remote
/// machine (`RemoteAttachTerminalView` → `LocalProcess`) — unlike a local
/// worktree's tmux attach, this is a real, potentially concurrency/cost-
/// bounded resource (SSM/ssh). `mounts` (driven by
/// `AppState.attachedRemoteMountKeys`) is the ONLY mount set this pager
/// ever renders; anything that falls out of it gets torn down
/// (`dismantleNSView` → `Coordinator.cleanup()` → `LocalProcess.terminate()`)
/// on the very next `updateNSViewController`, which is how cap-eviction and
/// explicit-detach both actually free their connection.
///
/// Tab items are keyed by `RemoteAttachMountKey` — selection AND restart
/// generation — not by selection alone. `AppState.reconnectRemoteSession`
/// bumps a selection's generation, so its old key falls out of `mounts` and
/// a new one enters: this one update removes the old item (terminating and
/// reaping its `attach` child; `cleanup()` marks the coordinator torn down, so
/// that child's exit never reaches `onDetached`) and adds a fresh item that
/// re-execs `attach <id>`. The `onDetached` bridge also carries the
/// generation, so an exit that races the swap is dropped by
/// `markRemoteSessionDetached` instead of detaching the replacement.
///
/// Mounted once per `RemoteSessionDetailView` instance and kept alive across
/// DIFFERENT remote-session selections (that view is deliberately no longer
/// `.id()`-keyed per selection — see its doc comment) so switching between
/// recently-viewed sessions doesn't tear down and respawn their terminals.
/// Background attaches ALSO survive leaving remote-session mode entirely
/// (selecting a worktree/repo/scratch section): `RemoteSessionDetailView`
/// itself is now hosted inside `DetailSectionHostPager`'s `.remote` tab,
/// which stays mounted (hidden, not torn down) across that excursion for
/// exactly this reason — see that type's doc comment.
struct RemoteAttachPager: NSViewControllerRepresentable {
    let mounts: [RemoteAttachMountKey]
    let activeSelection: RemoteSessionSelection?
    @Environment(AppState.self) var appState
    @EnvironmentObject var appearance: AppearanceSettings

    func makeNSViewController(context: Context) -> NSTabViewController {
        let vc = NSTabViewController()
        vc.tabStyle = .unspecified
        vc.transitionOptions = []
        return vc
    }

    func updateNSViewController(_ vc: NSTabViewController, context: Context) {
        Self.reconcile(vc, mounts: mounts, activeSelection: activeSelection, appState: appState) { key in
            guard let config = appState.remoteProviders.first(where: { $0.config.name == key.selection.provider })?.config
            else { return nil } // provider unregistered/unknown — nothing to spawn against
            let host = NSHostingController(
                rootView: Self.makeTerminalView(for: key, provider: config, appState: appState)
                    .environment(appState)
                    .environmentObject(appearance)
            )
            let item = NSTabViewItem(viewController: host)
            item.identifier = key
            return item
        }
    }

    /// The bare attach terminal for one mount key, with both AppState bridges
    /// wired: the spawn report and the exit report each carry the key's
    /// generation, which is how a superseded child's late report is told apart
    /// from the live one's. Kept separate from `updateNSViewController` so the
    /// wiring can be driven by a test without a SwiftUI `Context`.
    @MainActor
    static func makeTerminalView(
        for key: RemoteAttachMountKey,
        provider config: RemoteProviderConfig,
        appState: AppState
    ) -> RemoteAttachTerminalView {
        let selection = key.selection
        let generation = key.generation
        return RemoteAttachTerminalView(
            provider: config,
            sessionID: selection.sessionID,
            onDetached: { [weak appState] exitCode in
                appState?.markRemoteSessionDetached(selection, exitCode: exitCode, generation: generation)
            },
            // Runs from `TBDTerminalView.onReady`, which the terminal
            // view defers through `DispatchQueue.main.async` (see its
            // `layout()` override) — so this lands on a later
            // main-queue turn, outside the SwiftUI update pass, and
            // mutating AppState here is fine. Same generation tagging
            // as `onDetached`: a spawn reported for a superseded
            // generation is dropped rather than dating the
            // replacement child.
            onStarted: { [weak appState] date in
                appState?.markRemoteAttachStarted(selection, generation: generation, at: date)
            },
            // A kept-alive pane never re-runs its spawn-time focus claim, so
            // selecting it again goes through this registration instead. A
            // reconnect's replacement registers over the superseded view, and
            // the unregister is identity-guarded against that order.
            onViewMounted: { [weak appState] view in
                appState?.registerRemoteTerminalView(view, for: selection)
            },
            onViewDismantled: { [weak appState] view in
                appState?.unregisterRemoteTerminalView(view, for: selection)
            }
        )
    }

    /// The whole mount-set diff, applied to `vc`: remove tab items whose key
    /// left `mounts` (reporting each unmount to `appState` on the next main
    /// turn), add items for keys that entered, and select the active one.
    /// `makeItem` builds the tab item for a key — carrying that key as the
    /// item's `identifier`, which is how a later diff recognises it — or nil
    /// when its provider is unknown. Static so a test can drive it against a
    /// real `NSTabViewController` without a SwiftUI `Context`.
    @MainActor
    static func reconcile(
        _ vc: NSTabViewController,
        mounts: [RemoteAttachMountKey],
        activeSelection: RemoteSessionSelection?,
        appState: AppState,
        makeItem: (RemoteAttachMountKey) -> NSTabViewItem?
    ) {
        let mountedKeys = Set(mounts)
        let currentKeys = vc.tabViewItems.compactMap { $0.identifier as? RemoteAttachMountKey }

        // 1. Remove tab items for keys no longer in the mount set (cap
        //    eviction, explicit detach, the session vanishing from the
        //    daemon's mirror entirely, or a reconnect superseding the
        //    generation). This is where `terminate()` actually happens, via
        //    `dismantleNSView`.
        for (idx, key) in currentKeys.enumerated().reversed() {
            if !mountedKeys.contains(key) {
                vc.removeTabViewItem(vc.tabViewItems[idx])
                // That dismantle terminates the child with its own exit
                // callback suppressed (`Coordinator.cleanup()`), so this
                // report is the only thing that tells AppState the child is
                // gone. Without it the recorded spawn time outlives the child
                // it dates, and a cap-evicted selection that is later
                // re-admitted while still backgrounded — no child, nothing to
                // re-report — gets restarted by the next network change for a
                // pane that has nothing to restart.
                //
                // Deferred one main-queue turn because this runs inside
                // `updateNSViewController`, i.e. inside a SwiftUI update
                // pass, where mutating observed AppState is not allowed. The
                // generation rides along for the same reason `onDetached`
                // carries it: when a reconnect supersedes a generation, this
                // very loop removes the old key in the same update that mounts
                // the replacement, and a report against the stale generation
                // must not clear the replacement child's start.
                let selection = key.selection
                let generation = key.generation
                DispatchQueue.main.async { [weak appState] in
                    appState?.markRemoteAttachUnmounted(selection, generation: generation)
                }
            }
        }

        // 2. Add tab items for newly-mounted keys.
        for key in mounts where !currentKeys.contains(key) {
            guard let item = makeItem(key) else { continue }
            vc.addTabViewItem(item)
        }

        // 3. Sync selected index with the active selection, if any/mounted.
        if let activeSelection,
           let idx = vc.tabViewItems.firstIndex(where: {
               ($0.identifier as? RemoteAttachMountKey)?.selection == activeSelection
           }),
           vc.selectedTabViewItemIndex != idx {
            vc.selectedTabViewItemIndex = idx
        }
    }
}
