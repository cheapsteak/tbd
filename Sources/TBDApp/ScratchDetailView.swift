import SwiftUI
import TBDShared

/// Detail pane shown when the "Scratch" sidebar section header is selected
/// (`AppState.selectedScratchSection`). Mirrors `RepoDetailView`'s shell —
/// same segmented-Picker tab bar — but has no `repoID`, since scratch config
/// is global (`Config.scratchInstructions` / `scratchRenamePrompt` /
/// `scratchProfileOverrideID`), not per-row.
struct ScratchDetailView: View {
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
                ScratchArchivedView()
            case .instructions:
                ScratchInstructionsTabView()
            case .settings:
                ScratchSettingsView()
            }
        }
    }
}

/// Settings tab: global model-profile override applied to scratch terminal
/// spawns. Unlike `RepoSettingsView`, this is GLOBAL config (not a `Repo`
/// model field kept in sync via deltas), so it's fetched fresh into local
/// `@State` rather than read from a live in-memory array entry. No env
/// overrides / hooks sections — out of scope for scratch settings.
struct ScratchSettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var scratchProfileOverrideID: UUID?
    @State private var isLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isLoaded {
                    Picker("Model profile override", selection: profileOverrideBinding) {
                        Text("Inherit global default").tag(UUID?.none)
                        ForEach(appState.modelProfiles, id: \.profile.id) { entry in
                            Text(profileLabel(entry: entry)).tag(UUID?.some(entry.profile.id))
                        }
                    }
                    .pickerStyle(.menu)

                    if let caption = profileOverrideCaption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            guard !isLoaded else { return }
            let config = await appState.fetchConfig()
            scratchProfileOverrideID = config?.scratchProfileOverrideID
            isLoaded = true
        }
    }

    private var profileOverrideBinding: Binding<UUID?> {
        Binding(
            get: { scratchProfileOverrideID },
            set: { newValue in
                scratchProfileOverrideID = newValue
                Task {
                    await appState.setScratchProfileOverride(newValue)
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

    private var profileOverrideCaption: String? {
        if let overrideID = scratchProfileOverrideID {
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
