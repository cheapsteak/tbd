import Foundation
import TBDShared

/// Typed, ordered action model for a worktree row's action list — the single
/// source of truth behind the right-click context menu (`SidebarContextMenu`).
///
/// Pure composition on top of a small `Context` of live inputs the surface reads
/// from `AppState`. No AppKit, no SwiftUI: `role` is our own `ActionRole` and the
/// view maps it to SwiftUI's `.destructive`. `items(context:)` is a pure
/// function of its inputs, so the ordered structure the menu renders is
/// directly unit-testable without any `AppState`.
///
/// Per-session account facts and switching are intentionally NOT modeled here —
/// they live in the tab bar, not on the worktree row.
enum RowActionMenu {
    // MARK: - Typed model

    /// Stable typed identity for each action, so the view can dispatch to the
    /// right side effect without stringly-typed matching on titles.
    enum Kind: Equatable {
        case rename
        case openInFinder
        case copyPath
        case copyBranch
        /// Copy the shareable https deep link that opens this worktree.
        case copyLink
        case archiveScratch
        case deleteScratch
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
        /// Pin this worktree to the sidebar dock.
        case pin
        /// Remove this worktree from the sidebar dock.
        case unpin
        /// Re-run this worktree's `preSession` hook in a fresh, non-focused tab.
        case rerunPreSessionHook
        /// Reveal the repo's pre-session hook editor so the user can author one.
        case createPreSessionHook
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
        /// The global "Auto-hibernate idle Claude sessions" master switch is on.
        /// Keep-warm (exempt-from-auto-hibernation) is meaningless when off, so
        /// the toggle is hidden then.
        var autoHibernateEnabled: Bool
        /// Has at least one non-archived child worktree (gates archive).
        var hasActiveChildren: Bool
        /// Worktree path is empty (main/creating rows hide Finder/Copy then).
        var pathIsEmpty: Bool
        /// Backing repo present — nested-worktree creation is repo-only.
        var hasRepoID: Bool
        var isScratch: Bool
        /// Already pinned to the sidebar dock — selects Unpin over Pin.
        var isPinned: Bool
        /// The mode-managed Watch Desk. Neither Pin nor Unpin is offered: the
        /// sidebar's Day/Night toggle is what controls whether it is shown.
        var isNightwatchDesk: Bool
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
        /// A `preSession` hook resolves for this worktree. Selects between the
        /// re-run and create items. Resolved by the surface via the shared
        /// `HookResolver`, so `items(...)` stays pure.
        var hasPreSessionHook: Bool
        /// Where this worktree's files live. `.local` is unaffected by the
        /// capability gate below; a `.remote` row is the one Archive checks
        /// `providerCapabilities` for.
        var location: WorktreeLocation
        /// The remote lane's provider name (`location`'s associated
        /// `provider`), or nil for a local row.
        var provider: String?
        /// Capabilities the row's provider has declared (`describe.capabilities`,
        /// read by the surface via `AppState.remoteProviders`). Empty for a
        /// local row, or a remote one whose provider hasn't answered `describe`
        /// yet. Gates Archive: a remote lane whose provider has not declared
        /// `archive` cannot retire the lane on the backend, so the action stays
        /// disabled until it does.
        var providerCapabilities: Set<String>
        /// The provider has stopped enumerating this lane's session
        /// (`RemoteSessionInfo.gone`). The `gone` exemption is the only route
        /// out for a lane whose provider cannot archive
        /// (`docs/specs/2026-08-16-remote-lane-archive-design.md` §"Archive"),
        /// and the daemon takes it — so the menu must not disable the one
        /// gesture the daemon will still perform. Always `false` for a local
        /// row.
        var isGone: Bool

