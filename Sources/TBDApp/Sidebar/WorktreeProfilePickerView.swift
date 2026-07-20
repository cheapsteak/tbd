import SwiftUI
import TBDShared

/// Menu content shown when the user hovers (or ⌥-clicks) the `+` button next to
/// a repo in the sidebar. Presented in a borderless `FloatingPanel` (see
/// `FloatingMenuAnchor`), not a SwiftUI popover.
///
/// Two in-place pages (NOT nested popovers — those are fragile on macOS):
///  - `.profiles` (default): a fixed "Choose a branch…" drill-in row at the
///    top, then one row per configured model profile. Selecting a profile row
///    one-click-creates a worktree pinned to that profile. (A plain click on
///    the `+` — without opening this menu — already creates a default
///    worktree via repo → scratch → global default precedence, so there is no
///    separate "resolve automatically" row here.)
///  - `.branches`: the reused searchable branch list (`BranchListView`) behind
///    a back affordance. Selecting a branch creates a worktree on that existing
///    branch using the DEFAULT model (accepted tradeoff).
///
/// Modeled on `BranchPickerView` for consistent popover sizing/styling.
struct WorktreeProfilePickerView: View {
    let repoID: UUID
    /// When set, created worktrees are nested under this parent (the nested `+`
    /// on a worktree row). Nil for the repo-header `+` (top-level worktrees).
    var parentWorktreeID: UUID? = nil
    /// True while the pointer is over the trigger `+` button (not the popover
    /// itself) — highlights whichever profile row is the default so the user
    /// can preview the plain-click outcome before the pointer even reaches the
    /// menu. Fades once the pointer moves into the menu and normal per-row
    /// hover takes over.
    var highlightDefaultProfile: Bool = false
    /// Explicit close hook for the `FloatingPanel` presentation, which has no
    /// `@Environment(\.dismiss)` of its own (that's a SwiftUI popover/sheet
    /// concept). Wired to the owning `HoverMenuModel.closeNow()`.
    var onClose: () -> Void = {}
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Page {
        case profiles
        case branches
    }

    @State private var page: Page = .profiles

    var body: some View {
        Group {
            switch page {
            case .profiles:
                profilesPage
            case .branches:
                branchesPage
            }
        }
        .frame(width: 300)
        .frame(minHeight: 320)
        .task {
            // Ensure the list (and usage suffixes) are populated even if the
            // user hasn't opened Settings yet this session.
            if appState.modelProfiles.isEmpty {
                await appState.loadModelProfiles()
            }
        }
    }

    // MARK: - Page 1: profiles

    private var profilesPage: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New worktree with…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // Fixed at the top regardless of profile count: drill into the
            // branch list. The trailing chevron signals in-place navigation.
            ProfilePickerRow(
                title: "Choose a branch…",
                subtitle: "Create on an existing branch",
                systemImage: "arrow.triangle.branch",
                showsChevron: true
            ) {
                page = .branches
            }
            .padding(.top, 2)

