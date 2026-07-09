import AppKit
import SwiftUI

/// Presents `content` in a borderless, arrow-less, animation-less `FloatingPanel`
/// anchored to the trailing side of the host view — the replacement for `.popover`
/// on the worktree hover menu (no NSPopover arrow, no present/dismiss animation).
/// Driven by `isPresented`; `HoverMenuModel`'s hover close-grace still decides when
/// `isPresented` flips false.
struct FloatingMenuAnchor<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let content: Content

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView(frame: .zero)
        context.coordinator.anchor = anchor
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        if isPresented {
            if let panel = coordinator.panel {
                panel.updateContent(content)          // refresh (e.g. default-row highlight); no reposition
            } else {
                let panel = FloatingPanel(content: content)
                coordinator.panel = panel
                panel.showAsMenu(relativeTo: nsView)
            }
        } else {
            coordinator.panel?.dismiss()
            coordinator.panel = nil
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.panel?.dismiss()
        coordinator.panel = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var anchor: NSView?
        var panel: FloatingPanel?
    }
}
