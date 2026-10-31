import AppKit
import SwiftUI
import TBDShared

/// What the native sidebar's menus ask of the controller: the gestures that
/// need a view — an inline rename, a sheet, a confirmation — and the
/// expansion toggle the chevrons share.
@MainActor
protocol SidebarMenuHost: AnyObject {
    func beginRename(_ id: SidebarNodeID)
    func toggleExpansion(of id: SidebarNodeID)
    func presentSheet<Content: View>(_ content: Content)
    func confirmRemove(_ repo: Repo)
}

/// The native sidebar's context menus, built from the same models the SwiftUI
/// rows render (spec "Context menus, popovers and sheets"), so titles, order,
/// enabled state and actions match:
/// - a worktree row: `RowActionMenu` through `RowActionMenuActions`, then the
///   "New Cloud Session…" / "New Remote Session…" pair `WorktreeRowView` adds;
/// - a repo header: `RepoSectionView.repoContextMenu`'s items — Collapse or
///   Expand, Rename…, Hide or Unhide, the two create items, Remove from List…;
/// - the Scratch header: Collapse or Expand, Edit Scratch Instructions…;
/// - a remote session row: `RemoteSessionActionMenu` through
///   `RemoteSessionActionMenuActions`.
/// Group headers, provider headers and the scratch prompt have none, as in the
/// SwiftUI sidebar. Each menu is built when it is asked for, never per rebuild.
@MainActor
struct SidebarMenus {
    let appState: AppState
    let defaults: UserDefaults
    weak var host: (any SidebarMenuHost)?

    func menu(for node: SidebarNode) -> NSMenu? {
        let items: [NSMenuItem]
        switch node.id {
        case .worktree(let id):
            guard let worktree = appState.findWorktree(id: id) else { return nil }
            items = worktreeItems(worktree)
        case .repoHeader(let id):
            guard let repo = appState.repos.first(where: { $0.id == id }) else { return nil }
            items = repoItems(repo)
        case .scratchHeader:
            items = scratchItems()
        case .remoteSession(let id):
            guard let session = appState.remoteSessions.first(where: { $0.id == id }) else { return nil }
            items = remoteSessionItems(session)
        case .scratchPrompt, .providerHeader, .group:
            return nil
        }
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
        return menu
    }

    // MARK: Worktree rows

    private func worktreeItems(_ worktree: Worktree) -> [NSMenuItem] {
        let host = self.host
        let id = worktree.id
        let actions = RowActionMenuActions(
            appState: appState, worktree: worktree, onRename: { host?.beginRename(.worktree(id)) })
        var items = actions.items().map { item -> NSMenuItem in
            switch item {
            case .action(let action):
                let menuItem = SidebarMenuItem(action.title) { actions.run(action.kind) }
                menuItem.isEnabled = action.isEnabled
                menuItem.toolTip = action.disabledHelp
                return menuItem
            case .divider:
                return .separator()
            case .caption(let text):
                return Self.caption(text)
            }
        }
        items += remoteCreateItems(for: worktree)
        return items
    }

    /// `WorktreeRowView.remoteCreateMenuItems`: one separator, then the cloud
    /// item and the generic item, each omitted when there is nothing to offer
    /// and disabled while its provider's snapshot is stale. Both always open
    /// the form, nested under this row.
    private func remoteCreateItems(for worktree: Worktree) -> [NSMenuItem] {
        let isMain = worktree.status == .main
        let cloud = WorktreeRowView.cloudSessionMenuEntry(
            providers: appState.remoteProviders,
            claudeCloudEnabled: appState.daemonCapabilities?.claudeCloudEnabled ?? false, isMain: isMain)
        let providers = WorktreeRowView.remoteSessionMenuProviders(providers: appState.remoteProviders, isMain: isMain)
        guard cloud != nil || !providers.isEmpty else { return [] }
        let present = { (provider: RemoteProviderStatus) in self.presentCreateSheet(provider, nestedUnder: worktree) }
        return [NSMenuItem.separator()] + createItems(cloud: cloud, providers: providers, present: present)
    }

    private func presentCreateSheet(_ provider: RemoteProviderStatus, nestedUnder worktree: Worktree) {
        let repo = appState.repos.first { $0.id == worktree.repoID }
        host?.presentSheet(RemoteCreateSheet(
            provider: provider.config,
            describe: provider.describe,
            repoPrefill: RemoteCreateFormLogic.repoPrefill(remoteURL: repo?.remoteURL),
            repoDefaults: repo?.remoteCreateDefaults ?? [:],
            parentWorktreeID: worktree.id,
            repoID: worktree.repoID))
    }

