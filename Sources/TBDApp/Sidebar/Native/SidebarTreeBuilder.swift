import Foundation
import os
import TBDShared

private let nativeSidebarLogger = Logger(subsystem: "com.tbd.app", category: "native-sidebar")

/// The sidebar settings that shape the tree. Each lives in `UserDefaults`,
/// bound by `@AppStorage` in the SwiftUI views; the controller reads them with
/// `init(defaults:)` and rebuilds when they change.
struct SidebarBuildOptions: Equatable {
    /// `sidebar.showHiddenRepos`: hidden repos' sections are shown, dimmed.
    var showHiddenRepos: Bool
    /// `AppState.showScratchSectionKey`.
    var showScratchSection: Bool
    /// `AppState.sidebarWorkflowGroupsKey`.
    var workflowGroups: Bool
    /// `AppState.sidebarCollapseEndedSessionsKey`.
    var collapseEnded: Bool
    /// `AppState.scratchSectionExpandedKey`: the Scratch section's expanded
    /// state. A repo's lives on `Repo.expanded`; the Scratch section has no
    /// record of its own, so its state is a setting like the others here.
    var scratchExpanded: Bool

    /// The key `SidebarView` and `SidebarFooter` bind for the hidden-repos
    /// filter.
    static let showHiddenReposKey = "sidebar.showHiddenRepos"

    init(showHiddenRepos: Bool, showScratchSection: Bool, workflowGroups: Bool,
         collapseEnded: Bool, scratchExpanded: Bool) {
        self.showHiddenRepos = showHiddenRepos
        self.showScratchSection = showScratchSection
        self.workflowGroups = workflowGroups
        self.collapseEnded = collapseEnded
        self.scratchExpanded = scratchExpanded
    }

    /// Reads every option from `defaults` with the default its SwiftUI reader
    /// uses, so an unset key builds the tree the `List` would show.
    @MainActor
    init(defaults: UserDefaults) {
        self.init(
            showHiddenRepos: defaults.object(forKey: Self.showHiddenReposKey) as? Bool ?? false,
            showScratchSection: defaults.object(forKey: AppState.showScratchSectionKey) as? Bool ?? true,
            workflowGroups: AppState.sidebarWorkflowGroupsEnabled(defaults: defaults),
            collapseEnded: AppState.sidebarCollapseEndedSessionsEnabled(defaults: defaults),
            scratchExpanded: defaults.object(forKey: AppState.scratchSectionExpandedKey) as? Bool
                ?? AppState.scratchSectionExpandedDefault)
    }
}

/// Turns `AppState` into the `SidebarTree` the native outline shows: the same
/// sections, rows, order and depths `SidebarView`, `ScratchSectionView`,
/// `RepoSectionView`, `WorktreeSubtreeView` and `RemoteSectionView` render
/// for the same state. It calls the same `AppState` helpers they call
/// (`sidebarRepositoryLayout`, `sidebarRemoteGroups(parentID:)`,
/// `children(of:)` and the rest), so the two paths cannot disagree about
/// membership or order.
///
/// It never writes to `AppState` — the memo caches those helpers fill are
/// `@ObservationIgnored` — because the controller runs it inside
/// `withObservationTracking`, and a tracked write would schedule the next
/// rebuild from inside this one.
///
/// Content under a collapsed header or group is left out, as the `List`
/// leaves it out: a collapsed node has no children in the tree. A worktree
/// subtree is always expanded.
@MainActor
enum SidebarTreeBuilder {
    /// `WorktreeSubtreeView`'s recursion cap: a row at this ancestry depth is
    /// built without its children. Defends against a cyclic or runaway
    /// `parentWorktreeID` chain in the database.
    static let maxSubtreeDepth = 50

    /// - Parameters:
    ///   - now: the clock the staleness and issue captions read.
    ///   - directoryExists: answers whether an unpromoted scratch row's
    ///     directory is still there. Required, with no disk-checking
    ///     default: a rebuild must not touch the disk, so the controller hands
    ///     in its cache of answers probed off the main thread, and tests a
    ///     fixed answer.
    static func build(
        _ appState: AppState,
        options: SidebarBuildOptions,
        now: Date = Date(),
        directoryExists: @escaping (String) -> Bool
    ) -> SidebarTree {
        var pass = BuildPass(
            appState: appState, options: options,
            models: SidebarRowModelFactory(appState: appState, now: now, directoryExists: directoryExists))
        return SidebarTree(roots: pass.roots())
    }

