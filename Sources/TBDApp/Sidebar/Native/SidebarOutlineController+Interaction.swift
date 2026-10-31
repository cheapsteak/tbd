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
        let menuOpen = plusMenu.isOpen(for: id, in: outline)
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

    /// The pointer reaching or leaving a `+` that opens the profile picker.
    private func updatePlusTrigger(from old: SidebarHoverTracker.State, to new: SidebarHoverTracker.State) {
        plusMenu.pointerMoved(
            from: old.part == .plus ? old.row : nil, to: new.part == .plus ? new.row : nil, in: outline,
            anchor: { plusAnchor(for: $0) }, target: { plusTarget(for: $0) },
            appState: appState, sheets: sheets)
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
    private func plusTarget(for id: SidebarNodeID) -> SidebarPlusTarget? {
        switch id {
        case .repoHeader(let repoID):
            guard let repo = appState.repos.first(where: { $0.id == repoID }), repo.status != .missing else { return nil }
            return SidebarPlusTarget(repoID: repoID, parent: nil)
        case .worktree(let worktreeID):
            guard let worktree = appState.findWorktree(id: worktreeID), worktree.status != .main,
                  let repoID = worktree.repoID else { return nil }
            return SidebarPlusTarget(repoID: repoID, parent: worktreeID)
        case .scratchHeader, .scratchPrompt, .remoteSession, .providerHeader, .group:
            return nil
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
            guard case .worktree(let model)? = tree.node(id)?.kind, let indicator = model.suffix else { return nil }
            return Self.worktreeSuffixHelp(worktreeID, indicator: indicator, appState: appState)
        case (.noStatusMark, .worktree(let worktreeID)):
            return NoStatusMark.rowHelp(
                terminals: appState.terminals[worktreeID] ?? [], sightings: appState.noStatusSightings)
        case (.crossRepo, .worktree(let worktreeID)):
            return appState.findWorktree(id: worktreeID)?.repoID.flatMap { appState.repoName(for: $0) }
        case (.suffix, .remoteSession(let sessionID)):
            guard case .remoteSession(let model)? = tree.node(id)?.kind, let indicator = model.suffix else { return nil }
            return Self.remoteSuffixHelp(sessionID, indicator: indicator, appState: appState)
        case (.providerName, .providerHeader(let name)):
            return provider(named: name).map { RemoteProviderIdentityPresentation.compactSummary($0) }
        case (.providerAuth, .providerHeader(let name)):
            guard let status = provider(named: name) else { return nil }
            return status.errorMessage ?? status.remediationLabel ?? "Authentication needed"
        default:
            return nil
        }
    }

    /// `WorktreeRowView.suffixIcon`'s help for the badge `indicator`: the
    /// badge's words, or the OSC session states behind it. The pinned dock
    /// asks it for its rows too.
    static func worktreeSuffixHelp(_ worktreeID: UUID, indicator: SuffixRowIndicator,
                                   appState: AppState) -> String? {
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

    /// `RemoteSessionRowView`'s suffix help: the working dots' words, or the
    /// agent's own reason for wanting a look.
    static func remoteSuffixHelp(_ sessionID: UUID, indicator: SuffixRowIndicator,
                                 appState: AppState) -> String? {
        if case .working = indicator { return "Agent is working" }
        return appState.remoteSessions.first { $0.id == sessionID }?.payload.agentStateReason
            ?? "Needs your attention"
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
        cell.toolTips.provider = { [weak self] target in self?.helpText(target, for: id) }
        if case .worktree(let worktreeID) = id {
            cell.onOpenPullRequest = { [weak self] in self?.openPullRequest(worktreeID) ?? false }
        }
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
        plusMenu.press(owner: id, anchor: sender, in: outline, target: target, appState: appState, sheets: sheets)
    }

    @objc func sectionPlusClicked(_ sender: NSView) {
        guard let id = nodeID(for: sender) else { return }
        switch id {
        case .scratchHeader:
            appState.createScratch()
        case .repoHeader:
            guard let target = plusTarget(for: id) else { return }
            plusMenu.press(owner: id, anchor: sender, in: outline, target: target, appState: appState, sheets: sheets)
        case .worktree, .scratchPrompt, .remoteSession, .providerHeader, .group:
            break
        }
    }

    /// Opens the pull request a worktree row's leading glyph stands for —
    /// the worst-state binding, as `WorktreeRowView.openPR` picks it — when a
    /// click on the row lands on the glyph. The glyph is not a button, so a
    /// press on it can still start a drag; the outline's click action, which
    /// runs on mouse-up, is what opens the page.
    ///
    /// - Parameter point: the click, in the outline's coordinates.
    /// - Returns: whether the click opened a pull request.
    @discardableResult
    func openPullRequestIfClickedGlyph(row: Int, at point: NSPoint) -> Bool {
        guard let item = outline.item(atRow: row) as? SidebarItem, case .worktree(let worktreeID) = item.id,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorktreeRowCell,
              cell.isPullRequestGlyph(at: cell.convert(point, from: outline)) else { return false }
        return openPullRequest(worktreeID)
    }

    /// Opens the worktree's worst-state pull request, if it has one.
    func openPullRequest(_ worktreeID: UUID) -> Bool {
        guard let binding = PRBindingPresentation.iconBinding(appState.effectivePRBindings(worktreeID: worktreeID)),
              let url = URL(string: binding.url) else { return false }
        openURL(url)
        return true
    }

    /// `RemoteProviderHeaderRow`'s `+`: the create sheet with no repo prefill.
    @objc func providerPlusClicked(_ sender: NSView) {
        guard case .providerHeader(let name)? = nodeID(for: sender), let status = provider(named: name) else { return }
        present(.remoteCreate(NativeSidebarRemoteCreate(provider: status)))
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
        popover.delegate = self
        let content = RemoteProviderAuthCTAView(
            presentation: presentation,
            onRun: { [weak self, weak popover] in
                popover?.close()
                guard let run = RemoteRemediationRun(presentation) else { return }
                self?.present(.remediation(run))
            }
        )
        .padding(14)
        .environment(appState)
        popover.contentViewController = NSHostingController(rootView: content)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        authPopover = popover
    }

    // MARK: Sheets and confirmations

    /// Asks `NativeSidebarView` for a sheet. It presents with SwiftUI, so the
    /// content's own `dismiss` closes it; one sheet at a time.
    func present(_ sheet: NativeSidebarSheet) {
        sheets.present(sheet)
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

    /// A rename `editingWorktreeID` asked for: the row, the text its field
    /// opens with when an edit is handed over, and whether the open edit is
    /// being handed over rather than committed.
    struct RenameRequest {
        let id: UUID
        let seed: String?
        let handsOver: Bool
    }

    /// `editingWorktreeID`, consumed once its row is shown in the tree the
    /// apply is about to show — as the SwiftUI row consumes it from
    /// `onChange` only once mounted. A row not shown yet (a hold keeps it out,
    /// its section is collapsed) leaves the request pending until it is.
    ///
    /// The exception is the creating placeholder swapped for its real row
    /// while being renamed: the creating row under the edit has left the
    /// model, so the edit is handed to the new row with what was typed,
    /// uncommitted.
    func takeRenameRequest(in latest: SidebarTree) -> RenameRequest? {
        guard let id = appState.editingWorktreeID else { return nil }
        let rowID = SidebarNodeID.worktree(id)
        if let renamingID, renamingID != rowID, !latest.contains(renamingID), holds == [.rename],
           case .worktree(let renamed)? = tree.node(renamingID)?.kind, renamed.leading == .pending,
           let editor = renameEditor, Self.isShown(rowID, in: latest) {
            appState.editingWorktreeID = nil
            // Untouched, the placeholder's generated name is not carried over.
            let typed = editor.currentText
            return RenameRequest(id: id, seed: typed == editor.session.originalText ? nil : typed, handsOver: true)
        }
        guard Self.isShown(rowID, in: isHoldingStructure ? tree : latest) else { return nil }
        appState.editingWorktreeID = nil
        return RenameRequest(id: id, seed: nil, handsOver: false)
    }

    /// Whether the outline shows `id` for `tree`: it is in the tree and every
    /// ancestor shows its children.
    private static func isShown(_ id: SidebarNodeID, in tree: SidebarTree) -> Bool {
        guard tree.contains(id) else { return false }
        var ancestor = tree.parent(of: id)
        while let current = ancestor {
            guard tree.node(current)?.showsChildren == true else { return false }
            ancestor = tree.parent(of: current)
        }
        return true
    }

    /// Swaps the row's name for the inline editor and holds the structure
    /// until the edit ends. A worktree row other than the main one, a remote
    /// session row, or a repo header; anything else is ignored. One rename at
    /// a time: an open one is committed first.
    func beginRename(_ id: SidebarNodeID) {
        startRename(id, seed: nil, commitOpenEdit: true)
    }

    /// `beginRename`, with the text the field opens with when it differs from
    /// the row's name, and whether an open edit is committed or dropped
    /// before this one starts.
    func startRename(_ id: SidebarNodeID, seed: String?, commitOpenEdit: Bool) {
        renameEditor?.close(commitPending: commitOpenEdit)
        guard let node = tree.node(id), let item = items.existing(id) else { return }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.scrollRowToVisible(row)
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSView & SidebarRenamableCell,
              let editor = Self.makeRenameEditor(for: node.id, kind: node.kind, seed: seed, appState: appState)
        else { return }
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

    /// The editor for the row `id` names, committing where the SwiftUI row's
    /// `RenameableLabel` commits. The pinned dock renames its rows with it
    /// too.
    static func makeRenameEditor(for id: SidebarNodeID, kind: SidebarNodeKind, seed: String?,
                                 appState: AppState) -> SidebarRenameEditor? {
        let state = appState
        switch (id, kind) {
        case (.worktree(let worktreeID), .worktree(let model)):
            guard !model.isMain, let worktree = appState.findWorktree(id: worktreeID) else { return nil }
            return SidebarRenameEditor(text: worktree.displayName, seed: seed, allowsEmptyCommit: false) { name in
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

    /// The `+` menu closes once the row it belongs to is no longer shown, as
    /// the SwiftUI `+` closes when its row unmounts.
    func closePlusMenuIfItsRowLeft() {
        plusMenu.closeIfOwnerLeft(outline) { owner in
            items.existing(owner).map { outline.row(forItem: $0) >= 0 } ?? false
        }
    }
}

/// The needs-auth popover lets go of itself once it closes.
extension SidebarOutlineController: NSPopoverDelegate {
    /// Only the closed popover's identity crosses into the main-actor
    /// closure: `Notification` is not `Sendable`.
    nonisolated func popoverDidClose(_ notification: Notification) {
        let closedID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
            if let closedID, let authPopover, ObjectIdentifier(authPopover) == closedID {
                self.authPopover = nil
            }
        }
    }
}
