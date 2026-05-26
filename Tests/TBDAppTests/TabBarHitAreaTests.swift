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

            let paddedWidth = keyViewProxyMaxWidth(
                TabBar(
                    tabs: [tab],
                    worktreeID: worktreeID,
                    activeTabIndex: .constant(0),
                    onCloseTab: { _ in }
                )
                .environmentObject(appState)
                .frame(width: 220, height: 30)
            )
            let labelOnlyWidth = keyViewProxyMaxWidth(
                Button(action: {}) {
                    HStack(spacing: 0) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10))
                            .frame(width: 14)
                            .padding(.trailing, 3)
                        Text(tab.label ?? "")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 220, height: 30)
            )

            // The fix moves the leading padding and min-height onto the select
            // button itself, so its AppKit hit region should be materially
            // wider than the label-only baseline.
            #expect(paddedWidth > labelOnlyWidth + 2)
        }

        #expect(UserDefaults.standard.persistentDomain(forName: suiteName) == nil)
    }

    private func keyViewProxyMaxWidth<Content: View>(_ rootView: Content) -> CGFloat {
        let host = NSHostingView(rootView: rootView)
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 30)
        host.layoutSubtreeIfNeeded()
        return keyViewProxyFrames(in: host).map(\.width).max() ?? 0
    }

    private func keyViewProxyFrames(in view: NSView) -> [CGRect] {
        // SwiftUI's AppKit button hit target is materialized as a private
        // KeyViewProxy view. There's no public NSView API that exposes the
        // same button hit-region frame directly, so this string match is a
        // deliberate test seam rather than an accidental private dependency.
        let current = String(describing: type(of: view)) == "KeyViewProxy" ? [view.frame] : []
        return current + view.subviews.flatMap(keyViewProxyFrames(in:))
    }
}
