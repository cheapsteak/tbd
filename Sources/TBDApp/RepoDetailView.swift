import SwiftUI
import TBDShared

struct RepoDetailView: View {
    let repoID: UUID

    enum Tab: String, CaseIterable {
        case archived = "Archived"
        case instructions = "Instructions"
        case settings = "Settings"
    }

    @EnvironmentObject var appState: AppState
    @State private var selectedTab: Tab = .archived
    /// Bumped each time a reveal lands, so `RepoSettingsView` re-runs its
    /// scroll even if the Settings tab was already showing.
    @State private var revealNonce: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
            .padding(.vertical, 12)

            Divider()

            switch selectedTab {
            case .archived:
                ArchivedWorktreesView(repoID: repoID)
            case .instructions:
                RepoInstructionsView(repoID: repoID)
                    .id(repoID)
            case .settings:
                RepoSettingsView(repoID: repoID, revealHookNonce: revealNonce)
                    .id(repoID)
            }
        }
        // Fresh mount (no repo was selected before).
        .onAppear { consumeReveal(appState.repoDetailReveal) }
        // Reused instance (another repo was selected, or this one on another tab).
        .onChange(of: appState.repoDetailReveal) { _, reveal in consumeReveal(reveal) }
    }

    /// Apply a reveal addressed to this repo, then clear it so navigating back
    /// does not replay it. Reveals for another repo are ignored, not consumed.
    private func consumeReveal(_ reveal: AppState.RepoDetailReveal?) {
        guard case let .preSessionHook(id) = reveal, id == repoID else { return }
        selectedTab = .settings
        revealNonce += 1
        appState.repoDetailReveal = nil
    }
}

struct RepoSettingsView: View {
    let repoID: UUID
    /// Changes whenever a pre-session-hook reveal lands. `0` = no reveal.
    var revealHookNonce: Int = 0
    @EnvironmentObject var appState: AppState
    /// Drives focus into the pre-session TextEditor once scrolled.
    @FocusState private var focusedHook: RepoHooksSettingsView.HookField?

    private var repo: Repo? {
        appState.repos.first { $0.id == repoID }
    }

    var body: some View {
        if let repo = repo {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Model profile override", selection: profileOverrideBinding(repo: repo)) {
                            Text("Inherit global default").tag(UUID?.none)
                            ForEach(appState.modelProfiles, id: \.profile.id) { entry in
                                Text(profileLabel(entry: entry)).tag(UUID?.some(entry.profile.id))
                            }
                        }
                        .pickerStyle(.menu)

                        if let caption = profileOverrideCaption(repo: repo) {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()
                            .padding(.vertical, 4)

                        EnvOverridesEditor(
                            initial: repo.envOverrides,
                            caption: "Overrides global; overridden by the repo's model profile."
                        ) { await appState.setRepoEnvOverrides(repoID: repo.id, overrides: $0) }

                        Divider()
                            .padding(.vertical, 4)

                        RepoHooksSettingsView(repoID: repoID, focusedHook: $focusedHook)
                    }
                    .padding()
                }
                .onAppear { scrollToHookIfRequested(proxy) }
                .onChange(of: revealHookNonce) { _, _ in scrollToHookIfRequested(proxy) }
            }
        }
    }

    /// Scroll the pre-session hook section into view and focus its editor.
    /// A nonce of 0 means the user opened Settings themselves — leave the
    /// scroll position and focus alone.
    private func scrollToHookIfRequested(_ proxy: ScrollViewProxy) {
        guard revealHookNonce > 0 else { return }
        withAnimation { proxy.scrollTo(RepoHooksSettingsView.preSessionAnchor, anchor: .top) }
        focusedHook = .preSession
    }

    private func profileOverrideBinding(repo: Repo) -> Binding<UUID?> {
        Binding(
            get: { repo.profileOverrideID },
            set: { newValue in
                Task {
                    await appState.setRepoProfileOverride(repoID: repo.id, profileID: newValue)
                }
            }
        )
    }

    private func profileLabel(entry: ModelProfileWithUsage) -> String {
        if let detail = entry.profile.detailCaption {
            return "\(entry.profile.name) — \(detail)"
        }
        return entry.profile.name
    }

    private func profileOverrideCaption(repo: Repo) -> String? {
        if let overrideID = repo.profileOverrideID {
            let name = appState.modelProfiles.first(where: { $0.profile.id == overrideID })?.profile.name ?? "Unknown profile"
            return "Overriding with: \(name)"
        }
        if let defaultID = appState.defaultProfileID,
           let name = appState.modelProfiles.first(where: { $0.profile.id == defaultID })?.profile.name {
            return "Inheriting: \(name)"
        }
        return "Inheriting: Default (claude keychain login)"
    }
}
