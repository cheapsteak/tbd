import AppKit
import SwiftUI
import TBDShared

/// The shared dispatcher behind BOTH worktree-row action surfaces (the
/// right-click `SidebarContextMenu` and the hover "…" menu in
/// `RowAccountMenuView`). Holding `appState + worktree + onRename`, it exposes:
///
/// - `context()` — build the pure `RowActionMenu.Context` from live `AppState`.
/// - `run(_:)` — the single place every side-effecting closure lives, keyed by
///   the typed `RowActionMenu.Kind`, so behavior can never drift between the two
///   surfaces.
///
/// `@MainActor` because it reads/mutates `AppState` and touches AppKit
/// (`NSWorkspace`, `NSPasteboard`).
@MainActor
struct RowActionMenuActions {
    let appState: AppState
    let worktree: Worktree
    let onRename: () -> Void

    private var terminals: [Terminal] {
        appState.terminals[worktree.id] ?? []
    }

    /// Forkable Claude sessions in tab order, labeled with the same helper the
    /// account section uses so a session's fork entry matches its header.
    private var claudeSessions: [RowActionMenu.ClaudeSessionRef] {
        let claudeTerminals = terminals.filter { $0.kind == .claude || $0.isClaudeResumable }
        var index = 0
        return claudeTerminals.map { terminal in
            index += 1
            return RowActionMenu.ClaudeSessionRef(
                terminalID: terminal.id,
                profileID: terminal.profileID,
                label: RowAccountMenu.sessionLabel(terminal: terminal, fallbackIndex: index)
            )
        }
    }

    /// Build the pure model context from live `AppState`. Mirrors exactly the
    /// inputs the old `SidebarContextMenu` read inline.
    func context() -> RowActionMenu.Context {
        RowActionMenu.Context(
            hasUnsuspendedClaude: terminals.contains {
                $0.isClaudeResumable && $0.suspendedAt == nil
            },
            hasSuspendedClaude: terminals.contains {
                $0.isClaudeResumable && $0.suspendedAt != nil
            },
            hasHibernatableClaude: terminals.contains { $0.isManuallyHibernatable },
            hasHibernatedClaude: terminals.contains { $0.isHibernated },
            hasUnpinnedClaude: terminals.contains {
                $0.isClaudeResumable && !$0.keepWarm && !$0.isHibernated
            },
            hasKeepWarmClaude: terminals.contains {
                $0.isClaudeResumable && $0.keepWarm
            },
            hasActiveChildren: !appState.children(of: worktree.id).isEmpty,
            pathIsEmpty: worktree.path.isEmpty,
            hasRepoID: worktree.repoID != nil,
            isScratch: worktree.isScratch,
            status: worktree.status,
            isPromoted: worktree.promotedToRepoID != nil,
            branch: worktree.branch,
            claudeSessions: claudeSessions
        )
    }

    /// The ordered items to render. `includeSessionForks` is `true` for the
    /// right-click menu (fork lives in the shared list) and `false` for the "…"
    /// menu (fork lives in its account section, so it isn't duplicated here).
    func items(includeSessionForks: Bool = true) -> [RowActionMenu.Item] {
        RowActionMenu.items(context: context(), includeSessionForks: includeSessionForks)
    }

    /// Per-session fork actions for the "…" menu's account section.
    func sessionForkActions() -> [RowActionMenu.Action] {
        RowActionMenu.sessionForkActions(context: context())
    }

