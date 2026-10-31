import AppKit
import Combine
import SwiftUI

/// The native sidebar's `+` menu: the existing `WorktreeProfilePickerView` in
/// a `FloatingPanel`, opened and closed by a `HoverMenuModel` exactly as
/// `FloatingMenuAnchor` presents it for the SwiftUI rows — a 400 ms hover
/// delay, ⌥-click to open at once, a close grace that bridges the gap into the
/// panel, and closing when the app deactivates. Here it is anchored to an
/// AppKit button: a repo header's `+` or a worktree row's nested `+`.
///
/// One menu serves the whole sidebar, since only one can be open: it is bound
/// to whichever `+` the pointer reaches, and binding it to another closes the
/// first.
@MainActor
final class SidebarPlusMenu {
    let model: HoverMenuModel
    /// The row whose `+` the menu belongs to.
    private(set) var owner: SidebarNodeID?
    private weak var anchor: NSView?
    private var makeContent: ((_ highlightDefault: Bool) -> AnyView)?
    private var panel: FloatingPanel?
    private var subscriptions: Set<AnyCancellable> = []
    /// Called after the menu opens or closes, with its owner, so the owner's
    /// `+` can stay shown while the pointer is inside the menu.
    var onOpenChange: ((SidebarNodeID?, Bool) -> Void)?

    init(model: HoverMenuModel = HoverMenuModel()) {
        self.model = model
        // `@Published` emits before the property changes, so each sink acts
        // on the value it is handed.
        model.$isOpen.dropFirst().removeDuplicates().sink { [weak self] open in
            self?.openChanged(open)
        }.store(in: &subscriptions)
        model.$isTriggerHovered.dropFirst().removeDuplicates().sink { [weak self] hovered in
            self?.refreshContent(highlightDefault: hovered)
        }.store(in: &subscriptions)
    }

    var isOpen: Bool { panel != nil }

    /// Points the menu at `owner`'s `+`. A menu open for another row closes
    /// first.
    func bind(owner: SidebarNodeID, anchor: NSView, content: @escaping (_ highlightDefault: Bool) -> AnyView) {
        if self.owner != owner, model.isOpen {
            model.closeNow()
        }
        self.owner = owner
        self.anchor = anchor
        makeContent = content
    }

    private func openChanged(_ open: Bool) {
        if open {
            guard panel == nil, let anchor, anchor.window != nil, let makeContent else { return }
            let panel = FloatingPanel(content: makeContent(model.isTriggerHovered), canBecomeKey: true)
            self.panel = panel
            panel.showAsMenu(relativeTo: anchor)
        } else {
            panel?.dismiss()
            panel = nil
        }
        onOpenChange?(owner, open)
    }

    /// The trigger's hover highlights the default profile row, as
    /// `highlightDefaultProfile` does in the SwiftUI path.
    private func refreshContent(highlightDefault: Bool) {
        guard let panel, let makeContent else { return }
        panel.updateContent(makeContent(highlightDefault))
    }
}