    /// The repos whose sections render, in order: `SidebarView.filteredRepos`.
    static func filteredRepos(_ appState: AppState, showHiddenRepos: Bool) -> [Repo] {
        let base: [Repo]
        if let filterID = appState.repoFilter {
            base = appState.repos.filter { $0.id == filterID }
        } else {
            base = appState.repos
        }
        return showHiddenRepos ? base : base.filter { !$0.hidden }
    }

    /// IDs already reported, so a rebuild after every change does not log
    /// the same corrupt row again.
    private static var reportedRows: Set<UUID> = []

    fileprivate static func reportDepthCap(_ id: UUID) {
        guard reportedRows.insert(id).inserted else { return }
        nativeSidebarLogger.error(
            "Subtree depth cap (\(maxSubtreeDepth, privacy: .public)) hit at worktree \(id, privacy: .public); suspect cyclic parentWorktreeID chain")
    }

    fileprivate static func reportDuplicate(_ id: UUID) {
        guard reportedRows.insert(id).inserted else { return }
        nativeSidebarLogger.error(
            "Worktree \(id, privacy: .public) reached the sidebar twice; suspect cyclic parentWorktreeID chain")
    }
}

/// One build: walks the sections in `List` order, emitting each worktree and
/// session at most once. A node ID can stand for one outline item only, so a
/// row a corrupt parent chain reaches a second time is dropped rather than
/// drawn again, as the `List` would draw it.
@MainActor
private struct BuildPass {
    let appState: AppState
    let options: SidebarBuildOptions
    let models: SidebarRowModelFactory
    let expandedGroups: Set<SidebarGroupID>
    var emittedWorktrees: Set<UUID> = []
    var emittedSessions: Set<UUID> = []
    var emittedRepos: Set<UUID> = []
    var emittedProviders: Set<String> = []

    init(appState: AppState, options: SidebarBuildOptions, models: SidebarRowModelFactory) {
        self.appState = appState
        self.options = options
        self.models = models
        self.expandedGroups = appState.expandedSidebarGroups
    }

    /// Scratch, then the repos, then the Remote section's providers.
    mutating func roots() -> [SidebarNode] {
        var roots: [SidebarNode] = []
        if AppState.scratchSectionVisible(setting: options.showScratchSection, spaces: appState.scratchWorktrees) {
            roots.append(scratchSection())
        }
        for repo in SidebarTreeBuilder.filteredRepos(appState, showHiddenRepos: options.showHiddenRepos) {
            if let section = repoSection(repo) { roots.append(section) }
        }
        // Below the repos, not above, as in `SidebarView`.
        if AppState.remoteSectionVisible(providers: appState.remoteProviders) {
            roots.append(contentsOf: providerSections())
        }
        return roots
    }

    // MARK: Scratch — `ScratchSectionView`

    mutating func scratchSection() -> SidebarNode {
        let expanded = options.scratchExpanded
        var children: [SidebarNode] = []
        if expanded {
            let layout = appState.sidebarScratchLayout(grouped: options.workflowGroups)
            if appState.scratchWorktrees.isEmpty {
                children.append(SidebarNode(id: .scratchPrompt, kind: .scratchPrompt, children: [], isExpanded: false))
            }
            // Scratch rows render flat: no subtree, even when reparented.
            for row in layout.inlineRoots {
                if let node = leafRow(row, isMain: false, depth: 0, hidden: false) { children.append(node) }
            }
            if let hibernation = layout.hibernation {
                let id = SidebarGroupID(owner: .scratch, kind: .hibernated)
                var rows: [SidebarNode] = []
                if expandedGroups.contains(id) {
                    for row in hibernation.hibernatedRoots {
                        if let node = leafRow(row, isMain: false, depth: 1, hidden: false) { rows.append(node) }
                    }
                }
                children.append(groupNode(id, count: hibernation.hibernatedCount, summary: nil,
                                          depth: 0, hidden: false, children: rows))
            }
        }
        return SidebarNode(id: .scratchHeader, kind: .scratchHeader(models.scratchHeader(isExpanded: expanded)),
                           children: children, isExpanded: expanded)
    }

    // MARK: Repos — `RepoSectionView`

