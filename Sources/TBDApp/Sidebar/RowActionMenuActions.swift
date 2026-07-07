import AppKit
import SwiftUI
import TBDShared

/// The dispatcher behind the worktree-row right-click menu
/// (`SidebarContextMenu`). Holding `appState + worktree + onRename`, it exposes:
///
/// - `context()` — build the pure `RowActionMenu.Context` from live `AppState`.
/// - `run(_:)` — the single place every side-effecting closure lives, keyed by
///   the typed `RowActionMenu.Kind`.
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

    /// Forkable Claude sessions in tab order, labeled with the shared
    /// session-label helper so a fork entry matches the session's tab label.
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
            hasHibernatableClaude: terminals.contains { $0.isManuallyHibernatable },
            // "Wake" acts on any PARKED session (authoritative hibernatedAt OR
            // legacy suspendedAt) — the unified park state.
            hasHibernatedClaude: terminals.contains { $0.isParked },
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

    /// The ordered items to render.
    func items() -> [RowActionMenu.Item] {
        RowActionMenu.items(context: context())
    }

    /// Run the side effect for a typed action `kind`. The single source of truth
    /// for row-action behavior.
    func run(_ kind: RowActionMenu.Kind) {
        switch kind {
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
            // Wake every PARKED session (hibernated or legacy-suspended).
            let ids = terminals.filter { $0.isParked }.map { $0.id }
            Task {
                // Collect failures and show ONE coalesced alert after the
                // loop — never a modal per terminal (post-reboot every window
                // is dead, and a per-terminal alert becomes a modal storm).
                var failures: [String] = []
                for id in ids {
                    if let failure = await appState.wakeTerminal(
                        terminalID: id, worktreeID: wtID, userInitiated: true
                    ) {
                        failures.append(failure)
                    }
                }
                if let message = AppState.coalescedWakeFailureMessage(failures: failures) {
                    appState.showAlert(message, isError: true)
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

}

// MARK: - Rendering

/// SwiftUI rendering of `RowActionMenu.Item`s into `Button`/`Divider`/`Text`,
/// dispatching each action through `RowActionMenuActions`. Used by the
/// right-click `SidebarContextMenu`.
struct RowActionMenuItemsView: View {
    let actions: RowActionMenuActions

    var body: some View {
        ForEach(Array(actions.items().enumerated()), id: \.offset) { _, item in
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
