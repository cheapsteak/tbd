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
            }
        }

        // 2. Add tab items for newly-mounted keys.
        for key in mounts where !currentKeys.contains(key) {
            let selection = key.selection
            guard let config = appState.remoteProviders.first(where: { $0.config.name == selection.provider })?.config
            else { continue } // provider unregistered/unknown — nothing to spawn against
            let generation = key.generation
            let host = NSHostingController(
                rootView: RemoteAttachTerminalView(
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
                    }
                )
                .environment(appState)
                .environmentObject(appearance)
            )
            let item = NSTabViewItem(viewController: host)
            item.identifier = key
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
