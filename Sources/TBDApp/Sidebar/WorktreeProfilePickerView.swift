import SwiftUI
import TBDShared

/// Popover content rendered when the user long-presses or Option-clicks the
/// `+` button next to a repo in the sidebar.
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
        .frame(width: 300, height: 400)
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

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(appState.modelProfiles, id: \.profile.id) { entry in
                        // A not-logged-in OAuth profile is not selectable: dim it
                        // and disable its Button so its tap can't create a
                        // worktree pinned to an account that can't run. apiKey /
                        // bedrock rows report selectable and stay actionable.
                        let isSelectable = ProfileUsagePresentation.isSelectable(entry)
                        let isTheDefault = entry.profile.id == appState.defaultProfileID
                        Group {
                            if showsUsageBars(for: entry) {
                                // OAuth profile with a usage snapshot that has
                                // buckets: render the two-bar meter instead of the
                                // single-line usage text.
                                UsageBarsProfileRow(
                                    entry: entry,
                                    highlighted: isTheDefault && highlightDefaultProfile
                                ) {
                                    pick(profileID: entry.profile.id)
                                }
                            } else {
                                let line = ProfileUsagePresentation.menuLine(for: entry)
                                let subtitle = profileSubtitle(for: entry, usageNote: line.secondary)
                                ProfilePickerRow(
                                    title: line.primary,
                                    subtitle: subtitle.text,
                                    systemImage: "person.crop.circle",
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

    private func pick(profileID: UUID?) {
        dismiss()
        onClose()
        appState.createWorktree(repoID: repoID, parentWorktreeID: parentWorktreeID, profileID: profileID)
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

    /// Resolve the fixed-height subtitle for a profile row. Precedence:
    ///  1. A real usage / login note from `menuLine` (`usageNote`) — shown as-is.
    ///  2. Logged-in OAuth awaiting its first usage poll → skeleton (the ONE
    ///     genuine "loading" state).
    ///  3. Logged-out OAuth → a plain "not logged in" note (no skeleton).
    ///  4. API-key / Bedrock → the profile's own static kind descriptor.
    private func profileSubtitle(
        for entry: ModelProfileWithUsage,
        usageNote: String?
    ) -> (text: String?, showsSkeleton: Bool) {
        if let usageNote {
            return (usageNote, false)
        }
        switch entry.profile.kind {
        case .oauth:
            if ProfileUsagePresentation.isSelectable(entry) {
                // Logged in; skeleton only until the first snapshot lands.
                return (nil, entry.usageSnapshot == nil)
            }
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

/// A profile row whose subtitle is the two-bar usage meter rather than a text
/// line. Mirrors `ProfilePickerRow`'s chrome (icon, title, hover highlight,
/// "default" chip) but hosts `UsageBarsView`, which sizes to its two bars — the
/// fixed-single-line reservation only applies to the text rows.
private struct UsageBarsProfileRow: View {
    let entry: ModelProfileWithUsage
    var highlighted: Bool = false
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ProfileLoginPresentation.menuItemTitle(for: entry))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    UsageBarsView(snapshot: entry.usageSnapshot)
                }
                Spacer(minLength: 4)
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
}

private struct ProfilePickerRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
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
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
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
