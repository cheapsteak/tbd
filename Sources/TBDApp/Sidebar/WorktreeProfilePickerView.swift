import SwiftUI
import TBDShared

/// What the repo-header `+` menu offers as its remote-lane entry point, for a
/// given set of registered providers. Computed by
/// `WorktreeProfilePickerView.remoteLaneOffer(providers:parentWorktreeID:)`,
/// which owns the rules; this type only names the three outcomes.
enum RemoteLaneOffer {
    /// No row at all — no provider is registered.
    case hidden
    /// Exactly one provider: the row goes straight to its create sheet.
    case single(RemoteProviderStatus)
    /// Several providers: the row drills into the provider list page first.
    case chooseProvider([RemoteProviderStatus])
}

/// Menu content shown when the user hovers (or ⌥-clicks) the `+` button next to
/// a repo in the sidebar. Presented in a borderless `FloatingPanel` (see
/// `FloatingMenuAnchor`), not a SwiftUI popover.
///
/// Three in-place pages (NOT nested popovers — those are fragile on macOS):
///  - `.profiles` (default): a fixed "Choose a branch…" drill-in row at the
///    top, then up to two "start something other than a plain local worktree"
///    rows beneath it — an optional "New cloud session" row for the compiled
///    cloud provider (see `cloudLaneEntry`) and an optional "New remote
///    session" row for the providers the user configured themselves (see
///    `remoteLaneOffer`) — then one row per configured model profile.
///    Each of those two rows carries a trailing ellipsis only when selecting
///    it will itself open the create form — never when it drills into the
///    provider list, where the chevron says so.
///    Selecting a profile row one-click-creates a worktree
///    pinned to that profile. (A plain click on the `+` — without opening this
///    menu — already creates a default worktree via repo → scratch → global
///    default precedence, so there is no separate "resolve automatically" row
///    here.)
///  - `.branches`: the reused searchable branch list (`BranchListView`) behind
///    a back affordance. Selecting a branch creates a worktree on that existing
///    branch using the DEFAULT model (accepted tradeoff).
///  - `.remoteProviders`: one row per registered remote provider, reached only
///    when more than one is registered. A third page rather than a nested
///    `Menu`/popover for the same reason `.branches` is one. Each row carries
///    its own trailing ellipsis when selecting that provider will open the
///    create form, since these are the rows that act.
///
/// Width matches `BranchPickerView` for consistent popover styling; height is
/// per-page (see `body`) so the short profiles list isn't padded out to the
/// branch list's minimum.
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
    /// Called with the chosen provider after this menu has closed itself, so
    /// the host can present the remote create sheet. The host owns that sheet
    /// (`RepoSectionView.remoteCreateSheetProvider`,
    /// `WorktreeRowView.remoteCreateSheetProvider`) because this view lives in
    /// a `FloatingPanel` that is about to be torn down. Both call sites wire
    /// it; the default exists only so a preview or a future host can omit it.
    ///
    /// The compiled cloud provider reaches the sheet through this same hook.
    /// It has a row of its own rather than a place in the generic
    /// enumeration — a user who enabled a feature called Claude Cloud is
    /// looking for that name in the position a title occupies — but the row it
    /// gets is an ordinary provider row, so what it hands back here is the
    /// same `RemoteProviderStatus` any other row would.
    var onStartRemoteSession: (RemoteProviderStatus) -> Void = { _ in }
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss

    private enum Page {
        case profiles
        case branches
        case remoteProviders
    }

    @State private var page: Page = .profiles

    var body: some View {
        Group {
            switch page {
            case .profiles:
                profilesPage
            case .branches:
                branchesPage
            case .remoteProviders:
                remoteProvidersPage
            }
        }
        .frame(width: 300)
        // Height is per-page: `.branches` needs a 320pt minimum so the
        // searchable list stays usable, while `.profiles` hugs its rows.
        // `FloatingPanel` never re-fits after `showAsMenu`, and doesn't need
        // to: `NSHostingView`'s default `sizingOptions` constrain the panel to
        // the SwiftUI content's ideal size, so AppKit autolayout resizes the
        // borderless panel in place (top edge pinned) when `page` flips — no
        // explicit `setFrame` hook (cf. `HoverCard.apply`) is required.
        .frame(minHeight: page == .branches ? 320 : nil, alignment: .top)
        .task {
            // Ensure the list (and usage suffixes) are populated even if the
            // user hasn't opened Settings yet this session.
            if appState.modelProfiles.isEmpty {
                await appState.loadModelProfiles()
            }
            // User-gesture-triggered, one-shot fetch. The daemon talks to the
            // Codex app-server API; no background poller or persisted state.
            await appState.loadCodexUsage()
        }
    }

    // MARK: - Page 1: profiles

    private var profilesPage: some View {
        VStack(spacing: 0) {
            profilesPageHeader

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

            // Sit with "Choose a branch…" in the top group of "start
            // something other than a plain local worktree" rows, above the
            // profile list. Cloud first: it is the one entry a user came
            // looking for by name.
            cloudLaneRow
            remoteLaneRow

            Divider()
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(appState.modelProfiles, id: \.profile.id) { entry in
                    // A not-logged-in OAuth profile is not selectable: dim it
                    // and disable its Button so its tap can't create a
                    // worktree pinned to an account that can't run. apiKey /
                    // bedrock rows report selectable and stay actionable.
                    let isSelectable = ProfileUsagePresentation.isSelectable(entry)
                    let isTheDefault = appState.primaryAgentPreference == .claude
                        && entry.profile.id == appState.defaultProfileID
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
                                    pick(profileID: entry.profile.id, model: model, agent: .claude)
                                }
                            ) {
                                pick(profileID: entry.profile.id, agent: .claude)
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
                                pick(profileID: entry.profile.id, agent: .claude)
                            }
                        }
                    }
                    .disabled(!isSelectable)
                    .opacity(isSelectable ? 1 : 0.5)
                }

                Divider()
                    .padding(.vertical, 2)

                CodexPickerRow(
                    usage: appState.codexUsage,
                    isLoading: appState.isLoadingCodexUsage,
                    highlighted: appState.primaryAgentPreference == .codex
                        && highlightDefaultProfile
                ) {
                    pick(profileID: nil, agent: .codex)
                }
            }
        }
    }

    /// Extracted out of `profilesPage` so the conditional title stays a plain
    /// property reference there — same reason the rest of this page is split
    /// into small pieces.
    @ViewBuilder
    private var profilesPageHeader: some View {
        HStack {
            Text(Self.profilesPageTitle(
                offer: remoteLaneOffer, hasCloudEntry: cloudEntry != nil))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// The providers the generic "New remote session" row enumerates — the
    /// ones the user configured themselves. The compiled cloud provider has a
    /// row of its own (`cloudLaneRow`) and is never a member of this list.
    private var offerableProviders: [RemoteProviderStatus] {
        Self.registryLaneProviders(appState.remoteProviders)
    }

    /// The compiled cloud provider's row, or nil when there is none to offer.
    private var cloudEntry: RemoteProviderStatus? {
        Self.cloudLaneEntry(
            providers: appState.remoteProviders,
            claudeCloudEnabled: appState.daemonCapabilities?.claudeCloudEnabled ?? false,
            parentWorktreeID: parentWorktreeID)
    }

    /// What this menu offers as a remote-lane entry point right now.
    private var remoteLaneOffer: RemoteLaneOffer {
        Self.remoteLaneOffer(providers: offerableProviders, parentWorktreeID: parentWorktreeID)
    }

    /// The optional "New cloud session…" row — the compiled provider's own
    /// entry, named so a user who enabled Claude Cloud finds the word they
    /// enabled where a title goes rather than inferring it from a subtitle.
    /// Omitted entirely when the flag is off or the daemon never registered
    /// it; a stale provider keeps its row, disabled, with the reason in its
    /// subtitle (`remoteProviderRow` handles both).
    @ViewBuilder
    private var cloudLaneRow: some View {
        if let entry = cloudEntry {
            remoteProviderRow(
                entry,
                title: Self.cloudLaneRowTitle(opensForm: !willCreateImmediately(entry)),
                subtitle: Self.providerRowSubtitle(entry)
                    ?? "Runs on Anthropic's infrastructure",
                systemImage: Self.cloudLaneSymbol)
        }
    }

    /// The optional "New remote session…" row. Omitted entirely (never shown
    /// disabled) when there is no provider; a stale provider keeps its row but
    /// cannot be selected, matching `RepoSectionView.newRemoteSessionMenuItem`.
    @ViewBuilder
    private var remoteLaneRow: some View {
        let offer = remoteLaneOffer
        switch offer {
        case .hidden:
            EmptyView()
        case .single(let provider):
            remoteProviderRow(
                provider,
                title: Self.remoteLaneRowTitle(offer: offer, opensForm: !willCreateImmediately(provider)),
                subtitle: Self.providerRowSubtitle(provider) ?? "Run on \(Self.providerLabel(provider))"
            )
        case .chooseProvider:
            ProfilePickerRow(
                // The provider list always comes first, so this row does open
                // something whatever the chosen provider then does — but the
                // trailing chevron is what says so here; see
                // `remoteLaneRowTitle(offer:opensForm:)`.
                title: Self.remoteLaneRowTitle(offer: offer, opensForm: true),
                subtitle: "Choose a provider",
                systemImage: Self.remoteLaneSymbol,
                showsChevron: true
            ) {
                page = .remoteProviders
            }
        }
    }

    /// One selectable provider, on either the profiles page (single provider)
    /// or the provider list (several).
    @ViewBuilder
    private func remoteProviderRow(
        _ provider: RemoteProviderStatus,
        title: String,
        subtitle: String?,
        systemImage: String = WorktreeProfilePickerView.remoteLaneSymbol
    ) -> some View {
        ProfilePickerRow(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage
        ) {
            startRemoteSession(provider)
        }
        .disabled(provider.hasStaleSnapshot)
        .opacity(provider.hasStaleSnapshot ? 0.5 : 1)
    }

    /// Shared back affordance for the two drill-in pages.
    @ViewBuilder
    private var backButton: some View {
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
    }

    // MARK: - Page 2: branches

    private var branchesPage: some View {
        VStack(spacing: 0) {
            backButton

            Divider()

            // Reused branch list: selecting a branch creates on that existing
            // branch with the default model and dismisses the whole popover.
            BranchListView(repoID: repoID, parentWorktreeID: parentWorktreeID, onClose: onClose)
        }
    }

    // MARK: - Page 3: remote providers

    private var remoteProvidersPage: some View {
        VStack(spacing: 0) {
            backButton

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.providerList(offer: remoteLaneOffer), id: \.config.name) { provider in
                    remoteProviderRow(
                        provider,
                        // These rows are the ones that act, so each says for
                        // itself whether selecting it will ask first —
                        // decided per provider, from the same inputs the
                        // click uses.
                        title: Self.providerRowTitle(
                            provider, opensForm: !willCreateImmediately(provider)),
                        subtitle: Self.providerRowSubtitle(provider)
                    )
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Remote lane: pure decision helpers

    /// The remote-lane row's copy on the profiles page.
    ///
    /// The trailing ellipsis is a promise, so the row only makes it when it
    /// will keep it: selecting the row opens the create form when some answer
    /// is still needed, and creates outright when every required answer is
    /// already knowable (see `RemoteCreateFormLogic.willCreateImmediately`).
    nonisolated static func remoteLaneRowTitle(opensForm: Bool) -> String {
        opensForm ? "New remote session…" : "New remote session"
    }

    /// The cloud row's copy. Special in placement, not in behavior: it makes
    /// the same ellipsis promise on the same terms as every other row that
    /// acts, decided from the same inputs the click uses.
    nonisolated static func cloudLaneRowTitle(opensForm: Bool) -> String {
        opensForm ? "New cloud session…" : "New cloud session"
    }

    /// The remote-lane row's title for the offer it is rendering — the form
    /// the view calls, and the one place the ellipsis rule lives.
    ///
    /// - `.single`: the promise above, kept exactly when `opensForm`.
    /// - `.chooseProvider`: never an ellipsis, whatever `opensForm` says. That
    ///   row drills into the provider list, which its trailing chevron already
    ///   signals; spending the ellipsis on the same fact doubles the
    ///   signalling, and it would promise a form the provider chosen on the
    ///   next page may never show. Each provider row on that page then makes
    ///   the promise for itself — see `providerRowTitle(_:opensForm:)`.
    /// - `.hidden`: no row renders, and the ellipsis-free copy is the honest
    ///   value for a row that will not act.
    nonisolated static func remoteLaneRowTitle(offer: RemoteLaneOffer, opensForm: Bool) -> String {
        switch offer {
        case .single: return remoteLaneRowTitle(opensForm: opensForm)
        case .chooseProvider, .hidden: return remoteLaneRowTitle(opensForm: false)
        }
    }

    /// A provider row's title on the `.remoteProviders` page: the provider's
    /// display name, carrying the same ellipsis promise the single-provider
    /// row makes.
    ///
    /// These are the rows that actually create, so the signal has to reach
    /// them — a bare provider name says nothing about whether selecting it
    /// will ask first, and the row that sent the user here deliberately makes
    /// no promise on their behalf.
    nonisolated static func providerRowTitle(
        _ provider: RemoteProviderStatus, opensForm: Bool
    ) -> String {
        opensForm ? "\(providerLabel(provider))…" : providerLabel(provider)
    }

    /// Whether selecting this provider's row will create outright — asked with
    /// the SAME inputs the click itself uses (`RepoSectionView` /
    /// `WorktreeRowView`'s `startRemoteSession(with:)`), so the label and the
    /// action cannot disagree.
    private func willCreateImmediately(_ provider: RemoteProviderStatus) -> Bool {
        let repo = appState.repos.first(where: { $0.id == repoID })
        return RemoteCreateFormLogic.willCreateImmediately(
            describe: provider.describe,
            repoPrefill: RemoteCreateFormLogic.repoPrefill(remoteURL: repo?.remoteURL),
            repoDefaults: repo?.remoteCreateDefaults ?? [:],
            globalDefaults: appState.globalRemoteCreateDefaults)
    }

    /// Leading glyph for every remote-lane row — reads as "a machine that is
    /// not this one".
    static let remoteLaneSymbol = "server.rack"

    /// Leading glyph for the cloud row, which names one specific elsewhere
    /// rather than "not this machine" in general.
    static let cloudLaneSymbol = "cloud"

    /// The providers `remoteLaneRow` enumerates — a thin, named forward to
    /// `CloudCreateEntryPresentation.registryProviders` so this view has no
    /// inline gate of its own to drift from what that function pins, and so
    /// the cross-surface parity suite can call the exact list this page shows.
    nonisolated static func registryLaneProviders(
        _ providers: [RemoteProviderStatus]
    ) -> [RemoteProviderStatus] {
        CloudCreateEntryPresentation.registryProviders(providers)
    }

    /// The compiled cloud provider's row, or nil when there is none to offer —
    /// the pure, view-free form of `cloudLaneRow`'s gate, so the cross-surface
    /// parity suite can call the decision this page renders rather than
    /// re-deriving it.
    ///
    /// `parentWorktreeID` is **not** a gate, and the parameter is kept to say
    /// so where a test can pin it, for the same reason `remoteLaneOffer` keeps
    /// it: nesting is TBD-side filing, and the remote side neither knows nor
    /// needs to know about it.
    nonisolated static func cloudLaneEntry(
        providers: [RemoteProviderStatus],
        claudeCloudEnabled: Bool,
        parentWorktreeID: UUID?
    ) -> RemoteProviderStatus? {
        CloudCreateEntryPresentation.cloudEntry(
            providers, claudeCloudEnabled: claudeCloudEnabled)
    }

    /// What the `+` menu offers as its remote-lane entry point.
    ///
    /// One gate: **no provider registered → nothing at all.** Omitting rather
    /// than disabling mirrors `RepoSectionView.newRemoteSessionMenuItem` and
    /// `RemoteSessionActionMenu`, which omit capability-gated items instead of
    /// graying them out. Exactly one provider goes straight to starting a
    /// session with it (which creates outright or opens the create form,
    /// depending on what `RemoteCreateFormLogic.launch` can answer); more than
    /// one drills into the `.remoteProviders` page first.
    ///
    /// `parentWorktreeID` is **not** a gate, and the parameter is kept to say
    /// so where a test can pin it. The nested `+` promises the new lane nests
    /// under that worktree; the create path keeps that promise now
    /// (`RemoteCreateParams.parentWorktreeID` carries the click through to
    /// adoption), so both `+` buttons offer the row on identical terms.
    ///
    /// `nonisolated` so it's directly testable without an `AppState`/view
    /// hierarchy, for the same reason as `RepoSectionView`'s pure helpers.
    nonisolated static func remoteLaneOffer(
        providers: [RemoteProviderStatus],
        parentWorktreeID: UUID?
    ) -> RemoteLaneOffer {
        if providers.count == 1, let only = providers.first { return .single(only) }
        return providers.isEmpty ? .hidden : .chooseProvider(providers)
    }

    /// The providers the `.remoteProviders` page lists — taken from the offer
    /// that sent the user there, so the page cannot show a list the offer
    /// disagrees with. `.single` yields its one provider (the page is not
    /// normally reachable then, but a provider list that empties itself while
    /// the page is open should shrink, not blank), and `.hidden` yields
    /// nothing, which is the same thing the row would have said.
    nonisolated static func providerList(offer: RemoteLaneOffer) -> [RemoteProviderStatus] {
        switch offer {
        case .hidden: return []
        case .single(let only): return [only]
        case .chooseProvider(let all): return all
        }
    }

    /// The page's own header copy. "New worktree with…" stops being true once
    /// the page can also start a remote lane, which is a provider session and
    /// not a worktree — so the title widens exactly when either row is
    /// offered. `hasCloudEntry` is passed rather than inferred because the
    /// cloud row is not a member of `offer`: the two rows are siblings, and
    /// either one alone is enough to make the narrow title false.
    nonisolated static func profilesPageTitle(
        offer: RemoteLaneOffer, hasCloudEntry: Bool
    ) -> String {
        if hasCloudEntry { return "New worktree or remote session…" }
        switch offer {
        case .hidden: return "New worktree with…"
        case .single, .chooseProvider: return "New worktree or remote session…"
        }
    }

    /// Display name for a provider — the negotiated `describe` name when the
    /// provider supplied one, else its configured name (same precedence as
    /// `RepoSectionView.newRemoteSessionMenuItem`).
    nonisolated static func providerLabel(_ provider: RemoteProviderStatus) -> String {
        provider.describe?.name ?? provider.config.name
    }

    /// Why a provider's row is unselectable, or nil when it is selectable.
    /// A stale snapshot means TBD can no longer vouch for what it last saw
    /// from this provider, so its create path is closed off — the same gate
    /// the context-menu item applies.
    nonisolated static func providerRowSubtitle(_ provider: RemoteProviderStatus) -> String? {
        provider.hasStaleSnapshot ? "Unavailable — inventory is stale" : nil
    }

    /// Close this menu BEFORE the host presents its sheet: the picker lives in
    /// a borderless `FloatingPanel`, and a sheet racing a still-open floating
    /// panel is a real macOS failure mode. Same close pair as `pick`.
    private func startRemoteSession(_ provider: RemoteProviderStatus) {
        dismiss()
        onClose()
        onStartRemoteSession(provider)
    }

    /// `model` is an optional per-spawn Claude model override (the row's model
    /// rail); nil keeps the profile's default model.
    private func pick(
        profileID: UUID?,
        model: String? = nil,
        agent: PrimaryAgentPreference
    ) {
        dismiss()
        onClose()
        appState.createWorktree(
            repoID: repoID,
            parentWorktreeID: parentWorktreeID,
            profileID: profileID,
            model: model,
            primaryAgentPreference: agent
        )
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

/// Codex account row backed by a one-shot app-server snapshot. The row stays
/// selectable when usage or account metadata is unavailable: selection only
/// chooses the agent; the CLI remains the authority on whether it can start.
private struct CodexPickerRow: View {
    let usage: CodexUsageResult?
    let isLoading: Bool
    var highlighted = false
    let onSelect: () -> Void

    @State private var isHovered = false

    private var snapshot: CodexRateLimitSnapshot? {
        usage?.rateLimits.first(where: { $0.limitId == "codex" })
            ?? usage?.rateLimits.first
    }

    private var title: String {
        if let email = usage?.account?.email, !email.isEmpty {
            return "Codex — \(email)"
        }
        return "Codex"
    }

    private var subtitle: String {
        if isLoading && usage == nil { return "Loading usage…" }
        if let reason = usage?.unavailableReason { return reason }
        if usage?.account == nil { return "Not logged in" }
        if snapshot?.primary == nil && snapshot?.secondary == nil {
            return usage?.account?.planType.map { "\($0.capitalized) plan" } ?? "Usage unavailable"
        }
        return ""
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let snapshot, snapshot.primary != nil || snapshot.secondary != nil {
                    CodexUsageBarsView(snapshot: snapshot)
                } else {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
}

private struct CodexUsageBarsView: View {
    let snapshot: CodexRateLimitSnapshot

    var body: some View {
        VStack(spacing: 2) {
            if snapshot.rateLimitReachedType != nil || snapshot.spendControlReached == true {
                Text("Limit reached")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let window = snapshot.primary {
                bar(window)
            }
            if let window = snapshot.secondary {
                bar(window)
            }
        }
    }

    private func bar(_ window: CodexRateLimitWindow) -> some View {
        HStack(spacing: 5) {
            Text(Self.durationLabel(window.windowDurationMins))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Self.color(window.usedPercent))
                        .frame(width: geometry.size.width * min(Double(window.usedPercent) / 100, 1))
                }
            }
            .frame(height: 7)
            Text("\(window.usedPercent)%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Self.color(window.usedPercent))
                .frame(width: 34, alignment: .trailing)
            Text(Self.resetLabel(window.resetsAt))
                .font(.system(size: 9, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
        }
    }

    private static func durationLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "lim:" }
        if minutes % (7 * 24 * 60) == 0 { return "\(minutes / (7 * 24 * 60))w:" }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d:" }
        if minutes % 60 == 0 { return "\(minutes / 60)h:" }
        return "\(minutes)m:"
    }

    private static func resetLabel(_ timestamp: Int?) -> String {
        guard let timestamp else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return "at " + date.formatted(date: .omitted, time: .shortened)
    }

    private static func color(_ percent: Int) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .green
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
    @AppStorage(AppState.usageResetTimeStyleKey)
    private var usageResetTimeStyle: ProfileUsagePresentation.ResetTimeStyle = .timeOfReset

    var body: some View {
        HStack(spacing: 6) {
            ModelRailView(onSelectModel: onSelectModel)
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ProfileLoginPresentation.menuItemTitle(for: entry))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    subtitleView
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        // Tighter than the plain rows' 10pt: the usage-bars table should run
        // to within ~8pt of the popover's right edge (the old inner
        // Spacer + shared 10pt inset left ~20pt of dead space there).
        .padding(.trailing, 8)
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
            UsageBarsView(snapshot: entry.usageSnapshot, resetStyle: usageResetTimeStyle)
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

    /// Per-spawn model buttons: label + Claude Code model *alias*.
    ///
    /// Aliases, not pinned ids (`claude-opus-4-8`): the `claude` binary carries
    /// the alias table (`opus` → latest opus, resolved per provider), so a CLI
    /// auto-update picks up each new Opus/Sonnet/Fable with no TBD rebuild.
    /// `ANTHROPIC_MODEL` — how the spawn delivers this (see
    /// `ClaudeSpawnCommandBuilder`) — runs the same resolution as `--model`.
    private static let models: [(label: String, id: String, help: String)] = [
        ("Fable", "fable", "Spawn with the latest Claude Fable"),
        ("Opus", "opus", "Spawn with the latest Claude Opus"),
        ("Sonnet", "sonnet", "Spawn with the latest Claude Sonnet"),
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