    mutating func repoSection(_ repo: Repo) -> SidebarNode? {
        guard emittedRepos.insert(repo.id).inserted else { return nil }
        let hidden = repo.hidden
        var children: [SidebarNode] = []
        if repo.expanded {
            let appState = self.appState
            let layout = appState.sidebarRepositoryLayout(
                repoID: repo.id, grouped: options.workflowGroups, collapseEnded: options.collapseEnded,
                matchedSessions: appState.sidebarMatchedRemoteSessions(repoID: repo.id))
            // The main row first, always childless.
            if let main = (appState.worktrees[repo.id] ?? []).first(where: { $0.status == .main }),
               let node = leafRow(main, isMain: true, depth: 0, hidden: hidden) {
                children.append(node)
            }
            for root in layout.inlineRoots {
                if let node = subtree(root, ancestry: 0, depth: 0, sectionRepoID: repo.id, hidden: hidden) {
                    children.append(node)
                }
            }
            // Inline sessions after the worktree rows, never interleaved.
            children.append(contentsOf: sessionRows(layout.inlineSessions, depth: 0, hidden: hidden))
            if let ended = layout.ended {
                let id = SidebarGroupID(owner: .repository(repo.id), kind: .ended)
                let rows = expandedGroups.contains(id) ? sessionRows(ended.ended, depth: 1, hidden: hidden) : []
                children.append(groupNode(id, count: nil, summary: ended.summary, depth: 0, hidden: hidden, children: rows))
            }
            if let groups = layout.remoteGroups {
                children.append(remoteGroup(groups, owner: .repository(repo.id), rootAncestry: 0, depth: 0,
                                            sectionRepoID: repo.id, hidden: hidden))
            }
            if let hibernation = layout.hibernation {
                let id = SidebarGroupID(owner: .repository(repo.id), kind: .hibernated)
                var rows: [SidebarNode] = []
                if expandedGroups.contains(id) {
                    for root in hibernation.hibernatedRoots {
                        if let node = subtree(root, ancestry: 0, depth: 1, sectionRepoID: repo.id, hidden: hidden) {
                            rows.append(node)
                        }
                    }
                }
                children.append(groupNode(id, count: hibernation.hibernatedCount, summary: nil,
                                          depth: 0, hidden: hidden, children: rows))
            }
        }
        return SidebarNode(id: .repoHeader(repo.id), kind: .repoHeader(models.repoHeader(repo)),
                           children: children, isExpanded: repo.expanded)
    }

    // MARK: Remote section — `RemoteSectionView`

    mutating func providerSections() -> [SidebarNode] {
        let knownRepoIDs = RemoteSectionView.knownRepoIDs(repos: appState.repos, repoFilter: appState.repoFilter)
        var nodes: [SidebarNode] = []
        for provider in appState.remoteProviders {
            let name = provider.config.name
            guard RemoteSectionView.shouldShowHeader(
                    provider: provider, sessions: appState.remoteSessions, knownRepoIDs: knownRepoIDs),
                  emittedProviders.insert(name).inserted else { continue }
            let layout = appState.sidebarProviderLayout(
                provider: name, grouped: options.workflowGroups, collapseEnded: options.collapseEnded)
            var children = sessionRows(layout.inlineSessions, depth: 0, hidden: false)
            if let ended = layout.ended {
                let id = SidebarGroupID(owner: .provider(name), kind: .ended)
                let rows = expandedGroups.contains(id) ? sessionRows(ended.ended, depth: 1, hidden: false) : []
                children.append(groupNode(id, count: nil, summary: ended.summary, depth: 0, hidden: false, children: rows))
            }
            if let groups = layout.remoteGroups {
                children.append(remoteGroup(groups, owner: .provider(name), rootAncestry: 0, depth: 0,
                                            sectionRepoID: nil, hidden: false))
            }
            nodes.append(SidebarNode(id: .providerHeader(name), kind: .providerHeader(models.providerHeader(provider)),
                                     children: children, isExpanded: true))
        }
        return nodes
    }

    // MARK: Worktree subtrees — `WorktreeSubtreeView`

