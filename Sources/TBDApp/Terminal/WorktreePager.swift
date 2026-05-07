import SwiftUI
import AppKit
import os

private let pagerLog = Logger(subsystem: "com.tbd.app", category: "perf-transcript")

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
        pagerLog.debug("pager.makeVC tabStyle=unspecified")
        return vc
    }

    func updateNSViewController(_ vc: NSTabViewController, context: Context) {
        let currentIDs = vc.tabViewItems.compactMap { $0.identifier as? UUID }
        let activeShort = activeID.map { String($0.uuidString.suffix(4)) } ?? "nil"
        pagerLog.debug("pager.update.start existing=\(currentIDs.count, privacy: .public) requested=\(self.worktreeIDs.count, privacy: .public) active=\(activeShort, privacy: .public) selectedIdx=\(vc.selectedTabViewItemIndex, privacy: .public)")

        // 1. Remove tab items whose worktree IDs were evicted.
        for (idx, id) in currentIDs.enumerated().reversed() {
            if !worktreeIDs.contains(id) {
                pagerLog.debug("pager.tab.remove id=\(String(id.uuidString.suffix(4)), privacy: .public) idx=\(idx, privacy: .public)")
                vc.removeTabViewItem(vc.tabViewItems[idx])
            }
        }

        // 2. Add tab items for new worktree IDs.
        for id in worktreeIDs where !currentIDs.contains(id) {
            pagerLog.debug("pager.tab.add id=\(String(id.uuidString.suffix(4)), privacy: .public)")
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

        pagerLog.debug("pager.update.end tabs=\(vc.tabViewItems.count, privacy: .public) selectedIdx=\(vc.selectedTabViewItemIndex, privacy: .public)")

        for (idx, item) in vc.tabViewItems.enumerated() {
            let id = (item.identifier as? UUID).map { String($0.uuidString.suffix(4)) } ?? "?"
            let isLoaded = item.viewController?.isViewLoaded ?? false
            let isHidden = isLoaded ? (item.viewController?.view.isHidden ?? false) : false
            let isInWindow = isLoaded ? (item.viewController?.view.window != nil) : false
            pagerLog.debug("pager.tab.state idx=\(idx, privacy: .public) id=\(id, privacy: .public) loaded=\(isLoaded, privacy: .public) hidden=\(isHidden, privacy: .public) inWindow=\(isInWindow, privacy: .public)")
        }

        // Deep diagnostic: walk every inactive tab's NSView subtree and log
        // each descendant's window/isHidden state. Looking for descendants
        // with `window != nil` while their parent (the tab's hosting view) has
        // `window == nil` — that would prove SwiftUI's NSViewRepresentable
        // bridge keeps wrapped NSViews window-attached even when their hosting
        // SwiftUI parent is detached, which would explain the cross-worktree
        // scroll-event routing the user is observing.
        for (idx, item) in vc.tabViewItems.enumerated() where idx != vc.selectedTabViewItemIndex {
            guard item.viewController?.isViewLoaded ?? false,
                  let rootView = item.viewController?.view else { continue }
            let id = (item.identifier as? UUID).map { String($0.uuidString.suffix(4)) } ?? "?"
            Self.dumpInactiveSubtree(rootView, tabID: id, depth: 0, maxDepth: 12)
        }
    }

    private static func dumpInactiveSubtree(_ view: NSView, tabID: String, depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else {
            pagerLog.debug("pager.subtree.elided id=\(tabID, privacy: .public) depth=\(depth, privacy: .public)")
            return
        }
        let cls = String(describing: type(of: view))
        let inWindow = view.window != nil
        let hidden = view.isHidden
        pagerLog.debug("pager.subtree id=\(tabID, privacy: .public) depth=\(depth, privacy: .public) class=\(cls, privacy: .public) inWindow=\(inWindow, privacy: .public) hidden=\(hidden, privacy: .public)")
        for sub in view.subviews {
            dumpInactiveSubtree(sub, tabID: tabID, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}
