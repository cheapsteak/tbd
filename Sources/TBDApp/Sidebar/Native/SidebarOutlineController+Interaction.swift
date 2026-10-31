import AppKit
import SwiftUI
import TBDShared

/// Everything a pointer, a right-click or a rename does in the native sidebar
/// (spec "Hover", "Rename", "Context menus, popovers and sheets", "Keyboard and
/// accessibility"): the hover tracker's reports applied to cells and row views,
/// the row and header controls, the `+` menu, inline rename, the context menus,
/// sheets and popovers, and the tooltip bubble. Every action calls what the
/// SwiftUI sidebar's views call.
extension SidebarOutlineController: SidebarMenuHost {
    func installInteractions() {
        outline.contextMenuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
        let tracker = SidebarHoverTracker(
            outline: outline,
            onChange: { [weak self] state in self?.hoverChanged(state) },
            clock: hoverClock)
        outline.hoverTracker = tracker
        hoverTracker = tracker
        plusMenu.onOpenChange = { [weak self] _, _ in self?.applyHoverToAvailableRows() }
    }

    // MARK: Hover

    /// A recompute after a scroll or an apply reports an unchanged state too:
    /// the rows then already carry it — cells and row views made since were
    /// configured with it — and only the bubble needs re-anchoring.
    func hoverChanged(_ state: SidebarHoverTracker.State) {
        let previous = hoverState
        hoverState = state
        if state != previous {
            updatePlusTrigger(from: previous, to: state)
            applyHoverToAvailableRows()
        }
        updateTooltip()
    }

    /// Hands every row view the outline has its hover, dimming and pin gap.
    func applyHoverToAvailableRows() {
        outline.enumerateAvailableRowViews { rowView, row in
            guard let item = self.outline.item(atRow: row) as? SidebarItem,
                  let node = self.tree.node(item.id) else { return }
            if let rowView = rowView as? SidebarRowView {
                self.configure(rowView, node: node)
            }
            if let cell = rowView.view(atColumn: 0) as? NSView {
                self.applyHover(to: cell, id: item.id)
            }
        }
    }

    /// The hovered row shows its controls; a revealed section's header shows
    /// its `+` and chevron; the `+` whose menu is open stays shown.
    func applyHover(to cell: NSView, id: SidebarNodeID) {
        let hovered = hoverState.row == id
        let part = hovered ? hoverState.part : .none
        let menuOpen = plusMenu.isOpen && plusMenu.owner == id
        switch cell {
        case let cell as WorktreeRowCell:
            cell.setHovered(hovered)
            cell.setMenuOpen(menuOpen)
            cell.setHoveredPart(part)
        case let cell as SectionHeaderCell:
            cell.setHovered(hoverState.revealedSections.contains(id))
            cell.setMenuOpen(menuOpen)
            cell.setHoveredPart(part)
        case let cell as RemoteSessionRowCell:
            cell.setHovered(hovered)
        default:
            break
        }
    }

    /// A worktree or session row in the section whose chevron is hovered.
    /// Group headers and the header itself keep their opacity, as in
    /// `RepoSectionView` and `ScratchSectionView`.
    func isDimmedByChevron(_ node: SidebarNode) -> Bool {
        guard let section = hoverState.dimmedSection else { return false }
        switch node.kind {
        case .worktree, .remoteSession:
            var top = node.id
            while let parent = tree.parent(of: top) { top = parent }
            return top == section
        case .scratchHeader, .scratchPrompt, .repoHeader, .providerHeader, .groupHeader:
            return false
        }
    }

    /// The pointer reaching or leaving a `+` that opens the profile picker —
    /// `HoverMenuModel.triggerHover`, as the SwiftUI `+`'s `onHover` drives it.
    private func updatePlusTrigger(from old: SidebarHoverTracker.State, to new: SidebarHoverTracker.State) {
        let wasOn = old.part == .plus ? old.row : nil
        let isOn = new.part == .plus ? new.row : nil
        guard wasOn != isOn else { return }
        if let wasOn, plusMenu.owner == wasOn {
            plusMenu.model.triggerHover(false)
        }
        if let isOn, let anchor = plusAnchor(for: isOn), let target = plusTarget(for: isOn) {
            bindPlusMenu(owner: isOn, anchor: anchor, repoID: target.repoID, parent: target.parent)
            plusMenu.model.triggerHover(true)
        }
    }