    /// A row and its descendants. `ancestry` counts worktree ancestors only,
    /// the recursion the depth cap bounds; `depth` is the row's visual depth,
    /// which each group header deepens too.
    mutating func subtree(_ worktree: Worktree, ancestry: Int, depth: Int,
                          sectionRepoID: UUID?, hidden: Bool) -> SidebarNode? {
        guard claim(worktree.id) else { return nil }
        var children: [SidebarNode] = []
        if ancestry < SidebarTreeBuilder.maxSubtreeDepth {
            if options.workflowGroups {
                let groups = appState.sidebarRemoteGroups(parentID: worktree.id)
                for child in groups.localRoots {
                    if let node = subtree(child, ancestry: ancestry + 1, depth: depth + 1,
                                          sectionRepoID: sectionRepoID, hidden: hidden) {
                        children.append(node)
                    }
                }
                if !groups.isEmpty {
                    children.append(remoteGroup(groups, owner: .parent(worktree.id), rootAncestry: ancestry + 1,
                                                depth: depth + 1, sectionRepoID: sectionRepoID, hidden: hidden))
                }
            } else {
                for child in appState.children(of: worktree.id) {
                    if let node = subtree(child, ancestry: ancestry + 1, depth: depth + 1,
                                          sectionRepoID: sectionRepoID, hidden: hidden) {
                        children.append(node)
                    }
                }
            }
        } else {
            SidebarTreeBuilder.reportDepthCap(worktree.id)
        }
        let model = models.worktree(worktree, isMain: false, depth: depth,
                                    sectionRepoID: sectionRepoID, isInHiddenSection: hidden)
        return SidebarNode(id: .worktree(worktree.id), kind: .worktree(model), children: children, isExpanded: true)
    }

    /// A Remote disclosure and, while it is expanded, its rows and its Exited
    /// disclosure. Serves a repo's section (`RepoSectionView.remoteGroupContent`),
    /// a provider's (`RemoteSectionView.providerSessionGroups`) and a parent
    /// row's (`WorktreeSubtreeView.groupedChildren`). `depth` is the Remote
    /// header's own visual depth; its rows sit one deeper, and the Exited
    /// header's rows two.
    mutating func remoteGroup(_ groups: SidebarRemoteGroups, owner: SidebarGroupID.Owner, rootAncestry: Int,
                              depth: Int, sectionRepoID: UUID?, hidden: Bool) -> SidebarNode {
        let remoteID = SidebarGroupID(owner: owner, kind: .remote)
        var rows: [SidebarNode] = []
        if expandedGroups.contains(remoteID) {
            for root in groups.remoteRoots {
                if let node = subtree(root, ancestry: rootAncestry, depth: depth + 1,
                                      sectionRepoID: sectionRepoID, hidden: hidden) {
                    rows.append(node)
                }
            }
            rows.append(contentsOf: sessionRows(groups.sessions, depth: depth + 1, hidden: hidden))
            if groups.hasExited {
                let exitedID = SidebarGroupID(owner: owner, kind: .exited)
                var exitedRows: [SidebarNode] = []
                if expandedGroups.contains(exitedID) {
                    for root in groups.exitedRoots {
                        if let node = subtree(root, ancestry: rootAncestry, depth: depth + 2,
                                              sectionRepoID: sectionRepoID, hidden: hidden) {
                            exitedRows.append(node)
                        }
                    }
                    exitedRows.append(contentsOf: sessionRows(groups.exitedSessions, depth: depth + 2, hidden: hidden))
                }
                rows.append(groupNode(exitedID, count: nil, summary: groups.exitedSummary,
                                      depth: depth + 1, hidden: hidden, children: exitedRows))
            }
        }
        return groupNode(remoteID, count: nil, summary: groups.summary, depth: depth, hidden: hidden, children: rows)
    }

    // MARK: Leaves

    /// A worktree row without a subtree: the main row and scratch rows.
    mutating func leafRow(_ worktree: Worktree, isMain: Bool, depth: Int, hidden: Bool) -> SidebarNode? {
        guard claim(worktree.id) else { return nil }
        let model = models.worktree(worktree, isMain: isMain, depth: depth,
                                    sectionRepoID: nil, isInHiddenSection: hidden)
        return SidebarNode(id: .worktree(worktree.id), kind: .worktree(model), children: [], isExpanded: true)
    }

    mutating func sessionRows(_ sessions: [RemoteSessionInfo], depth: Int, hidden: Bool) -> [SidebarNode] {
        var nodes: [SidebarNode] = []
        for session in sessions {
            guard emittedSessions.insert(session.id).inserted else { continue }
            let model = models.remoteSession(session, depth: depth, isInHiddenSection: hidden)
            nodes.append(SidebarNode(id: .remoteSession(session.id), kind: .remoteSession(model),
                                     children: [], isExpanded: false))
        }
        return nodes
    }

    func groupNode(_ id: SidebarGroupID, count: Int?, summary: SidebarRemoteGroups.Summary?,
                   depth: Int, hidden: Bool, children: [SidebarNode]) -> SidebarNode {
        let expanded = expandedGroups.contains(id)
        let model = GroupHeaderModel(
            kind: id.kind, count: count, summary: summary?.text, attention: summary?.attention,
            hasUncertainty: summary?.hasUncertainty ?? false, isExpanded: expanded,
            depth: depth, isInHiddenSection: hidden)
        return SidebarNode(id: .group(id), kind: .groupHeader(model), children: children, isExpanded: expanded)
    }