    // MARK: Repo headers

    private func repoItems(_ repo: Repo) -> [NSMenuItem] {
        let host = self.host
        let state = appState
        let id = repo.id
        var items: [NSMenuItem] = [
            // Ungated, unlike a trailing chevron: the keyboard path to the
            // same action.
            SidebarMenuItem(repo.expanded ? "Collapse" : "Expand") { host?.toggleExpansion(of: .repoHeader(id)) },
            SidebarMenuItem("Rename...") { host?.beginRename(.repoHeader(id)) },
            SidebarMenuItem(repo.hidden ? "Unhide" : "Hide") {
                let hidden = !repo.hidden
                Task { await state.setRepoHidden(id: id, hidden: hidden) }
            },
        ]
        let cloud = RepoSectionView.cloudSessionMenuEntry(
            providers: appState.remoteProviders,
            claudeCloudEnabled: appState.daemonCapabilities?.claudeCloudEnabled ?? false)
        let providers = RepoSectionView.remoteSessionMenuProviders(providers: appState.remoteProviders)
        items += createItems(cloud: cloud, providers: providers) { provider in
            host?.presentSheet(RemoteCreateSheet(
                provider: provider.config,
                describe: provider.describe,
                repoPrefill: RemoteCreateFormLogic.repoPrefill(remoteURL: repo.remoteURL),
                repoDefaults: repo.remoteCreateDefaults,
                repoID: repo.id))
        }
        items.append(.separator())
        items.append(SidebarMenuItem("Remove from List...") { host?.confirmRemove(repo) })
        return items
    }

    // MARK: The Scratch header

    private func scratchItems() -> [NSMenuItem] {
        let host = self.host
        let state = appState
        return [
            SidebarMenuItem(SidebarBuildOptions(defaults: defaults).scratchExpanded ? "Collapse" : "Expand") {
                host?.toggleExpansion(of: .scratchHeader)
            },
            SidebarMenuItem("Edit Scratch Instructions…") {
                host?.presentSheet(ScratchInstructionsView().environment(state))
            },
        ]
    }

    // MARK: Remote session rows

    private func remoteSessionItems(_ session: RemoteSessionInfo) -> [NSMenuItem] {
        let host = self.host
        let id = session.id
        let actions = RemoteSessionActionMenuActions(
            appState: appState, session: session, onRename: { host?.beginRename(.remoteSession(id)) })
        return actions.items().map { item -> NSMenuItem in
            switch item {
            case .action(let action):
                let menuItem = SidebarMenuItem(action.title) { actions.run(action.kind) }
                menuItem.isEnabled = action.isEnabled
                menuItem.toolTip = action.disabledHelp
                return menuItem
            case .divider:
                return .separator()
            }
        }
    }

    // MARK: Shared pieces

    /// "New Cloud Session…" for the compiled cloud provider, then "New Remote
    /// Session…" over the registry providers — a plain item for one, a submenu
    /// of their headlines for several. Stale providers stay, disabled.
    private func createItems(
        cloud: RemoteProviderStatus?, providers: [RemoteProviderStatus],
        present: @escaping (RemoteProviderStatus) -> Void
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let cloud {
            let item = SidebarMenuItem("New Cloud Session…") { present(cloud) }
            item.isEnabled = !cloud.hasStaleSnapshot
            items.append(item)
        }
        if providers.count == 1, let only = providers.first {
            let item = SidebarMenuItem("New Remote Session…") { present(only) }
            item.isEnabled = !only.hasStaleSnapshot
            items.append(item)
        } else if !providers.isEmpty {
            let parent = NSMenuItem(title: "New Remote Session…", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "New Remote Session…")
            submenu.autoenablesItems = false
            for provider in providers {
                let item = SidebarMenuItem(RemoteProviderIdentityPresentation.headline(provider)) { present(provider) }
                item.isEnabled = !provider.hasStaleSnapshot
                submenu.addItem(item)
            }
            parent.submenu = submenu
            items.append(parent)
        }
        return items
    }

    /// A muted, unclickable footnote, as SwiftUI renders `Text` in a menu.
    private static func caption(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        item.isEnabled = false
        return item
    }
}

/// A menu item that runs a closure.
final class SidebarMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire(_ sender: Any?) {
        handler()
    }
}
