import Foundation
import TBDShared

/// Typed, ordered action model for a worktree row's action list — the single
/// source of truth shared by BOTH the right-click context menu
/// (`SidebarContextMenu`) and the hover-revealed "…" menu (`RowAccountMenuView`).
///
/// Pure composition on top of a small `Context` of live inputs the surfaces read
/// from `AppState`. No AppKit, no SwiftUI: `role` is our own `ActionRole` and the
/// view maps it to SwiftUI's `.destructive`. `items(worktree:context:)` is a pure
/// function of its inputs, so the ordered structure both surfaces render is
/// directly unit-testable without any `AppState`.
///
/// The account section (per-session info + "Switch account") is intentionally
/// NOT modeled here — it is contributed separately by `RowAccountMenu` and shown
/// only in the "…" menu, above these items. This model is exactly what the
/// right-click menu shows, and exactly the tail of what the "…" menu shows.
enum RowActionMenu {
    // MARK: - Typed model

    /// Stable typed identity for each action, so the view can dispatch to the
    /// right side effect without stringly-typed matching on titles.
    enum Kind: Equatable {
        case newClaudeTerminal
        case newCodexTerminal
        case newShellTerminal
        case rename
        case openInFinder
        case copyPath
        case archiveScratch
        case deleteScratch
        case suspendClaude
        case resumeClaude
        /// Manually hibernate all idle Claude sessions in this worktree.
        case hibernateNow
        /// Wake all hibernated Claude sessions in this worktree.
        case wakeHibernated
        /// Toggle the keep-warm pin (exempt from auto-hibernation) for this
        /// worktree's Claude sessions. Carries the target state.
        case toggleKeepWarm(enable: Bool)
        case createNestedWorktree
        /// Create a child worktree based on THIS worktree's current branch.
        case newWorktreeFromBranch
        case archive
        /// Fork a specific Claude session into a new tab on the same account.
        /// Carries the session's terminal and its own (possibly ambient/nil)
        /// profile, so the dispatcher can resume+fork it.
        case forkSession(terminalID: UUID, profileID: UUID?)
    }

    /// Whether an action reads as destructive. Mapped by the view to SwiftUI's
    /// `ButtonRole.destructive`; kept AppKit/SwiftUI-free so the helper is pure.
    enum ActionRole: Equatable {
        case normal
        case destructive
    }

    /// One selectable action: its typed identity, display title, role, enabled
    /// flag, and an optional disabled-help string (the archive-with-children
    /// explainer).
    struct Action: Equatable {
        let kind: Kind
        let title: String
        let role: ActionRole
        let isEnabled: Bool
        let disabledHelp: String?

        init(kind: Kind,
             title: String,
             role: ActionRole = .normal,
             isEnabled: Bool = true,
             disabledHelp: String? = nil) {
            self.kind = kind
            self.title = title
            self.role = role
            self.isEnabled = isEnabled
            self.disabledHelp = disabledHelp
        }
    }

    /// A single line in the rendered list. Dividers and captions are modeled so
    /// BOTH surfaces render the exact same visual structure.
    enum Item: Equatable {
        case action(Action)
        case divider
        /// A muted caption note (the "To promote: run `tbd scratch promote …`"
        /// line in the scratch branch).
        case caption(String)
    }

    /// A forkable Claude session in this worktree: the terminal to resume, its
    /// own account (nil = ambient), and a human label for disambiguation when a
    /// worktree hosts more than one session.
    struct ClaudeSessionRef: Equatable {
        let terminalID: UUID
        let profileID: UUID?
        let label: String
    }

    /// The small set of live inputs the current `SidebarContextMenu` reads from
    /// `AppState`, lifted into a value type so `items(...)` is a pure function.
    struct Context: Equatable {
        /// Has at least one resumable Claude terminal that is NOT suspended.
        var hasUnsuspendedClaude: Bool
        /// Has at least one resumable Claude terminal that IS suspended.
        var hasSuspendedClaude: Bool
        /// Has at least one Claude terminal eligible for a manual "Hibernate
        /// now" right now (idle-at-rest, not running/waiting/hibernated).
        var hasHibernatableClaude: Bool
        /// Has at least one hibernated Claude terminal (drives "Wake").
        var hasHibernatedClaude: Bool
        /// Has at least one resumable Claude terminal that is NOT keep-warm
        /// pinned (drives "Keep warm").
        var hasUnpinnedClaude: Bool
        /// Has at least one keep-warm-pinned Claude terminal (drives "Allow
        /// hibernation").
        var hasKeepWarmClaude: Bool
        /// Has at least one non-archived child worktree (gates archive).
        var hasActiveChildren: Bool
        /// Worktree path is empty (main/creating rows hide Finder/Copy then).
        var pathIsEmpty: Bool
        /// Backing repo present — nested-worktree creation is repo-only.
        var hasRepoID: Bool
        var isScratch: Bool
        var status: WorktreeStatus
        /// Whether the scratch space has already been promoted (hides the
        /// promote-hint caption).
        var isPromoted: Bool
        /// This worktree's current branch. Empty → "New worktree from this
        /// branch…" is omitted (nothing to base it on).
        var branch: String
        /// Forkable Claude sessions in tab order. Drives the per-session
        /// "Fork session" entries (empty → none).
        var claudeSessions: [ClaudeSessionRef]