    /// Marks a worktree as placed; false when it already was.
    mutating func claim(_ id: UUID) -> Bool {
        guard emittedWorktrees.insert(id).inserted else {
            SidebarTreeBuilder.reportDuplicate(id)
            return false
        }
        return true
    }
}

/// Computes each row's model from `AppState`, once per rebuild. Every value is
/// derived the way the matching SwiftUI row derives it, through the same pure
/// helpers. Also the entry point for any other native list that draws these
/// rows, such as the pinned dock.
@MainActor
struct SidebarRowModelFactory {
    let appState: AppState
    let now: Date
    let directoryExists: (String) -> Bool
    /// `AppState.repoName(for:)` as a lookup: the first repo with an ID wins,
    /// as `first(where:)` picks it.
    private let repoNames: [UUID: String]
    /// The first provider registered under each name, as
    /// `RemoteSessionRowView.providerStatus` picks it.
    private let providersByName: [String: RemoteProviderStatus]

    init(appState: AppState, now: Date, directoryExists: @escaping (String) -> Bool) {
        self.appState = appState
        self.now = now
        self.directoryExists = directoryExists
        self.repoNames = Dictionary(appState.repos.map { ($0.id, $0.displayName) },
                                    uniquingKeysWith: { first, _ in first })
        self.providersByName = Dictionary(appState.remoteProviders.map { ($0.config.name, $0) },
                                          uniquingKeysWith: { first, _ in first })
    }

    // MARK: Worktree rows — `WorktreeRowView`

    func worktree(_ worktree: Worktree, isMain: Bool, depth: Int, sectionRepoID: UUID?,
                  isInHiddenSection: Bool) -> WorktreeRowModel {
        let id = worktree.id
        let terminals = appState.terminals[id] ?? []
        var resolutions: [UUID: ProgramStatusResolution] = [:]
        for terminal in terminals {
            if let resolution = ProgramStatusRowPresentation.resolution(
                terminal: terminal, snapshot: appState.programStatusSnapshots[terminal.id]) {
                resolutions[terminal.id] = resolution
            }
        }
        let notification = appState.unreadByWorktree[id]?.type
        let hasPromptOnScreen = terminals.contains { terminal in
            if let resolution = resolutions[terminal.id] {
                if case .awaitingInput = resolution.value { return true }
                return false
            }
            return terminal.hasPromptOnScreen
        }
        let isWorking = terminals.contains { terminal in
            if let resolution = resolutions[terminal.id] {
                return resolution.value == .working
            }
            return WorktreeRowView.isForegroundWorking(terminal)
        }
        let suffix = RowStatusIndicator.suffix(
            notification: notification,
            isWorking: isWorking,
            // Suspend retired: every parked session funnels to the moon.
            isSuspended: false,
            isHibernated: terminals.contains { $0.isParked },
            hasPromptOnScreen: hasPromptOnScreen,
            needsAuth: resolutions.values.contains { $0.value == .needsAuth },
            turnFailed: resolutions.values.contains { $0.value == .error })

        let isPending = worktree.status == .creating
        let indicatorStatus = PRBindingPresentation.iconBinding(appState.effectivePRBindings(worktreeID: id))?.status
        let prPresentation = isMain ? nil : PRStatusPresentation.make(for: indicatorStatus)
        let hasUndeterminedPR = !isMain && indicatorStatus == nil
            && PRFreshness.unknownIndicatorTooltip(appState.prObservations[id], now: now) != nil
        let leading: WorktreeLeadingSlot?
        switch WorktreeRowView.leadingIndicator(
            worktree: worktree, isPending: isPending,
            hasPRStatus: prPresentation != nil, hasUndeterminedPR: hasUndeterminedPR) {
        case .prStatus: leading = prPresentation.map(WorktreeLeadingSlot.prStatus)
        case .prUnknown: leading = .prUnknown
        case .pending: leading = .pending
        case .remote: leading = .remote
        case nil: leading = nil
        }

        var subtitles: [String] = []
        if isPending {
            subtitles.append(WorktreeRowView.creatingSubtitle(
                hasPreSessionTerminal: appState.hasPreSessionTerminal(worktreeID: id)))
        }
        if let promotedID = worktree.promotedToRepoID, let name = repoNames[promotedID] {
            subtitles.append("→ promoted to \(name)")
        }

        var crossRepoLabel: String?
        if let sectionRepoID, sectionRepoID != worktree.repoID,
           let homeRepoID = worktree.repoID, let homeRepo = repoNames[homeRepoID] {
            let short = homeRepo.count > 5 ? String(homeRepo.prefix(5)) + "…" : homeRepo
            crossRepoLabel = "(\(short))"
        }

        let directoryExists = self.directoryExists
        let isDimmed = AppState.scratchRowIsDimmed(
            worktree,
            directoryExists: LocalWorktree(worktree).map { directoryExists($0.path) } ?? false)

        return WorktreeRowModel(
            name: worktree.displayName,
            leading: leading,
            isNameBold: RowStatusIndicator.shouldBoldName(notification, hasPromptOnScreen: hasPromptOnScreen),
            subtitles: subtitles,
            suffix: suffix,
            showsNoStatusMark: NoStatusMark.rowHelp(terminals: terminals, sightings: appState.noStatusSightings) != nil,
            showsDevServerDot: WorktreeRowView.showsServerDot(
                worktreeID: id, running: appState.devServerRunningWorktreeIDs),
            crossRepoLabel: crossRepoLabel,
            homeRepoID: worktree.repoID,
            isPinned: worktree.pinnedAt != nil,
            depth: depth,
            isDimmed: isDimmed,
            isInHiddenSection: isInHiddenSection,
            isMain: isMain,
            heightClass: subtitles.isEmpty ? .single : .withSubtitle,
            hasRepo: worktree.repoID != nil)
    }