        init(hasHibernatableClaude: Bool = false,
             hasHibernatedClaude: Bool = false,
             hasUnpinnedClaude: Bool = false,
             hasKeepWarmClaude: Bool = false,
             autoHibernateEnabled: Bool = true,
             hasActiveChildren: Bool = false,
             pathIsEmpty: Bool = false,
             hasRepoID: Bool = true,
             isScratch: Bool = false,
             isPinned: Bool = false,
             isNightwatchDesk: Bool = false,
             status: WorktreeStatus = .active,
             isPromoted: Bool = false,
             branch: String = "",
             claudeSessions: [ClaudeSessionRef] = [],
             hasPreSessionHook: Bool = false,
             location: WorktreeLocation = .local,
             provider: String? = nil,
             providerCapabilities: Set<String> = [],
             isGone: Bool = false) {
            self.hasHibernatableClaude = hasHibernatableClaude
            self.hasHibernatedClaude = hasHibernatedClaude
            self.hasUnpinnedClaude = hasUnpinnedClaude
            self.hasKeepWarmClaude = hasKeepWarmClaude
            self.autoHibernateEnabled = autoHibernateEnabled
            self.hasActiveChildren = hasActiveChildren
            self.pathIsEmpty = pathIsEmpty
            self.hasRepoID = hasRepoID
            self.isScratch = isScratch
            self.isPinned = isPinned
            self.isNightwatchDesk = isNightwatchDesk
            self.status = status
            self.isPromoted = isPromoted
            self.branch = branch
            self.claudeSessions = claudeSessions
            self.hasPreSessionHook = hasPreSessionHook
            self.location = location
            self.provider = provider
            self.providerCapabilities = providerCapabilities
            self.isGone = isGone
        }
    }

    // MARK: - Copy

    static let promoteHint =
        "To promote: run `tbd scratch promote <dest>` from a session here"
    static let archiveNeedsChildrenGoneHelp = "Archive nested worktrees first"
    /// Archive title when the row still has active nested children: the action
    /// stays visible (and destructive-styled) but is disabled, and the title
    /// itself explains why, since menu tooltips are easy to miss.
    static let archiveHasChildrenLabel = "Archive (has children)"
    /// Archive title for a remote lane whose provider has not declared the
    /// `archive` capability: same visible-but-disabled treatment as
    /// `archiveHasChildrenLabel`, naming what's missing rather than
    /// implying anything about the user or the session's own state.
    static let archiveProviderCannotArchiveLabel = "Archive (provider can't archive)"
    /// Disabled-help paired with `archiveProviderCannotArchiveLabel`: names the
    /// capability that would need to exist, not an action for the user to take.
    static let archiveNeedsProviderCapabilityHelp = "This provider hasn't implemented the archive capability yet"
    static let forkSessionLabel = "Fork session"
    static let newWorktreeFromBranchLabel = "New worktree from this branch…"
    static let hibernateNowLabel = "Hibernate now"
    static let wakeLabel = "Wake"
    static let keepWarmLabel = "Keep warm"
    static let allowHibernationLabel = "Allow hibernation"
    static let rerunPreSessionLabel = "Re-run pre-session hook"
    static let pinLabel = "Pin to dock"
    static let unpinLabel = "Unpin from dock"
    /// Trailing character is U+2026 HORIZONTAL ELLIPSIS — the macOS convention
    /// for an item that opens further UI rather than acting immediately.
    static let createPreSessionLabel = "Create pre-session hook…"

    /// Title for a fork-session action: plain when the worktree hosts a single
    /// Claude session, suffixed with the session label when there are several.
    static func forkSessionTitle(label: String, multiple: Bool) -> String {
        multiple ? "\(forkSessionLabel) — \(label)" : forkSessionLabel
    }

    // MARK: - Composition

