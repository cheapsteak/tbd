import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

@Suite("Tab bar hit area")
@MainActor
struct TabBarHitAreaTests {
    @Test("selection target includes tab padding, not just the label")
    func selectionTargetIncludesTabPadding() {
        let worktreeID = UUID()
        let terminalID = UUID()
        let tab = Tab(id: terminalID, content: .terminal(terminalID: terminalID), label: "A")
        let suiteName = "TabBarHitAreaTests-\(UUID().uuidString)"

        do {
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.set(true, forKey: "probe")
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let appState = AppState(userDefaults: defaults)
            appState.terminals[worktreeID] = [
                Terminal(
                    id: terminalID,
                    worktreeID: worktreeID,
                    tmuxWindowID: "1",
                    tmuxPaneID: "%1"
                )
            ]

            let host = NSHostingView(
                rootView: TabBar(
                    tabs: [tab],
                    worktreeID: worktreeID,
                    activeTabIndex: .constant(0),
                    onCloseTab: { _ in }
                )
                .environmentObject(appState)
                .frame(width: 220, height: 30)
            )
            host.frame = NSRect(x: 0, y: 0, width: 220, height: 30)
            host.layoutSubtreeIfNeeded()

            let proxyWidths = keyViewProxyFrames(in: host).map(\.width)
            // A label-only target was 28pt in the broken layout. The HStack fix
            // moves the leading padding/min-height onto the select button, which
            // should push the button's AppKit hit region beyond that label-only size.
            #expect((proxyWidths.max() ?? 0) > 30)
        }

        #expect(UserDefaults.standard.persistentDomain(forName: suiteName) == nil)
    }

    private func keyViewProxyFrames(in view: NSView) -> [CGRect] {
        let current = String(describing: type(of: view)) == "KeyViewProxy" ? [view.frame] : []
        return current + view.subviews.flatMap(keyViewProxyFrames(in:))
    }
}