    // MARK: Remote session rows — `RemoteSessionRowView`

    func remoteSession(_ session: RemoteSessionInfo, depth: Int, isInHiddenSection: Bool) -> RemoteSessionRowModel {
        let selection = RemoteSessionSelection(provider: session.provider, sessionID: session.payload.id)
        let unread = appState.unreadByRemoteSession[selection]?.type
        let provider = providersByName[session.provider]
        let caption = RemoteSessionRowView.caption(
            state: session.payload.state, agentState: session.payload.agentState,
            gone: session.gone, exitCode: session.payload.exitCode,
            staleness: RemoteSessionRowView.stalenessCaption(
                health: provider?.health ?? .ok,
                lastSuccessfulSnapshotAt: provider?.lastSuccessfulSnapshotAt ?? session.lastSeen,
                now: now))
        return RemoteSessionRowModel(
            title: appState.remoteSessionDisplayName(
                provider: session.provider, sessionID: session.payload.id, providerTitle: session.payload.title),
            isPending: session.payload.state == .starting,
            isNameBold: RowStatusIndicator.shouldBoldName(unread),
            isExited: session.payload.state == .exited,
            caption: caption,
            suffix: RemoteSessionRowView.suffixIndicator(agentState: session.payload.agentState, unreadType: unread),
            isGone: session.gone,
            isSelected: appState.selectedRemoteSession == selection,
            depth: depth,
            isInHiddenSection: isInHiddenSection)
    }

    // MARK: Headers

    /// `RepoSectionView.headerRow`.
    func repoHeader(_ repo: Repo) -> SectionHeaderModel {
        SectionHeaderModel(
            title: repo.displayName, isExpanded: repo.expanded, isHidden: repo.hidden,
            isMissing: repo.status == .missing, isSelected: appState.selectedRepoID == repo.id)
    }

    /// `ScratchSectionView`'s header.
    func scratchHeader(isExpanded: Bool) -> SectionHeaderModel {
        SectionHeaderModel(
            title: AppState.scratchSectionLabel, isExpanded: isExpanded, isHidden: false,
            isMissing: false, isSelected: appState.selectedScratchSection)
    }

    /// `RemoteProviderHeaderRow`.
    func providerHeader(_ provider: RemoteProviderStatus) -> ProviderHeaderModel {
        ProviderHeaderModel(
            name: RemoteProviderIdentityPresentation.headline(provider),
            health: provider.health,
            issueSummary: RemoteProviderStatusPresentation.issueSummary(provider, now: now),
            isSelected: appState.selectedRemoteProvider == provider.config.name,
            canCreate: RemoteProviderHeaderRow.canCreate(
                provider: provider,
                claudeCloudEnabled: appState.daemonCapabilities?.claudeCloudEnabled ?? false),
            isCreateEnabled: !provider.hasStaleSnapshot)
    }
}