    /// The ordered action list for a worktree row. Pure function of `context`,
    /// with three branches (scratch / main-or-creating / regular). The regular
    /// and scratch branches share a sectioned layout, top to bottom:
    ///
    /// 1. Identity — Rename, then Archive (destructive; disabled + retitled
    ///    "Archive (has children)" for a regular row with active children, or
    ///    "Archive (provider can't archive)" for a remote lane whose provider
    ///    has not declared the `archive` capability — active children wins
    ///    when a remote row hits both).
    /// 2. Hibernation — Wake / Hibernate now / keep-warm toggle (conditional).
    /// 3. Sessions & spawning — per-session Fork entries, plus (regular only)
    ///    Create Nested Worktree / New worktree from this branch.
    /// 4. Maintenance — Re-run pre-session hook when one resolves, else Create
    ///    pre-session hook… (repo-backed rows only).
    /// 5. Filesystem — Open in Finder, Copy Path, Copy Link.
    /// 6. (scratch only) Delete Scratch Space, with the promote-hint caption
    ///    beneath it.
    ///
    /// Sections are joined with a single divider each; empty sections collapse,
    /// so the list never renders doubled or dangling dividers.
    static func items(context: Context) -> [Item] {
        if context.isScratch {
            return scratchItems(context: context)
        } else if context.status == .main || context.status == .creating {
            return mainItems(context: context)
        } else {
            return regularItems(context: context)
        }
    }