    private func plusAnchor(for id: SidebarNodeID) -> NSView? {
        guard let item = items.existing(id) else { return nil }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return nil }
        switch outline.view(atColumn: 0, row: row, makeIfNecessary: false) {
        case let cell as WorktreeRowCell: return cell.plusButton
        case let cell as SectionHeaderCell: return cell.plusButton
        default: return nil
        }
    }

    /// Where a `+` creates: a repo header's repo, or a worktree row's repo
    /// with the row as parent. Nil for the Scratch `+`, which has no menu, and
    /// for a missing repo, which never opens one.
    private func plusTarget(for id: SidebarNodeID) -> (repoID: UUID, parent: UUID?)? {
        switch id {
        case .repoHeader(let repoID):
            guard let repo = appState.repos.first(where: { $0.id == repoID }), repo.status != .missing else { return nil }
            return (repoID, nil)
        case .worktree(let worktreeID):
            guard let worktree = appState.findWorktree(id: worktreeID), worktree.status != .main,
                  let repoID = worktree.repoID else { return nil }
            return (repoID, worktreeID)
        case .scratchHeader, .scratchPrompt, .remoteSession, .providerHeader, .group:
            return nil
        }
    }

    private func bindPlusMenu(owner: SidebarNodeID, anchor: NSView, repoID: UUID, parent: UUID?) {
        let state = appState
        let model = plusMenu.model
        plusMenu.bind(owner: owner, anchor: anchor) { [weak self] highlight in
            AnyView(
                WorktreeProfilePickerView(
                    repoID: repoID,
                    parentWorktreeID: parent,
                    highlightDefaultProfile: highlight,
                    onClose: { model.closeNow() },
                    // The picker closes itself first, so this only creates or
                    // presents the sheet.
                    onStartRemoteSession: { provider in
                        self?.startRemoteSession(provider, repoID: repoID, parent: parent)
                    }
                )
                .environment(state)
                .background(.ultraThickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onHover { model.menuHover($0) }
            )
        }
    }

    /// The truncated name of the hovered row, or the hovered PR glyph's
    /// description, in the bubble below it; nothing while that row is being
    /// renamed.
    func updateTooltip() {
        guard let id = hoverState.row, id != renamingID, let item = items.existing(id) else {
            tooltipOverlay.hide()
            return
        }
        let row = outline.row(forItem: item)
        let view = row >= 0 ? outline.view(atColumn: 0, row: row, makeIfNecessary: false) : nil
        var text: String?
        var anchor: NSView?
        if let cell = view as? WorktreeRowCell {
            if hoverState.part == .leadingGlyph, case .worktree(let worktreeID) = id {
                text = prTooltip(worktreeID, leading: cell.model?.leading)
                anchor = cell.leadingImageView
            } else if cell.isNameTruncated, !cell.isRenaming {
                text = cell.model?.name
                anchor = cell.nameField
            }
        } else if let cell = view as? RemoteSessionRowCell, cell.isNameTruncated, !cell.isRenaming {
            text = cell.model?.title
            anchor = cell.nameField
        }
        guard let text, let anchor else {
            tooltipOverlay.hide()
            return
        }
        tooltipOverlay.show(text, below: tooltipOverlay.convert(anchor.bounds, from: anchor))
    }

    /// `WorktreeRowView.leadingIcon`'s tooltips: the PR's reference, state
    /// and freshness, or why nobody could find out.
    private func prTooltip(_ worktreeID: UUID, leading: WorktreeLeadingSlot?) -> String? {
        let observation = appState.prObservations[worktreeID]
        switch leading {
        case .prStatus?:
            guard let binding = PRBindingPresentation.iconBinding(appState.effectivePRBindings(worktreeID: worktreeID)),
                  let status = binding.status else { return nil }
            let detail = PRStatusPresentation.stateDescription(for: status)
            let freshness = PRFreshness.clauses(status: status, observation: observation, now: Date())
            return ([binding.refLabel, detail] + freshness).joined(separator: " · ")
        case .prUnknown?:
            return PRFreshness.unknownIndicatorTooltip(observation, now: Date())
        case .pending?, .remote?, nil:
            return nil
        }
    }

    // MARK: Help text, computed when AppKit asks

    func helpText(_ target: SidebarToolTips.Target, for id: SidebarNodeID) -> String? {
        switch (target, id) {
        case (.suffix, .worktree(let worktreeID)):
            return worktreeSuffixHelp(worktreeID)
        case (.noStatusMark, .worktree(let worktreeID)):
            return NoStatusMark.rowHelp(
                terminals: appState.terminals[worktreeID] ?? [], sightings: appState.noStatusSightings)
        case (.crossRepo, .worktree(let worktreeID)):
            return appState.findWorktree(id: worktreeID)?.repoID.flatMap { appState.repoName(for: $0) }
        case (.suffix, .remoteSession(let sessionID)):
            guard case .remoteSession(let model)? = tree.node(id)?.kind, let indicator = model.suffix else { return nil }
            if case .working = indicator { return "Agent is working" }
            return appState.remoteSessions.first { $0.id == sessionID }?.payload.agentStateReason
                ?? "Needs your attention"
        case (.providerName, .providerHeader(let name)):
            return provider(named: name).map { RemoteProviderIdentityPresentation.compactSummary($0) }
        case (.providerAuth, .providerHeader(let name)):
            guard let status = provider(named: name) else { return nil }
            return status.errorMessage ?? status.remediationLabel ?? "Authentication needed"
        default:
            return nil
        }
    }

    /// `WorktreeRowView.suffixIcon`'s help: the badge's words, or the OSC
    /// session states behind it.
    private func worktreeSuffixHelp(_ worktreeID: UUID) -> String? {
        guard case .worktree(let model)? = tree.node(.worktree(worktreeID))?.kind,
              let indicator = model.suffix else { return nil }
        let terminals = appState.terminals[worktreeID] ?? []
        var resolutions: [UUID: ProgramStatusResolution] = [:]
        var entries: [(label: String, snapshot: ProgramStatusSnapshot)] = []
        for terminal in terminals {
            let snapshot = appState.programStatusSnapshots[terminal.id]
            guard let resolution = ProgramStatusRowPresentation.resolution(terminal: terminal, snapshot: snapshot)
            else { continue }
            resolutions[terminal.id] = resolution
            if let snapshot {
                entries.append((label: ProgramStatusRowPresentation.tooltipLabel(for: terminal), snapshot: snapshot))
            }
        }
        let oscTooltip = resolutions.isEmpty ? nil : ProgramStatusRowPresentation.tooltip(terminals: entries)
        return ProgramStatusRowPresentation.badgeHelp(
            selected: indicator, oscTooltip: oscTooltip,
            resolvedValues: resolutions.values.map { $0.value },
            genericHelp: SidebarCellKit.spokenStatus(indicator))
    }

    private func provider(named name: String) -> RemoteProviderStatus? {
        appState.remoteProviders.first { $0.config.name == name }
    }

    // MARK: Row and header controls

    func wireControls(of cell: WorktreeRowCell, id: SidebarNodeID) {
        cell.pinButton.target = self
        cell.pinButton.action = #selector(pinClicked(_:))
        cell.plusButton.target = self
        cell.plusButton.action = #selector(nestedPlusClicked(_:))
        cell.prButton.target = self
        cell.prButton.action = #selector(prClicked(_:))
        cell.toolTips.provider = { [weak self] target in self?.helpText(target, for: id) }
    }

    /// The ID of the row `sender` sits in.
    private func nodeID(for sender: NSView) -> SidebarNodeID? {
        let row = outline.row(for: sender)
        guard row >= 0 else { return nil }
        return (outline.item(atRow: row) as? SidebarItem)?.id
    }

    @objc func pinClicked(_ sender: NSView) {
        guard case .worktree(let worktreeID)? = nodeID(for: sender),
              let worktree = appState.findWorktree(id: worktreeID) else { return }
        let state = appState
        let pinned = worktree.pinnedAt == nil
        Task { await state.setPinned(worktreeID: worktreeID, pinned: pinned) }
    }

    @objc func nestedPlusClicked(_ sender: NSView) {
        guard let id = nodeID(for: sender), case .worktree = id, let target = plusTarget(for: id) else { return }
        plusPressed(owner: id, anchor: sender, repoID: target.repoID, parent: target.parent)
    }

    @objc func sectionPlusClicked(_ sender: NSView) {
        guard let id = nodeID(for: sender) else { return }
        switch id {
        case .scratchHeader:
            appState.createScratch()
        case .repoHeader:
            guard let target = plusTarget(for: id) else { return }
            plusPressed(owner: id, anchor: sender, repoID: target.repoID, parent: nil)
        case .worktree, .scratchPrompt, .remoteSession, .providerHeader, .group:
            break
        }
    }

    /// A plain click creates a worktree with the default profile; ⌥-click
    /// opens the picker at once. ⌥ is read from `NSEvent.modifierFlags`, the
    /// keyboard's state now, as the SwiftUI `+` reads it.
    private func plusPressed(owner: SidebarNodeID, anchor: NSView, repoID: UUID, parent: UUID?) {
        switch HoverMenuModel.plusOutcome(optionHeld: NSEvent.modifierFlags.contains(.option)) {
        case .openMenu:
            bindPlusMenu(owner: owner, anchor: anchor, repoID: repoID, parent: parent)
            plusMenu.model.openImmediately()
        case .createDefault:
            plusMenu.model.closeNow()
            appState.createWorktree(repoID: repoID, parentWorktreeID: parent)
        }
    }

    /// The picker's remote-lane row: create at once when every answer is
    /// knowable, else open the form — `RepoSectionView.startRemoteSession`
    /// and `WorktreeRowView.startRemoteSession`, which differ only in the
    /// parent.
    private func startRemoteSession(_ provider: RemoteProviderStatus, repoID: UUID, parent: UUID?) {
        let repo = appState.repos.first { $0.id == repoID }
        let prefill = RemoteCreateFormLogic.repoPrefill(remoteURL: repo?.remoteURL)
        let launch = RemoteCreateFormLogic.launch(
            describe: provider.describe,
            repoPrefill: prefill,
            repoDefaults: repo?.remoteCreateDefaults ?? [:],
            globalDefaults: appState.globalRemoteCreateDefaults,
            generatedSlug: NameGenerator.generate())
        switch launch {
        case .createNow(let paramsJSON):
            let state = appState
            Task {
                await state.createRemoteSession(
                    provider: provider.config.name, paramsJSON: paramsJSON,
                    parentWorktreeID: parent, repoID: repoID)
            }
        case .openForm:
            presentSheet(RemoteCreateSheet(
                provider: provider.config,
                describe: provider.describe,
                repoPrefill: prefill,
                repoDefaults: repo?.remoteCreateDefaults ?? [:],
                parentWorktreeID: parent,
                repoID: repoID))
        }
    }

    @objc func prClicked(_ sender: NSView) {
        guard case .worktree(let worktreeID)? = nodeID(for: sender),
              let binding = PRBindingPresentation.iconBinding(appState.effectivePRBindings(worktreeID: worktreeID)),
              let url = URL(string: binding.url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// `RemoteProviderHeaderRow`'s `+`: the create sheet with no repo prefill.
    @objc func providerPlusClicked(_ sender: NSView) {
        guard case .providerHeader(let name)? = nodeID(for: sender), let status = provider(named: name) else { return }
        presentSheet(RemoteCreateSheet(provider: status.config, describe: status.describe, repoPrefill: nil))
    }

    /// The needs-auth key: the session detail pane's auth CTA in a popover;
    /// running its command closes the popover and opens the remediation
    /// terminal in a sheet.
    @objc func authClicked(_ sender: NSView) {
        guard case .providerHeader(let name)? = nodeID(for: sender),
              let presentation = RemoteProviderAuthPresentation.make(from: provider(named: name)) else { return }
        authPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let content = RemoteProviderAuthCTAView(
            presentation: presentation,
            onRun: { [weak self, weak popover] in
                popover?.close()
                guard let run = RemoteRemediationRun(presentation) else { return }
                self?.presentRemediation(run)
            }
        )
        .padding(14)
        .environment(appState)
        popover.contentViewController = NSHostingController(rootView: content)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        authPopover = popover
    }

    private func presentRemediation(_ run: RemoteRemediationRun) {
        guard let appearance = appState.appearance else { return }
        presentSheet(RemoteRemediationTerminalSheet(run: run).environmentObject(appearance))
    }

    // MARK: Sheets and confirmations

    /// Presents existing SwiftUI sheet content as an AppKit sheet on the
    /// sidebar's window, so the SwiftUI path's sheets stay as they are.
    func presentSheet<Content: View>(_ content: Content) {
        guard view.window != nil else { return }
        presentAsSheet(NSHostingController(rootView: content.environment(appState)))
    }

    /// `RepoSectionView`'s confirmation dialog, as an alert sheet.
    func confirmRemove(_ repo: Repo) {
        guard let window = view.window else { return }
        let active = (appState.worktrees[repo.id] ?? [])
            .filter { $0.status == .active || $0.status == .creating }
            .count
        let base = "This unregisters the repo from TBD. Your git repository and files on disk are not touched."
        let alert = NSAlert()
        alert.messageText = "Remove \(repo.displayName) from list?"
        alert.informativeText = active > 0
            ? "\(active) active \(active == 1 ? "worktree" : "worktrees") will be archived first.\n\n\(base)"
            : base
        alert.addButton(withTitle: active > 0 ? "Archive Worktrees & Remove" : "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let state = appState
        let repoID = repo.id
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in await state.removeRepo(repoID: repoID, force: active > 0) }
        }
    }

    // MARK: Context menus

    var menus: SidebarMenus {
        SidebarMenus(appState: appState, defaults: defaults, host: self)
    }

    func contextMenu(forRow row: Int) -> NSMenu? {
        guard let item = outline.item(atRow: row) as? SidebarItem, let node = tree.node(item.id) else { return nil }
        return menus.menu(for: node)
    }

    // MARK: Rename

    /// `editingWorktreeID`, consumed once its row is in the tree the apply is
    /// about to show — as the SwiftUI row consumes it from `onChange`. While a
    /// hold keeps a new row out of the shown structure, the request waits.
    func takeRenameRequest(in latest: SidebarTree) -> UUID? {
        guard let id = appState.editingWorktreeID, latest.contains(.worktree(id)) else { return nil }
        guard !isHoldingStructure || tree.contains(.worktree(id)) else { return nil }
        appState.editingWorktreeID = nil
        return id
    }

    /// Swaps the row's name for the inline editor and holds the structure
    /// until the edit ends. A worktree row other than the main one, a remote
    /// session row, or a repo header; anything else is ignored. One rename at
    /// a time: an open one is committed first.
    func beginRename(_ id: SidebarNodeID) {
        renameEditor?.close(commitPending: true)
        guard let node = tree.node(id), let item = items.existing(id) else { return }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.scrollRowToVisible(row)
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSView & SidebarRenamableCell,
              let editor = makeRenameEditor(for: node) else { return }
        beginHold(.rename)
        renamingID = id
        renamingCell = cell
        renameEditor = editor
        editor.onFinished = { [weak self, weak editor] in self?.renameFinished(editor) }
        cell.beginRename(editor)
        tooltipOverlay.hide()
    }

    /// Ends the open rename, if any. With `commitPending`, what the field
    /// holds is committed as a focus loss would commit it.
    func finishRename(commitPending: Bool) {
        renameEditor?.close(commitPending: commitPending)
    }

    /// The edit is over: the cell still showing `editor` gets its label back,
    /// and the structure hold ends.
    private func renameFinished(_ editor: SidebarRenameEditor?) {
        guard let editor, editor === renameEditor else { return }
        if let cell = renamingCell as? SidebarRenamableCell, cell.renameEditor === editor {
            cell.endRename()
        }
        renamingID = nil
        renamingCell = nil
        renameEditor = nil
        endHold(.rename)
    }

    /// The editor for `node`, committing where the SwiftUI row's
    /// `RenameableLabel` commits.
    private func makeRenameEditor(for node: SidebarNode) -> SidebarRenameEditor? {
        let state = appState
        switch (node.id, node.kind) {
        case (.worktree(let worktreeID), .worktree(let model)):
            guard !model.isMain, let worktree = appState.findWorktree(id: worktreeID) else { return nil }
            return SidebarRenameEditor(text: worktree.displayName, allowsEmptyCommit: false) { name in
                // `renameWorktree` applies the optimistic update itself.
                Task { await state.renameWorktree(id: worktreeID, displayName: name) }
            }
        case (.remoteSession(let sessionID), .remoteSession):
            guard let session = appState.remoteSessions.first(where: { $0.id == sessionID }) else { return nil }
            let providerName = session.provider
            let remoteID = session.payload.id
            let current = appState.remoteSessionDisplayName(
                provider: providerName, sessionID: remoteID, providerTitle: session.payload.title)
            // An empty name clears the override back to the provider's title.
            return SidebarRenameEditor(text: current, allowsEmptyCommit: true) { name in
                state.renameRemoteSession(provider: providerName, sessionID: remoteID, displayName: name)
            }
        case (.repoHeader(let repoID), .repoHeader):
            guard let repo = appState.repos.first(where: { $0.id == repoID }) else { return nil }
            return SidebarRenameEditor(text: repo.displayName, allowsEmptyCommit: false) { name in
                Task { await state.renameRepo(id: repoID, displayName: name) }
            }
        default:
            return nil
        }
    }
}