    /// Run the side effect for a typed action `kind`. The single source of truth
    /// for row-action behavior.
    func run(_ kind: RowActionMenu.Kind) {
        switch kind {
        case .newClaudeTerminal:
            let wtID = worktree.id
            Task { await appState.createClaudeTerminal(worktreeID: wtID) }

        case .newCodexTerminal:
            let wtID = worktree.id
            Task { await appState.createCodexTerminal(worktreeID: wtID) }

        case .newShellTerminal:
            let wtID = worktree.id
            Task { await appState.createTerminal(worktreeID: wtID) }

        case .rename:
            onRename()

        case .openInFinder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)

        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(worktree.path, forType: .string)

        case .archiveScratch:
            let wtID = worktree.id
            Task { await appState.archiveScratch(id: wtID) }

        case .deleteScratch:
            let wtID = worktree.id
            Task { await appState.deleteScratch(id: wtID) }

        case .suspendClaude:
            suspendClaude()

        case .resumeClaude:
            let wtID = worktree.id
            Task {
                try? await appState.daemonClient.worktreeResume(worktreeID: wtID)
                await appState.refreshTerminals(worktreeID: wtID)
            }

        case .hibernateNow:
            let wtID = worktree.id
            let ids = terminals.filter { $0.isManuallyHibernatable }.map { $0.id }
            Task {
                for id in ids {
                    await appState.hibernateTerminal(terminalID: id, worktreeID: wtID)
                }
            }

        case .wakeHibernated:
            let wtID = worktree.id
            let ids = terminals.filter { $0.isHibernated }.map { $0.id }
            Task {
                for id in ids {
                    await appState.wakeTerminal(terminalID: id, worktreeID: wtID)
                }
            }

        case let .toggleKeepWarm(enable):
            let wtID = worktree.id
            // Only flip terminals not already in the requested state.
            let ids = terminals
                .filter { $0.isClaudeResumable && $0.keepWarm != enable && !$0.isHibernated }
                .map { $0.id }
            Task {
                for id in ids {
                    await appState.setTerminalKeepWarm(terminalID: id, keepWarm: enable, worktreeID: wtID)
                }
            }

        case .createNestedWorktree:
            guard let repoID = worktree.repoID else { return }
            appState.createWorktree(repoID: repoID, parentWorktreeID: worktree.id)

        case .newWorktreeFromBranch:
            guard let repoID = worktree.repoID, !worktree.branch.isEmpty else { return }
            appState.createWorktree(
                repoID: repoID,
                parentWorktreeID: worktree.id,
                existingBranch: BranchInfo(name: worktree.branch,
                                           localName: worktree.branch,
                                           isRemote: false)
            )

        case .archive:
            let wtID = worktree.id
            Task { await appState.archiveWorktree(id: wtID) }

        case let .forkSession(terminalID, profileID):
            // Duplicate the conversation into a NEW tab on the SAME account —
            // swapTerminalProfile with the session's own profileID (nil = same
            // ambient login), in `.fork` mode so the daemon forks into a new
            // tab rather than switching in place.
            Task { await appState.swapTerminalProfile(terminalID: terminalID, newProfileID: profileID, mode: .fork) }
        }
    }

    /// Suspend all unsuspended resumable Claude terminals. Screenshot-capture +
    /// suspending-state + poll-until-suspended loop preserved byte-for-byte from
    /// the original `SidebarContextMenu` implementation.
    private func suspendClaude() {
        let wtID = worktree.id
        let claudeTerminalIDs = terminals
            .filter { $0.isClaudeResumable && $0.suspendedAt == nil }
            .map { $0.id }
        // Capture screenshot synchronously before any state change
        for id in claudeTerminalIDs {
            if let screenshot = appState.snapshotProviders[id]?() {
                appState.setSuspendingSnapshot(screenshot, for: id)
            }
        }
        // Now set suspending state (removes TerminalPanelView, shows screenshot)
        claudeTerminalIDs.forEach { appState.suspendingTerminalIDs.insert($0) }
        Task {
            try? await appState.daemonClient.worktreeSuspend(worktreeID: wtID)
            // Poll until all Claude terminals are suspended (daemon now async)
            // 200ms intervals for first 2s, 500ms after — up to 15s total
            for i in 0..<30 {
                await appState.refreshTerminals(worktreeID: wtID)
                let updated = appState.terminals[wtID] ?? []
                if claudeTerminalIDs.allSatisfy({ id in
                    updated.first(where: { $0.id == id })?.suspendedAt != nil
                }) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(i < 10 ? 200 : 500))
            }
            claudeTerminalIDs.forEach {
                appState.suspendingTerminalIDs.remove($0)
                appState.removeSuspendingSnapshot(for: $0)
            }
        }
    }
}

// MARK: - Rendering

/// Shared SwiftUI rendering of `RowActionMenu.Item`s into `Button`/`Divider`/
/// `Text`, dispatching each action through the shared `RowActionMenuActions`.
/// Used by both the right-click menu and the "…" menu so the two surfaces render
/// an identical structure.
struct RowActionMenuItemsView: View {
    let actions: RowActionMenuActions
    /// See `RowActionMenuActions.items(includeSessionForks:)`. Right-click passes
    /// `true`; the "…" menu passes `false` (fork lives in its account section).
    var includeSessionForks: Bool = true

    var body: some View {
        ForEach(Array(actions.items(includeSessionForks: includeSessionForks).enumerated()), id: \.offset) { _, item in
            switch item {
            case let .action(action):
                actionButton(action)
            case .divider:
                Divider()
            case let .caption(text):
                Text(text).font(.caption)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: RowActionMenu.Action) -> some View {
        Button(role: action.role == .destructive ? .destructive : nil) {
            actions.run(action.kind)
        } label: {
            Text(action.title)
        }
        .disabled(!action.isEnabled)
        .help(action.disabledHelp ?? "")
    }
}
