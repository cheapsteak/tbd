import SwiftUI
import TBDShared

struct RepoDetailView: View {
    let repoID: UUID

    enum Tab: String, CaseIterable {
        case archived = "Archived"
        case instructions = "Instructions"
        case settings = "Settings"
    }

    @State private var selectedTab: Tab = .archived

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
                RepoSettingsView(repoID: repoID)
            }
        }
    }
}

struct RepoSettingsView: View {
    let repoID: UUID
    @EnvironmentObject var appState: AppState

    private var repo: Repo? {
        appState.repos.first { $0.id == repoID }
    }

    var body: some View {
        if let repo = repo {
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

                    RepoHooksSettingsView(repoID: repoID)
                }
                .padding()
            }
        }
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
        guard let baseURL = entry.profile.baseURL else { return entry.profile.name }
        if let model = entry.profile.model, !model.isEmpty {
            return "\(entry.profile.name) — via \(baseURL) · \(model)"
        }
        return "\(entry.profile.name) — via \(baseURL)"
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