        init(hasUnsuspendedClaude: Bool = false,
             hasSuspendedClaude: Bool = false,
             hasHibernatableClaude: Bool = false,
             hasHibernatedClaude: Bool = false,
             hasUnpinnedClaude: Bool = false,
             hasKeepWarmClaude: Bool = false,
             hasActiveChildren: Bool = false,
             pathIsEmpty: Bool = false,
             hasRepoID: Bool = true,
             isScratch: Bool = false,
             status: WorktreeStatus = .active,
             isPromoted: Bool = false,
             branch: String = "",
             claudeSessions: [ClaudeSessionRef] = []) {
            self.hasUnsuspendedClaude = hasUnsuspendedClaude
            self.hasSuspendedClaude = hasSuspendedClaude
            self.hasHibernatableClaude = hasHibernatableClaude
            self.hasHibernatedClaude = hasHibernatedClaude
            self.hasUnpinnedClaude = hasUnpinnedClaude
            self.hasKeepWarmClaude = hasKeepWarmClaude
            self.hasActiveChildren = hasActiveChildren
            self.pathIsEmpty = pathIsEmpty
            self.hasRepoID = hasRepoID
            self.isScratch = isScratch
            self.status = status
            self.isPromoted = isPromoted
            self.branch = branch
            self.claudeSessions = claudeSessions
        }
    }

    // MARK: - Copy

    static let promoteHint =
        "To promote: run `tbd scratch promote <dest>` from a session here"
    static let archiveNeedsChildrenGoneHelp = "Archive nested worktrees first"
    static let forkSessionLabel = "Fork session"
    static let newWorktreeFromBranchLabel = "New worktree from this branch…"
    static let hibernateNowLabel = "Hibernate now"
    static let wakeLabel = "Wake"
    static let keepWarmLabel = "Keep warm"
    static let allowHibernationLabel = "Allow hibernation"

    /// Title for a fork-session action: plain when the worktree hosts a single
    /// Claude session, suffixed with the session label when there are several.
    static func forkSessionTitle(label: String, multiple: Bool) -> String {
        multiple ? "\(forkSessionLabel) — \(label)" : forkSessionLabel
    }

    // MARK: - Composition

    /// The ordered action list for a worktree row. Pure function of `context`;
    /// the three branches map exactly to today's `SidebarContextMenu` branches
    /// (scratch / main-or-creating / regular), preserving item order within each.
    ///
    /// `includeSessionForks` controls whether per-session "Fork session" entries
    /// are part of this list. The right-click menu passes `true` (it has no
    /// account section, so fork lives here); the "…" menu passes `false` and
    /// renders fork inside each account section instead, so it isn't duplicated.
    static func items(context: Context, includeSessionForks: Bool = true) -> [Item] {
        if context.isScratch {
            return scratchItems(context: context, includeSessionForks: includeSessionForks)
        } else if context.status == .main || context.status == .creating {
            return mainItems(context: context)
        } else {
            return regularItems(context: context, includeSessionForks: includeSessionForks)
        }
    }

    /// The per-session fork actions for this worktree, used by the "…" menu's
    /// account section (which renders fork alongside each session's switch
    /// submenu rather than in the shared action block).
    static func sessionForkActions(context: Context) -> [Action] {
        forkActions(context: context)
    }

