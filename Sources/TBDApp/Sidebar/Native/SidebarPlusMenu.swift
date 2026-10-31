import AppKit
import Combine
import SwiftUI
import TBDShared

/// The native sidebar's `+` menu: the existing `WorktreeProfilePickerView` in
/// a `FloatingPanel`, opened and closed by a `HoverMenuModel` exactly as
/// `FloatingMenuAnchor` presents it for the SwiftUI rows — a 400 ms hover
/// delay, ⌥-click to open at once, a close grace that bridges the gap into the
/// panel, and closing when the app deactivates. Here it is anchored to an
/// AppKit button: a repo header's `+` or a worktree row's nested `+`.
///
/// One menu serves the whole sidebar — the outline and the pinned dock —
/// since only one can be open: it is bound to whichever `+` the pointer
/// reaches, and binding it to another closes the first. A row can show in
/// both lists under one ID, so the menu records which list bound it, and each
/// list asks about its own rows only.
@MainActor
final class SidebarPlusMenu {
    let model: HoverMenuModel
    /// The row whose `+` the menu belongs to.
    private(set) var owner: SidebarNodeID?
    /// The list `owner`'s row is in.
    private weak var list: NSTableView?
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

    /// Points the menu at `owner`'s `+` in `list`. A menu open for another
    /// row, or for the same row in the other list, closes first.
    func bind(owner: SidebarNodeID, anchor: NSView, in list: NSTableView,
              content: @escaping (_ highlightDefault: Bool) -> AnyView) {
        if self.owner != owner || self.list !== list, model.isOpen {
            model.closeNow()
        }
        self.owner = owner
        self.list = list
        self.anchor = anchor
        makeContent = content
    }

    /// Whether `owner`'s row in `list` is the one the menu belongs to.
    func isBound(to owner: SidebarNodeID, in list: NSTableView) -> Bool {
        self.owner == owner && self.list === list
    }

    /// Whether the menu is open for `owner`'s `+` in `list`, which keeps that
    /// `+` shown after the pointer leaves the row for the menu.
    func isOpen(for owner: SidebarNodeID, in list: NSTableView) -> Bool {
        isOpen && isBound(to: owner, in: list)
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

/// Where a `+` creates: a repo, and the row a new worktree nests under — nil
/// for one at the repo's top level.
struct SidebarPlusTarget: Equatable {
    let repoID: UUID
    let parent: UUID?
}

// MARK: Shared by the outline and the dock

/// What both lists do with a `+`: the pointer reaching or leaving one, a
/// press, and the menu closing once its row leaves. Each list hands in its own
/// table, so a row that shows in both is told apart.
extension SidebarPlusMenu {
    /// The pointer reached or left a `+` in `list` — `HoverMenuModel`'s
    /// trigger, as the SwiftUI `+`'s `onHover` drives it, with its 400 ms
    /// delay before the menu opens.
    ///
    /// - Parameters:
    ///   - old: the row whose `+` the pointer was on, if any.
    ///   - new: the row whose `+` it is on now, if any.
    ///   - anchor: the `+` button of a row `list` shows.
    ///   - target: where a row's `+` creates; nil for a `+` with no menu.
    func pointerMoved(
        from old: SidebarNodeID?, to new: SidebarNodeID?, in list: NSTableView,
        anchor: (SidebarNodeID) -> NSView?, target: (SidebarNodeID) -> SidebarPlusTarget?,
        appState: AppState, sheets: NativeSidebarSheetPresenter
    ) {
        guard old != new else { return }
        if let old, isBound(to: old, in: list) {
            model.triggerHover(false)
        }
        if let new, let button = anchor(new), let destination = target(new) {
            bindPicker(owner: new, anchor: button, in: list, target: destination, appState: appState, sheets: sheets)
            model.triggerHover(true)
        }
    }

    /// A press on a `+` in `list`: a plain click creates a worktree with the
    /// default profile; ⌥-click opens the picker at once. ⌥ is read from
    /// `NSEvent.modifierFlags`, the keyboard's state now, as the SwiftUI `+`
    /// reads it.
    func press(owner: SidebarNodeID, anchor: NSView, in list: NSTableView, target: SidebarPlusTarget,
               appState: AppState, sheets: NativeSidebarSheetPresenter) {
        switch HoverMenuModel.plusOutcome(optionHeld: NSEvent.modifierFlags.contains(.option)) {
        case .openMenu:
            bindPicker(owner: owner, anchor: anchor, in: list, target: target, appState: appState, sheets: sheets)
            model.openImmediately()
        case .createDefault:
            model.closeNow()
            appState.createWorktree(repoID: target.repoID, parentWorktreeID: target.parent)
        }
    }

    /// Closes the menu once its row is no longer shown in `list`, as the
    /// SwiftUI `+` closes when its row unmounts. A menu another list bound is
    /// that list's to close.
    func closeIfOwnerLeft(_ list: NSTableView, isShown: (SidebarNodeID) -> Bool) {
        guard model.isOpen, let owner, self.list === list, !isShown(owner) else { return }
        model.closeNow()
    }

    /// Binds the menu to `owner`'s `+` with the existing
    /// `WorktreeProfilePickerView` as its content.
    private func bindPicker(owner: SidebarNodeID, anchor: NSView, in list: NSTableView, target: SidebarPlusTarget,
                            appState: AppState, sheets: NativeSidebarSheetPresenter) {
        let model = self.model
        bind(owner: owner, anchor: anchor, in: list) { highlight in
            AnyView(
                WorktreeProfilePickerView(
                    repoID: target.repoID,
                    parentWorktreeID: target.parent,
                    highlightDefaultProfile: highlight,
                    onClose: { model.closeNow() },
                    // The picker closes itself first, so this only creates or
                    // presents the sheet.
                    onStartRemoteSession: { provider in
                        SidebarPlusMenu.startRemoteSession(provider, target: target, appState: appState, sheets: sheets)
                    }
                )
                .environment(appState)
                .background(.ultraThickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onHover { model.menuHover($0) }
            )
        }
    }

    /// The picker's remote-lane row: create at once when every answer is
    /// knowable, else open the form — `RepoSectionView.startRemoteSession`
    /// and `WorktreeRowView.startRemoteSession`, which differ only in the
    /// parent.
    static func startRemoteSession(_ provider: RemoteProviderStatus, target: SidebarPlusTarget,
                                   appState: AppState, sheets: NativeSidebarSheetPresenter) {
        let repo = appState.repos.first { $0.id == target.repoID }
        let prefill = RemoteCreateFormLogic.repoPrefill(remoteURL: repo?.remoteURL)
        let launch = RemoteCreateFormLogic.launch(
            describe: provider.describe,
            repoPrefill: prefill,
            repoDefaults: repo?.remoteCreateDefaults ?? [:],
            globalDefaults: appState.globalRemoteCreateDefaults,
            generatedSlug: NameGenerator.generate())
        switch launch {
        case .createNow(let paramsJSON):
            Task {
                await appState.createRemoteSession(
                    provider: provider.config.name, paramsJSON: paramsJSON,
                    parentWorktreeID: target.parent, repoID: target.repoID)
            }
        case .openForm:
            sheets.present(.remoteCreate(NativeSidebarRemoteCreate(
                provider: provider,
                repoPrefill: prefill,
                repoDefaults: repo?.remoteCreateDefaults ?? [:],
                parentWorktreeID: target.parent,
                repoID: target.repoID)))
        }
    }
}