            Divider()
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(appState.modelProfiles, id: \.profile.id) { entry in
                    // A not-logged-in OAuth profile is not selectable: dim it
                    // and disable its Button so its tap can't create a
                    // worktree pinned to an account that can't run. apiKey /
                    // bedrock rows report selectable and stay actionable.
                    let isSelectable = ProfileUsagePresentation.isSelectable(entry)
                    let isTheDefault = entry.profile.id == appState.defaultProfileID
                    Group {
                        if entry.profile.kind == .oauth && isSelectable {
                            // Selectable Claude account: always render the
                            // model rail — model selection must not depend on
                            // usage data being available. The subtitle is the
                            // two-bar meter when a snapshot has buckets, else
                            // the same text/skeleton line as the plain rows.
                            ClaudeProfileRow(
                                entry: entry,
                                highlighted: isTheDefault && highlightDefaultProfile,
                                subtitle: claudeRowSubtitle(for: entry),
                                onSelectModel: { model in
                                    pick(profileID: entry.profile.id, model: model)
                                }
                            ) {
                                pick(profileID: entry.profile.id)
                            }
                        } else {
                            let line = ProfileUsagePresentation.menuLine(for: entry)
                            let subtitle = profileSubtitle(for: entry, usageNote: line.secondary)
                            ProfilePickerRow(
                                title: line.primary,
                                subtitle: subtitle.text,
                                highlighted: isTheDefault && highlightDefaultProfile,
                                // Always reserve subtitle height so the row never
                                // shifts, whichever state it resolves to.
                                reservesSubtitle: true,
                                // Skeleton is reserved for the ONE genuine loading
                                // case (logged-in OAuth awaiting its first poll).
                                showsSubtitleSkeleton: subtitle.showsSkeleton
                            ) {
                                pick(profileID: entry.profile.id)
                            }
                        }
                    }
                    .disabled(!isSelectable)
                    .opacity(isSelectable ? 1 : 0.5)
                }
            }
        }
    }

    // MARK: - Page 2: branches

    private var branchesPage: some View {
        VStack(spacing: 0) {
            Button {
                page = .profiles
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            // Reused branch list: selecting a branch creates on that existing
            // branch with the default model and dismisses the whole popover.
            BranchListView(repoID: repoID, parentWorktreeID: parentWorktreeID, onClose: onClose)
        }
    }

    /// `model` is an optional per-spawn Claude model override (the row's model
    /// rail); nil keeps the profile's default model.
    private func pick(profileID: UUID?, model: String? = nil) {
        dismiss()
        onClose()
        appState.createWorktree(repoID: repoID, parentWorktreeID: parentWorktreeID, profileID: profileID, model: model)
    }

    /// Whether a profile row should render the two-bar usage meter (instead of
    /// a text subtitle): an OAuth profile whose snapshot carries at least one of
    /// the session / weekly buckets the meter draws. Every other case (logged-in
    /// awaiting first poll, logged out, apiKey/bedrock) keeps its text subtitle.
    private func showsUsageBars(for entry: ModelProfileWithUsage) -> Bool {
        guard entry.profile.kind == .oauth, ProfileUsagePresentation.isSelectable(entry) else { return false }
        return ProfileUsagePresentation.sessionBucket(entry.usageSnapshot) != nil
            || ProfileUsagePresentation.weeklyAllBucket(entry.usageSnapshot) != nil
    }

    /// Subtitle for a selectable Claude row: the two-bar meter when the
    /// snapshot has buckets, otherwise the same text/skeleton precedence as
    /// `profileSubtitle` (usage note → first-poll skeleton → reserved blank).
    private func claudeRowSubtitle(for entry: ModelProfileWithUsage) -> ClaudeProfileRow.Subtitle {
        if showsUsageBars(for: entry) { return .bars }
        let line = ProfileUsagePresentation.menuLine(for: entry)
        return .text(line.secondary, showsSkeleton: line.secondary == nil && entry.usageSnapshot == nil)
    }

    /// Resolve the fixed-height subtitle for a non-Claude-row profile
    /// (selectable OAuth rows render via `ClaudeProfileRow` instead).
    /// Precedence:
    ///  1. A real usage / login note from `menuLine` (`usageNote`) — shown as-is.
    ///  2. Logged-out OAuth → a plain "not logged in" note (no skeleton).
    ///  3. API-key / Bedrock → the profile's own static kind descriptor.
    private func profileSubtitle(
        for entry: ModelProfileWithUsage,
        usageNote: String?
    ) -> (text: String?, showsSkeleton: Bool) {
        if let usageNote {
            return (usageNote, false)
        }
        switch entry.profile.kind {
        case .oauth:
            // Selectable OAuth never reaches this path; only logged-out rows.
            return ("Not logged in — run /login", false)
        case .apiKey, .bedrock:
            // Static descriptor from ModelProfile — never a loading state.
            if let detail = entry.profile.detailCaption {
                return ("\(entry.profile.kindLabel) · \(detail)", false)
            }
            return (entry.profile.kindLabel, false)
        }
    }
}

/// A selectable Claude (OAuth) profile row. Mirrors `ProfilePickerRow`'s
/// chrome (title, hover highlight); the subtitle is either the two-bar usage
/// meter (`.bars`) or the same fixed-height text/skeleton line as the plain
/// rows (`.text`) so the rail never depends on usage data. The leading slot
/// is a vertical rail of per-spawn model buttons (Fable/Opus/Sonnet):
/// clicking one picks this profile AND requests that model for the spawn;
/// clicking anywhere else on the row keeps the profile's default model. The
/// rail sits OUTSIDE the row's Button so its buttons don't fight the row's
/// hit-testing.
private struct ClaudeProfileRow: View {
    enum Subtitle {
        /// Two-bar usage meter drawn from the entry's snapshot.
        case bars
        /// Single text line; skeleton is reserved for the ONE genuine loading
        /// case (logged-in OAuth awaiting its first poll). Nil text with no
        /// skeleton reserves the line's height so the row doesn't shift.
        case text(String?, showsSkeleton: Bool)
    }

