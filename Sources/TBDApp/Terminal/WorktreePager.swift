import SwiftUI
import AppKit

/// NSViewControllerRepresentable wrapping NSTabViewController for keep-alive
/// worktree views. Apple's TabView uses NSTabViewController internally for
/// state preservation; we use it directly with no tab chrome to get the same
/// behavior for our keep-alive ZStack pattern.
///
/// Why not pure SwiftUI: see research-2026-05-06-zstack-event-leak.md.
/// .opacity(0) doesn't block AppKit scroll-wheel events, .hidden() applied
/// conditionally via @ViewBuilder if/else resets @State on toggle, and
/// NSHostingView wrapping with isHidden update has its own AppKit-side
/// hit-testing quirks. NSTabViewController solves all three at once because
/// it manages isHidden + responder chain internally.
struct WorktreePager: NSViewControllerRepresentable {
    let worktreeIDs: [UUID]
    let activeID: UUID?
    @EnvironmentObject var appState: AppState

    func makeNSViewController(context: Context) -> NSTabViewController {
        let vc = NSTabViewController()
        vc.tabStyle = .unspecified
        vc.transitionOptions = []
        return vc
    }

    func updateNSViewController(_ vc: NSTabViewController, context: Context) {
        let currentIDs = vc.tabViewItems.compactMap { $0.identifier as? UUID }

        // 1. Remove tab items whose worktree IDs were evicted.
        for (idx, id) in currentIDs.enumerated().reversed() {
            if !worktreeIDs.contains(id) {
                vc.removeTabViewItem(vc.tabViewItems[idx])
            }
        }

        // 2. Add tab items for new worktree IDs.
        for id in worktreeIDs where !currentIDs.contains(id) {
            let host = NSHostingController(
                rootView: SingleWorktreeView(worktreeID: id)
                    .environmentObject(appState)
            )
            let item = NSTabViewItem(viewController: host)
            item.identifier = id
            vc.addTabViewItem(item)
        }

        // 3. Sync selected index with the active worktree, if any.
        if let activeID,
           let idx = vc.tabViewItems.firstIndex(where: { $0.identifier as? UUID == activeID }),
           vc.selectedTabViewItemIndex != idx {
            vc.selectedTabViewItemIndex = idx
        }
    }
}