    /// Hibernation actions for a worktree row: Wake (if any session is
    /// hibernated), Hibernate now (if any is eligible), and the keep-warm
    /// toggle. Shared by the regular and scratch branches so both stay in
    /// lockstep.
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
        // pinned. (Both can appear if a worktree hosts a mix.) Meaningless
        // when the global auto-hibernate switch is off, so hidden then.
        if context.autoHibernateEnabled {
            if context.hasUnpinnedClaude {
                actions.append(Action(kind: .toggleKeepWarm(enable: true), title: keepWarmLabel))
            }
            if context.hasKeepWarmClaude {
                actions.append(Action(kind: .toggleKeepWarm(enable: false), title: allowHibernationLabel))
            }
        }
        return actions
    }

    /// The maintenance section. Three states: re-run when a `preSession` hook
    /// resolves; otherwise an offer to create one; and, for a scratch space,
    /// nothing at all — it has no repo, so there is no hooks editor to reveal,
    /// and `joined(...)` collapses the empty section with no dangling divider.
    static func maintenanceActions(context: Context) -> [Action] {
        if context.hasPreSessionHook {
            return [Action(kind: .rerunPreSessionHook, title: rerunPreSessionLabel)]
        }
        guard context.hasRepoID else { return [] }
        return [Action(kind: .createPreSessionHook, title: createPreSessionLabel)]
    }

    /// Pin / unpin the sidebar-dock entry. Empty for the Watch Desk — it is
    /// mode-driven, and `joined(...)` collapses the empty section so no dangling
    /// divider appears.
    static func pinActions(context: Context) -> [Action] {
        guard !context.isNightwatchDesk else { return [] }
        return [context.isPinned
            ? Action(kind: .unpin, title: unpinLabel)
            : Action(kind: .pin, title: pinLabel)]
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

    /// Join non-empty sections with a single `.divider` between them. Empty
    /// sections (e.g. no hibernation-eligible sessions) collapse entirely, so
    /// the rendered list never shows doubled dividers or a leading/trailing one.
    private static func joined(_ sections: [[Item]]) -> [Item] {
        Array(sections.filter { !$0.isEmpty }.joined(separator: [Item.divider]))
    }

    /// Filesystem section: Open in Finder, Copy Path, Copy Link, and Copy
    /// Branch Name (the last only when the worktree has a branch to copy).
    /// Shared by all three branches so they stay in lockstep.
    private static func filesystemActions(context: Context) -> [Item] {
        var items: [Item] = [
            .action(Action(kind: .openInFinder, title: "Open in Finder")),
            .action(Action(kind: .copyPath, title: "Copy Path")),
            .action(Action(kind: .copyLink, title: "Copy Link")),
        ]
        if !context.branch.isEmpty {
            items.append(.action(Action(kind: .copyBranch, title: "Copy Branch Name")))
        }
        return items
    }

    private static func scratchItems(context: Context) -> [Item] {
        // Trailing section: Delete stays last among the actions; the
        // promote-hint caption sits beneath it as the menu's footnote.
        var trailing: [Item] = [
            .action(Action(kind: .deleteScratch, title: "Delete Scratch Space", role: .destructive)),
        ]
        if !context.isPromoted {
            trailing.append(.caption(promoteHint))
        }
        return joined([
            [
                .action(Action(kind: .rename, title: "Rename...")),
                // `.destructive` for consistency with the repo-worktree Archive
                // even though scratch archive is recoverable and leaves the
                // folder on disk.
                .action(Action(kind: .archiveScratch, title: "Archive", role: .destructive)),
            ],
            pinActions(context: context).map(Item.action),
            hibernationActions(context: context).map(Item.action),
            // Scratch spaces host Claude sessions too — same fork entries as
            // the regular branch.
            forkActions(context: context).map(Item.action),
            maintenanceActions(context: context).map(Item.action),
            filesystemActions(context: context),
            trailing,
        ])
    }

    private static func mainItems(context: Context) -> [Item] {
        // Main / creating worktree: only Finder and Copy Path (+ Copy Branch
        // Name when applicable), and only when a path exists (no
        // rename/archive).
        guard !context.pathIsEmpty else { return [] }
        return filesystemActions(context: context)
    }

    private static func regularItems(context: Context) -> [Item] {
        // A remote lane whose provider has not declared `archive` cannot be
        // retired on the backend (docs/specs/2026-08-16-remote-lane-archive-design.md
        // "Archive"), so Archive gates on two independent conditions. When
        // both apply — a remote lane with active children AND no `archive`
        // capability — active children wins the title: it is the reason the
        // user can act on right now (archive the children), while a missing
        // provider capability is not something a gesture here can fix. Order
        // in the `if`/`else if` below is the precedence.
        //
        // A `gone` lane is exempt from the capability gate entirely. The spec
        // calls the `gone` exemption "the only route out for a lane whose
        // provider cannot archive", and the daemon takes it — `archivePlan`
        // returns `.rowOnlyGone` for exactly this shape and files the row
        // without invoking any verb. Disabling Archive here would leave the
        // surface blocking the one gesture the daemon will still perform, with
        // no other way out. The exemption is narrow: a lane the provider still
        // enumerates stays disabled, and active children still win above it.
        let missingArchiveCapability = !context.location.isLocal
            && !context.isGone
            && !context.providerCapabilities.contains("archive")
        let archiveBlocked = context.hasActiveChildren || missingArchiveCapability
        let archiveTitle: String
        let archiveHelp: String?
        if context.hasActiveChildren {
            archiveTitle = archiveHasChildrenLabel
            archiveHelp = archiveNeedsChildrenGoneHelp
        } else if missingArchiveCapability {
            archiveTitle = archiveProviderCannotArchiveLabel
            archiveHelp = archiveNeedsProviderCapabilityHelp
        } else {
            archiveTitle = "Archive"
            archiveHelp = nil
        }

        // Sessions & spawning: per-session fork entries, then the
        // nested-worktree creators.
        var spawning: [Item] = forkActions(context: context).map(Item.action)
        // Nested-worktree creation is repo-only.
        if context.hasRepoID {
            spawning.append(.action(Action(kind: .createNestedWorktree, title: "Create Nested Worktree")))
            // Base a child worktree on this worktree's current branch. Needs a
            // branch to check out — omitted when empty.
            if !context.branch.isEmpty {
                spawning.append(.action(Action(kind: .newWorktreeFromBranch, title: newWorktreeFromBranchLabel)))
            }
        }

        return joined([
            [
                .action(Action(kind: .rename, title: "Rename...")),
                .action(Action(
                    kind: .archive,
                    title: archiveTitle,
                    role: .destructive,
                    isEnabled: !archiveBlocked,
                    disabledHelp: archiveHelp
                )),
            ],
            pinActions(context: context).map(Item.action),
            hibernationActions(context: context).map(Item.action),
            spawning,
            maintenanceActions(context: context).map(Item.action),
            filesystemActions(context: context),
        ])
    }
}