    /// Hibernation actions for a worktree row: Wake (if any session is
    /// hibernated), Hibernate now (if any is eligible), and the keep-warm
    /// toggle. Shared by the regular and scratch branches so both surfaces
    /// (right-click + "…") stay in lockstep.
    static func hibernationActions(context: Context) -> [Action] {
        var actions: [Action] = []
        if context.hasHibernatedClaude {
            actions.append(Action(kind: .wakeHibernated, title: wakeLabel))
        }
        if context.hasHibernatableClaude {
            actions.append(Action(kind: .hibernateNow, title: hibernateNowLabel))
        }
        // Keep-warm toggle: offer "Keep warm" when any session is still
        // eligible for auto-hibernation, and "Allow hibernation" when any is
        // pinned. (Both can appear if a worktree hosts a mix.)
        if context.hasUnpinnedClaude {
            actions.append(Action(kind: .toggleKeepWarm(enable: true), title: keepWarmLabel))
        }
        if context.hasKeepWarmClaude {
            actions.append(Action(kind: .toggleKeepWarm(enable: false), title: allowHibernationLabel))
        }
        return actions
    }

    private static func forkActions(context: Context) -> [Action] {
        let multiple = context.claudeSessions.count > 1
        return context.claudeSessions.map { session in
            Action(
                kind: .forkSession(terminalID: session.terminalID, profileID: session.profileID),
                title: forkSessionTitle(label: session.label, multiple: multiple)
            )
        }
    }

    private static func scratchItems(context: Context, includeSessionForks: Bool) -> [Item] {
        var items: [Item] = [
            .action(Action(kind: .newClaudeTerminal, title: "New Claude Terminal")),
            .action(Action(kind: .newCodexTerminal, title: "New Codex Terminal")),
            .action(Action(kind: .newShellTerminal, title: "New Shell Terminal")),
        ]
        // Scratch spaces host Claude sessions too — same fork parity as the
        // regular branch (right-click carries fork; the "…" menu's account
        // section renders it instead).
        if includeSessionForks {
            items.append(contentsOf: forkActions(context: context).map(Item.action))
        }
        items.append(contentsOf: hibernationActions(context: context).map(Item.action))
        items.append(contentsOf: [
            .divider,
            .action(Action(kind: .rename, title: "Rename...")),
        ])
        if !context.isPromoted {
            items.append(.caption(promoteHint))
        }
        items.append(contentsOf: [
            .divider,
            .action(Action(kind: .openInFinder, title: "Open in Finder")),
            .action(Action(kind: .copyPath, title: "Copy Path")),
            .divider,
            // `.destructive` for consistency with the repo-worktree Archive even
            // though scratch archive is recoverable and leaves the folder on disk.
            .action(Action(kind: .archiveScratch, title: "Archive", role: .destructive)),
            .action(Action(kind: .deleteScratch, title: "Delete Scratch Space", role: .destructive)),
        ])
        return items
    }

    private static func mainItems(context: Context) -> [Item] {
        // Main / creating worktree: only Finder and Copy Path, and only when a
        // path exists (no rename/archive).
        guard !context.pathIsEmpty else { return [] }
        return [
            .action(Action(kind: .openInFinder, title: "Open in Finder")),
            .action(Action(kind: .copyPath, title: "Copy Path")),
        ]
    }

    private static func regularItems(context: Context, includeSessionForks: Bool) -> [Item] {
        var items: [Item] = [
            .action(Action(kind: .rename, title: "Rename...")),
        ]
        if context.hasUnsuspendedClaude {
            items.append(.action(Action(kind: .suspendClaude, title: "Suspend Claude")))
        }
        if context.hasSuspendedClaude {
            items.append(.action(Action(kind: .resumeClaude, title: "Resume Claude")))
        }
        items.append(contentsOf: hibernationActions(context: context).map(Item.action))
        // Per-session fork — only in surfaces without an account section (the
        // right-click menu). The "…" menu renders fork in its account section.
        if includeSessionForks {
            items.append(contentsOf: forkActions(context: context).map(Item.action))
        }
        // Scratch spaces have no repo, so nesting isn't offered for them.
        if context.hasRepoID {
            items.append(.action(Action(kind: .createNestedWorktree, title: "Create Nested Worktree")))
            // Base a child worktree on this worktree's current branch. Needs a
            // branch to check out — omitted when empty.
            if !context.branch.isEmpty {
                items.append(.action(Action(kind: .newWorktreeFromBranch, title: newWorktreeFromBranchLabel)))
            }
        }
        items.append(.action(Action(
            kind: .archive,
            title: "Archive",
            role: .destructive,
            isEnabled: !context.hasActiveChildren,
            disabledHelp: context.hasActiveChildren ? archiveNeedsChildrenGoneHelp : nil
        )))
        items.append(contentsOf: [
            .divider,
            .action(Action(kind: .openInFinder, title: "Open in Finder")),
            .action(Action(kind: .copyPath, title: "Copy Path")),
        ])
        return items
    }
}
