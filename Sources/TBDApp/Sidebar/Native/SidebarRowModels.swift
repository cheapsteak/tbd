import Foundation
import TBDShared

// The values each native sidebar cell draws. One stored property per input
// the matching SwiftUI view reads today, computed once per rebuild by
// `SidebarRowModelFactory`; a cell never reads `AppState`. Text shown only on
// hover — PR freshness, status-badge and no-status tooltips, a provider's
// summary, a remote session's attention reason, a cross-repo row's full repo
// name — is not here: it is computed when the pointer arrives, so a clock
// tick or a tooltip-only change never reconfigures a row.

/// A row's height variant. Heights are fixed per kind and variant, so nothing
/// measures; the cells map each class to a constant.
enum RowHeightClass: Equatable {
    case single
    /// One subtitle line under the name: "Creating worktree…", "Running
    /// setup…", "→ promoted to …", a remote session's caption, a group's
    /// summary or a provider's issue summary.
    case withSubtitle
}

/// What a worktree row's leading slot draws (`WorktreeRowView.leadingIcon`).
enum WorktreeLeadingSlot: Equatable {
    /// The worst-state PR's glyph, as the toolbar icon picks it.
    case prStatus(PRStatusPresentation)
    /// No cached PR, and the last attempt to learn one came back undetermined.
    case prUnknown
    /// The row is still being created.
    case pending
    /// The row's session runs on a remote provider.
    case remote
}

/// Everything a worktree row draws. Mirrors `WorktreeRowView`; each property
/// names the input it stands for.
struct WorktreeRowModel: Equatable {
    /// `worktree.displayName`.
    var name: String
    /// `leadingIcon()`: PR glyph, PR-unknown mark, pending spinner, remote
    /// globe, or nothing. The main row never shows a PR.
    var leading: WorktreeLeadingSlot?
    /// `RowStatusIndicator.shouldBoldName`: an unread notification that asks
    /// for a look, or a prompt on screen.
    var isNameBold: Bool
    /// The lines under the name, in order: the creating subtitle, then the
    /// promoted-to caption.
    var subtitles: [String]
    /// `suffixIcon()`: the trailing status badge; `.working` draws the
    /// typing dots.
    var suffix: SuffixRowIndicator?
    /// `noStatusMark()`: an agent session that has not reported its state
    /// for the whole grace period.
    var showsNoStatusMark: Bool
    /// The green dev-server dot.
    var showsDevServerDot: Bool
    /// The muted "(repo)" suffix on a row nested under another repo's
    /// section, with the repo name shortened as the SwiftUI row shortens it.
    var crossRepoLabel: String?
    /// `worktree.repoID`: the repo the row belongs to, nil for a scratch row.
    /// The cell does not draw it; `SidebarDropPolicy` compares it with a
    /// section's repo to tell a row's own section from another repo's.
    var homeRepoID: UUID?
    /// `worktree.pinnedAt != nil`: the gutter pin shows solid, without hover.
    var isPinned: Bool
    /// The row's visual depth — its outline level below the section header —
    /// which places its content and its hierarchy guide lines. Group headers
    /// count, as their padding does in the SwiftUI sidebar.
    var depth: Int
    /// `AppState.scratchRowIsDimmed`: an unpromoted scratch row whose
    /// directory is missing draws at 0.5 opacity.
    var isDimmed: Bool
    /// The row sits in a hidden repo's section, which draws at 0.55 opacity
    /// (`SidebarView` applies it to the whole `RepoSectionView`).
    var isInHiddenSection: Bool
    /// The repo's main checkout: no PR glyph, no pin, no nested `+`, no rename.
    var isMain: Bool
    /// `.withSubtitle` exactly when `subtitles` is not empty.
    var heightClass: RowHeightClass
    /// `worktree.repoID != nil`. Nesting is repo-only, so a scratch row offers
    /// no nested `+` and no "New nested worktree" action.
    var hasRepo: Bool = false
}

/// A repo or Scratch section header (`RepoSectionView.headerRow`,
/// `ScratchSectionView`'s header). The title carries any emoji the user put
/// in the name; `Repo` has no separate emoji field.
struct SectionHeaderModel: Equatable {
    var title: String
    /// Draws the chevron's direction.
    var isExpanded: Bool
    /// A hidden repo's section draws at 0.55 opacity.
    var isHidden: Bool
    /// A `.missing` repo dims its title and chevron and shows the
    /// "[missing]" badge with "Locate…".
    var isMissing: Bool
    /// `selectedRepoID` or `selectedScratchSection` names this section.
    var isSelected: Bool
}

/// One remote session row (`RemoteSessionRowView`).
struct RemoteSessionRowModel: Equatable {
    /// `remoteSessionDisplayName`: the user's rename, else the provider's
    /// title, else the raw ID.
    var title: String
    /// The session is starting: the leading slot shows the pending spinner
    /// instead of the globe.
    var isPending: Bool
    /// An unread entry that asks for a look.
    var isNameBold: Bool
    /// The process exited: the name draws in the secondary color.
    var isExited: Bool
    /// The state caption under the name, staleness included.
    var caption: String?
    var suffix: SuffixRowIndicator?
    /// The provider no longer reports the session: the row draws at 0.5
    /// opacity.
    var isGone: Bool
    /// `selectedRemoteSession` names this session.
    var isSelected: Bool
    /// The row's visual depth, as for `WorktreeRowModel.depth`.
    var depth: Int
    var isInHiddenSection: Bool

    var heightClass: RowHeightClass { caption == nil ? .single : .withSubtitle }
}

/// One provider header in the Remote section (`RemoteProviderHeaderRow`).
struct ProviderHeaderModel: Equatable {
    /// `RemoteProviderIdentityPresentation.headline`.
    var name: String
    /// Picks the health suffix glyph; `.needsAuth` makes it a button.
    var health: ProviderHealth
    /// The caption line under the name while the provider is unhealthy.
    var issueSummary: String?
    /// `selectedRemoteProvider` names this provider: the row's background
    /// tints.
    var isSelected: Bool
    /// Whether the `+` shows at all.
    var canCreate: Bool
    /// False while the snapshot is stale: the `+` shows, disabled.
    var isCreateEnabled: Bool

    var heightClass: RowHeightClass { issueSummary == nil ? .single : .withSubtitle }
}

/// A Remote, Exited, Ended or Hibernated disclosure (`SidebarGroupHeader`).
struct GroupHeaderModel: Equatable {
    var kind: SidebarGroupID.Kind
    /// The Hibernated group's row count, shown in its title; nil for the
    /// other kinds, whose counts are in `summary`.
    var count: Int?
    /// The summary line under the title ("2 running · 1 exited").
    var summary: String?
    /// The most severe unread state among the group's sessions, which picks
    /// the trailing glyph.
    var attention: NotificationType?
    /// Some session's state is unknown or no longer reported: the question
    /// mark shows when there is no attention glyph.
    var hasUncertainty: Bool
    /// Draws the chevron's direction.
    var isExpanded: Bool
    /// The header's visual depth, as for `WorktreeRowModel.depth`.
    var depth: Int
    var isInHiddenSection: Bool

    var title: String {
        switch kind {
        case .remote: "Remote"
        case .exited: "Exited"
        case .ended: "Ended"
        case .hibernated: "Hibernated (\(count ?? 0))"
        }
    }

    var heightClass: RowHeightClass { summary == nil ? .single : .withSubtitle }
}
