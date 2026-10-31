import AppKit
import TBDShared

/// Header actions, chevrons and the reveals `SidebarView` runs, mirrored.
extension SidebarOutlineController {
    // MARK: Header actions and chevrons

    /// The outline's click action: a header runs what the SwiftUI header's tap
    /// runs, and a click on a worktree row's PR glyph opens the pull request.
    /// Row clicks otherwise select through the outline and need nothing here.
    @objc func outlineClicked(_ sender: Any?) {
        var point: NSPoint?
        if let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown {
            point = outline.convert(event.locationInWindow, from: nil)
        }
        handleClick(row: outline.clickedRow, at: point)
    }

    /// - Parameter point: where the click landed, in the outline's
    ///   coordinates, when it came from the pointer.
    func handleClick(row: Int, at point: NSPoint? = nil) {
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem else { return }
        if let point, openPullRequestIfClickedGlyph(row: row, at: point) { return }
        switch item.id {
        case .repoHeader(let repoID):
            appState.selectRepo(id: repoID)
        case .scratchHeader:
            appState.selectScratchSection()
        case .providerHeader(let name):
            appState.selectRemoteProvider(name)
        case .group(let groupID):
            appState.toggleSidebarGroup(groupID)
        case .scratchPrompt:
            appState.createScratch()
        case .worktree, .remoteSession:
            break
        }
    }

    /// A section header's chevron.
    @objc func chevronClicked(_ sender: NSView) {
        let row = outline.row(for: sender)
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem else { return }
        toggleExpansion(of: item.id)
    }

    /// Flips a section's or group's expanded state where it lives — the repo
    /// record, the Scratch section's `@AppStorage` key, or
    /// `expandedSidebarGroups` — and lets the next rebuild apply it. The
    /// outline's own expansion notifications are never read for this.
    func toggleExpansion(of id: SidebarNodeID) {
        switch id {
        case .repoHeader(let repoID):
            guard let repo = appState.repos.first(where: { $0.id == repoID }) else { return }
            let state = appState
            let expanded = !repo.expanded
            Task { await state.setRepoExpanded(id: repoID, expanded: expanded) }
        case .scratchHeader:
            let expanded = SidebarBuildOptions(defaults: defaults).scratchExpanded
            defaults.set(!expanded, forKey: AppState.scratchSectionExpandedKey)
        case .group(let groupID):
            appState.toggleSidebarGroup(groupID)
        case .worktree, .remoteSession, .providerHeader, .scratchPrompt:
            break
        }
    }

    /// A missing repo's Locate… link: the SwiftUI header's panel and relocate.
    @objc func locateClicked(_ sender: NSView) {
        let row = outline.row(for: sender)
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem,
              case .repoHeader(let repoID) = item.id,
              let repo = appState.repos.first(where: { $0.id == repoID }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the new location of \(repo.displayName)"
        panel.prompt = "Relocate"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let state = appState
        Task { await state.relocateRepo(id: repoID, newPath: url.path) }
    }

    // MARK: Reveal

    /// `SidebarView`'s three `onChange` handlers, run at the top of every
    /// rebuild: the pending scroll's reveal, the selection reveal with its
    /// baseline rule, and the Ended reveal. They call the same `AppState`
    /// methods, so the two paths reveal alike.
    func performReveals(options: SidebarBuildOptions) {
        let grouped = options.workflowGroups
        if let target = appState.pendingScrollToWorktreeID {
            appState.revealSidebarGroups(
                appState.sidebarGroupReveal(worktreeIDs: [target], selection: nil), grouped: grouped)
            // Taken now and cleared before the tracking is installed; the
            // apply that follows scrolls to it.
            pendingScrollTarget = target
            appState.pendingScrollToWorktreeID = nil
        }

        let reveal: SidebarGroupReveal? = grouped ? appState.sidebarSelectionReveal : nil
        if !hasSeenSelectionReveal || reveal != lastSelectionReveal {
            // The first evaluation sees the value as both old and new, as
            // `onChange(of:initial: true)` hands it over.
            let previous = hasSeenSelectionReveal ? lastSelectionReveal : reveal
            hasSeenSelectionReveal = true
            lastSelectionReveal = reveal
            if let reveal {
                appState.revealSidebarGroups(
                    reveal,
                    previous: SidebarReveal.baseline(
                        previous: previous, reveal: reveal, hasRevealed: hasRevealedInitialSelection),
                    grouped: grouped)
            }
            hasRevealedInitialSelection = true
        }

        // Nil, reading nothing, unless the option is on and groups are off.
        let key: EndedRevealKey? = !grouped && options.collapseEnded
            ? EndedRevealKey(generation: appState.sidebarSelectionGeneration, selection: appState.selectedRemoteSession)
            : nil
        if !hasSeenEndedRevealKey || key != lastEndedRevealKey {
            hasSeenEndedRevealKey = true
            lastEndedRevealKey = key
            if let key {
                appState.expandedSidebarGroups.formUnion(appState.sidebarEndedRevealGroups(selection: key.selection))
            }
        }
    }

    /// Centres the pending scroll target in the apply that expanded its
    /// section. While structure is held the section may not be shown yet, so
    /// the target waits for the apply that ends the hold. A target with no
    /// row by then is dropped, as the `List` drops it.
    func scrollPendingTargetToCenter() {
        guard let target = pendingScrollTarget, !isHoldingStructure else { return }
        pendingScrollTarget = nil
        guard let item = items.existing(.worktree(target)) else { return }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.tile()
        scroll(toY: outline.rect(ofRow: row).midY - scrollView.contentView.bounds.height / 2)
    }
}
