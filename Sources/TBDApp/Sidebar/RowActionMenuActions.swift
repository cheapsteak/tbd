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

    /// This row's worktree when it has a checkout on this disk. The
    /// path-dependent actions (`openInFinder`, `copyPath`) and the hook probe
    /// resolve through it, so none of them can act on a directory that is not
    /// there; `RowActionMenu.Context.pathIsEmpty` is its nil check.
    private var localWorktree: LocalWorktree? {
        LocalWorktree(worktree)
    }

    /// Does a `preSession` hook resolve for this worktree? Uses the SAME
    /// five-step chain the daemon executes (`HookResolver` lives in TBDShared
    /// precisely so this can't drift): app per-repo config → `.worktree-hooks/`
    /// → `conductor.json` → `.dmux-hooks/` → global default.
    ///
    /// A handful of `fileExists` calls, evaluated when the menu is built on
    /// right-click — not per frame. Scratch spaces have no `repoID`, so
    /// `appHookPath` is nil for them and resolution falls through to the
    /// in-directory hook or the global default.
    private var hasPreSessionHook: Bool {
        guard let local = localWorktree else { return false }
        let appHookPath = local.repoID.map {
            TBDConstants.hookPath(repoID: $0, eventName: HookEvent.preSession.rawValue)
        }
        return HookResolver().resolve(
            event: .preSession,
            repoPath: local.path,
            appHookPath: appHookPath
        ) != nil
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
            autoHibernateEnabled: appState.autoHibernateEnabled,
            hasActiveChildren: !appState.children(of: worktree.id).isEmpty,
            pathIsEmpty: localWorktree == nil,
            hasRepoID: worktree.repoID != nil,
            isScratch: worktree.isScratch,
            isPinned: worktree.pinnedAt != nil,
            isNightwatchDesk: worktree.isNightwatchDesk,
            status: worktree.status,
            isPromoted: worktree.promotedToRepoID != nil,
            branch: worktree.branch,
            claudeSessions: claudeSessions,
            hasPreSessionHook: hasPreSessionHook
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

        // Both path actions are hidden when `pathIsEmpty`, so the nil arm is
        // unreachable through the menu — the binding is what proves it.
        case .openInFinder:
            if let local = localWorktree {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: local.path)
            }

        case .copyPath:
            if let local = localWorktree {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(local.path, forType: .string)
            }

        case .copyBranch:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(worktree.branch, forType: .string)

        case .copyLink:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                DeepLink.makeShareableOpenURL(worktree.id).absoluteString,
                forType: .string
            )

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
            // Wake every PARKED session (hibernated or legacy-suspended) in
            // bounded-concurrency batches — NOT a full fan-out (that caused the
            // #367 spawn storm) and NOT the one-per-focus default. One coalesced
            // failure alert for the whole action.
            Task { await appState.wakeAllParkedInWorktree(worktreeID: wtID) }

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

        case .pin:
            let wtID = worktree.id
            Task { await appState.setPinned(worktreeID: wtID, pinned: true) }

        case .unpin:
            let wtID = worktree.id
            Task { await appState.setPinned(worktreeID: wtID, pinned: false) }

        case .rerunPreSessionHook:
            let wtID = worktree.id
            Task { await appState.rerunPreSessionHook(worktreeID: wtID) }

        case .createPreSessionHook:
            // Regular rows always have a repo (isScratch IS repoID == nil), and
            // the menu never offers this to a scratch row. Return rather than
            // assert — a context menu is not a place to crash.
            guard let repoID = worktree.repoID else { return }
            appState.revealPreSessionHookEditor(repoID: repoID)

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