    let entry: ModelProfileWithUsage
    var highlighted: Bool = false
    let subtitle: Subtitle
    var onSelectModel: (String) -> Void = { _ in }
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            ModelRailView(onSelectModel: onSelectModel)
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ProfileLoginPresentation.menuItemTitle(for: entry))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        subtitleView
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Let the row's natural content height (title + subtitle/bars) drive
        // its size — the rail stretches to match, never the other way around,
        // and the popover's minHeight can't balloon the row.
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered || highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var subtitleView: some View {
        switch subtitle {
        case .bars:
            UsageBarsView(snapshot: entry.usageSnapshot)
        case .text(let text, let showsSkeleton):
            if let text, !text.isEmpty {
                subtitleText(text)
            } else if showsSkeleton {
                subtitleText("resets 00:00 · week 00% used")
                    .redacted(reason: .placeholder)
            } else {
                subtitleText(" ")
                    .hidden()
            }
        }
    }

    /// Matches `ProfilePickerRow.subtitleText` so both Claude subtitle states
    /// and the plain rows share font/size/line-limit.
    private func subtitleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// The vertical rail of per-spawn model buttons on a Claude row.
private struct ModelRailView: View {
    let onSelectModel: (String) -> Void

    /// Per-spawn model buttons: label + exact model id.
    private static let models: [(label: String, id: String, help: String)] = [
        ("Fable", "claude-fable-5", "Spawn with Claude Fable 5"),
        ("Opus", "claude-opus-4-8", "Spawn with Claude Opus 4.8"),
        ("Sonnet", "claude-sonnet-5", "Spawn with Claude Sonnet 5"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.models, id: \.id) { model in
                ModelRailButton(title: model.label, help: model.help) {
                    onSelectModel(model.id)
                }
            }
        }
        // Natural width (widest capsule), but stretch vertically to the row's
        // full height so the three buttons divide it into equal-thirds hit
        // areas.
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// One segment of the model rail, styled like a vertical segmented control:
/// the visible surface fills its full third of the rail (full rail width x
/// 1/3 of the row height, minus a 1pt inset between segments), with the
/// label centered. Hover feedback covers the whole segment; the hit area
/// includes the inset so the thirds stay contiguous.
private struct ModelRailButton: View {
    let title: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06))
                )
                .padding(.vertical, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct ProfilePickerRow: View {
    let title: String
    let subtitle: String?
    /// Leading icon; nil renders no icon view (profile rows). The
    /// "Choose a branch…" navigation row keeps its branch icon.
    var systemImage: String? = nil
    var highlighted: Bool = false
    /// When true, a subtitle line is always rendered at full height — real text
    /// when available, otherwise an invisible placeholder — so the row height
    /// never changes across states (no pop-in).
    var reservesSubtitle: Bool = false
    /// When true (and there is no real `subtitle`), render a redacted skeleton
    /// instead of empty space. Reserved for the one genuine loading case.
    var showsSubtitleSkeleton: Bool = false
    /// Trailing drill-in chevron (e.g. the "Choose a branch…" navigation row).
    var showsChevron: Bool = false
    let onSelect: () -> Void

    @State private var isHovered = false

    private var hasSubtitle: Bool {
        if let subtitle, !subtitle.isEmpty { return true }
        return false
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    subtitleLine
                }
                Spacer(minLength: 4)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered || highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var subtitleLine: some View {
        if hasSubtitle {
            subtitleText(subtitle ?? "")
        } else if showsSubtitleSkeleton {
            // Redacted → a subtle skeleton while the first usage poll is in
            // flight (logged-in OAuth only).
            subtitleText("resets 00:00 · week 00% used")
                .redacted(reason: .placeholder)
        } else if reservesSubtitle {
            // No text and nothing loading: hold the line's height so the row
            // stays identical to its usage / skeleton / descriptor siblings.
            subtitleText(" ")
                .hidden()
        }
    }

    /// Shared styling so every subtitle state — usage text, skeleton, a
    /// "not logged in" note, a kind descriptor, or the reserved blank — has an
    /// identical font/size/line-limit and therefore an identical row height.
    private func subtitleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
