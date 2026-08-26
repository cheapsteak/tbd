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
/// bounded resource (SSM/ssh). `selections` (driven by
/// `AppState.attachedRemoteSelections`) is the ONLY mount set this pager
/// ever renders; anything that falls out of it gets torn down
/// (`dismantleNSView` → `Coordinator.cleanup()` → `LocalProcess.terminate()`)
/// on the very next `updateNSViewController`, which is how cap-eviction and
/// explicit-detach both actually free their connection.
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
    let selections: [RemoteSessionSelection]
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
        let mountedSelections = Set(selections)
        let currentSelections = vc.tabViewItems.compactMap { $0.identifier as? RemoteSessionSelection }

        // 1. Remove tab items for selections no longer in the mount set
        //    (cap eviction, explicit detach, or the session vanishing from
        //    the daemon's mirror entirely). This is where `terminate()`
        //    actually happens, via `dismantleNSView`.
        for (idx, selection) in currentSelections.enumerated().reversed() {
            if !mountedSelections.contains(selection) {
                vc.removeTabViewItem(vc.tabViewItems[idx])
            }
        }

        // 2. Add tab items for newly-mounted selections.
        for selection in selections where !currentSelections.contains(selection) {
            guard let config = appState.remoteProviders.first(where: { $0.config.name == selection.provider })?.config
            else { continue } // provider unregistered/unknown — nothing to spawn against
            let host = NSHostingController(
                rootView: RemoteAttachTerminalView(
                    provider: config,
                    sessionID: selection.sessionID,
                    onDetached: { [weak appState] exitCode in
                        appState?.markRemoteSessionDetached(selection, exitCode: exitCode)
                    }
                )
                .environment(appState)
                .environmentObject(appearance)
            )
            let item = NSTabViewItem(viewController: host)
            item.identifier = selection
            vc.addTabViewItem(item)
        }

        // 3. Sync selected index with the active selection, if any/mounted.
        if let activeSelection,
           let idx = vc.tabViewItems.firstIndex(where: { $0.identifier as? RemoteSessionSelection == activeSelection }),
           vc.selectedTabViewItemIndex != idx {
            vc.selectedTabViewItemIndex = idx
        }
    }
}
