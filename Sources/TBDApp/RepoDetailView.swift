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
                    Picker("Claude token", selection: tokenOverrideBinding(repo: repo)) {
                        Text("Inherit global default").tag(UUID?.none)
                        ForEach(appState.claudeTokens, id: \.token.id) { entry in
                            Text(entry.token.name).tag(UUID?.some(entry.token.id))
                        }
                    }
                    .pickerStyle(.menu)

                    if let caption = tokenOverrideCaption(repo: repo) {
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

    private func tokenOverrideBinding(repo: Repo) -> Binding<UUID?> {
        Binding(
            get: { repo.claudeTokenOverrideID },
            set: { newValue in
                Task {
                    await appState.setRepoClaudeTokenOverride(repoID: repo.id, tokenID: newValue)
                }
            }
        )
    }

    private func tokenOverrideCaption(repo: Repo) -> String? {
        if let overrideID = repo.claudeTokenOverrideID {
            let name = appState.claudeTokens.first(where: { $0.token.id == overrideID })?.token.name ?? "Unknown token"
            return "Overriding with: \(name)"
        }
        if let defaultID = appState.globalDefaultClaudeTokenID,
           let name = appState.claudeTokens.first(where: { $0.token.id == defaultID })?.token.name {
            return "Inheriting: \(name)"
        }
        return "Inheriting: Default (claude keychain login)"
    }
}
