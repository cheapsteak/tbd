import AppKit
import SwiftUI
import TBDShared
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            RepositoriesSettingsTab()
                .tabItem {
                    Label("Repositories", systemImage: "folder")
                }

            TerminalSettingsView()
                .tabItem {
                    Label("Terminal", systemImage: "terminal")
                }

            ModelProfilesSettingsView()
                .tabItem { Label("Model Profiles", systemImage: "key.fill") }
        }
        .frame(width: 500, height: 520)
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("enableNotifications") private var enableNotifications: Bool = true
    @AppStorage("skipPermissions") private var skipPermissions: Bool = true
    @AppStorage(AppState.autoSuspendClaudeKey) private var autoSuspend: Bool = false
    @AppStorage(AppState.enableTranscriptKey) private var enableTranscript: Bool = false
    @AppStorage("enableNotificationSounds") private var enableSounds: Bool = true
    @AppStorage("notificationSoundName") private var soundName: String = "Blow"
    @AppStorage("notificationSoundCustomPath") private var customPath: String = ""
    @AppStorage("errorNotificationSoundName") private var errorSoundName: String = "Sosumi"
    @AppStorage("errorNotificationSoundCustomPath") private var errorCustomPath: String = ""

    private var systemSounds: [String] { NotificationSoundPlayer.systemSoundNames() }
    private let soundPlayer = NotificationSoundPlayer()

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Enable macOS notifications", isOn: $enableNotifications)
                    .help("Show system notifications when background tasks complete")
                Toggle("Enable notification sounds", isOn: $enableSounds)
                    .help("Play a sound when background tasks complete")

                if enableSounds {
                    HStack {
                        Picker("Sound", selection: Binding(
                            get: { customPath.isEmpty ? soundName : "__custom__" },
                            set: { newValue in
                                if newValue == "__custom__" {
                                    pickCustomSound()
                                } else {
                                    soundName = newValue
                                    customPath = ""
                                }
                            }
                        )) {
                            ForEach(systemSounds, id: \.self) { name in
                                Text(name).tag(name)
                            }
                            Divider()
                            Text("Custom…").tag("__custom__")
                            if !customPath.isEmpty {
                                Text(URL(fileURLWithPath: customPath).lastPathComponent)
                                    .tag("__custom__")
                            }
                        }
                        .frame(maxWidth: 200)

                        Button("Test") {
                            soundPlayer.playTest()
                        }
                        .controlSize(.small)
                    }

                    HStack {
                        Picker("Error sound", selection: Binding(
                            get: { errorCustomPath.isEmpty ? errorSoundName : "__custom__" },
                            set: { newValue in
                                if newValue == "__custom__" {
                                    pickErrorCustomSound()
                                } else {
                                    errorSoundName = newValue
                                    errorCustomPath = ""
                                }
                            }
                        )) {
                            ForEach(systemSounds, id: \.self) { name in
                                Text(name).tag(name)
                            }
                            Divider()
                            Text("Custom…").tag("__custom__")
                            if !errorCustomPath.isEmpty {
                                Text(URL(fileURLWithPath: errorCustomPath).lastPathComponent)
                                    .tag("__custom__")
                            }
                        }
                        .frame(maxWidth: 200)

                        Button("Test") {
                            soundPlayer.playTestError()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Agents") {
                Picker("Default primary agent", selection: primaryAgentPreferenceBinding) {
                    Text("Claude Code").tag(PrimaryAgentPreference.claude)
                    Text("Codex").tag(PrimaryAgentPreference.codex)
                }
                .pickerStyle(.segmented)
                .help("Used when TBD needs to choose the primary agent for a worktree and there is no prior agent state to restore.")
            }

            Section("Worktrees") {
                Toggle("Auto-archive worktrees when their PR merges", isOn: Binding(
                    get: { appState.autoArchiveOnMergeDefault },
                    set: { newValue in Task { await appState.setAutoArchiveOnMergeDefault(newValue) } }
                ))
                .help("Default for new worktrees. Each worktree can override this from its toolbar toggle.")
            }

            Section("Claude") {
                Toggle("Launch claude with --dangerously-skip-permissions", isOn: $skipPermissions)
                    .help("Skip the interactive permission prompt when launching claude in new worktrees")
            }

            Section {
                EnvOverridesEditor(
                    initial: appState.globalEnvOverrides,
                    caption: "Applied to every spawned Claude/Codex session. Repo and model-profile overrides take precedence."
                ) { await appState.setGlobalEnvOverrides($0) }
            }

            Section("Experimental") {
                Toggle("Auto-suspend idle Claude when switching worktrees", isOn: $autoSuspend)
                    .help("Experimental: exit idle Claude instances when you switch away and resume them when you switch back, freeing memory. Off by default — may interrupt long-running work.")
                Toggle("Live transcript pane", isOn: $enableTranscript)
                    .help("Experimental: show a chat-style live transcript pane for Claude sessions. Off by default — may freeze the app on very large transcripts.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var primaryAgentPreferenceBinding: Binding<PrimaryAgentPreference> {
        Binding(
            get: { appState.primaryAgentPreference },
            set: { newValue in
                Task { await appState.setPrimaryAgentPreference(newValue) }
            }
        )
    }

    private func pickCustomSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["aiff", "mp3", "wav", "m4a"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a notification sound"

        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
        }
    }

    private func pickErrorCustomSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["aiff", "mp3", "wav", "m4a"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an error notification sound"

        if panel.runModal() == .OK, let url = panel.url {
            errorCustomPath = url.path
        }
    }
}

// MARK: - Repositories Tab

struct RepositoriesSettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.repos.isEmpty {
                VStack {
                    Spacer()
                    Text("No repositories added yet.")
                        .foregroundStyle(.secondary)
                    Text("Use the + button in the sidebar to add a repository.")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(appState.repos) { repo in
                        RepoSettingsRow(repo: repo)
                    }
                }
            }
        }
        .padding()
    }
}

struct RepoSettingsRow: View {
    let repo: Repo
    @EnvironmentObject var appState: AppState
    @State private var editingName: String = ""
    @State private var isEditing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if isEditing {
                    TextField("Display Name", text: $editingName, onCommit: {
                        commitRename()
                    })
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                    Button("Save") {
                        commitRename()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Cancel") {
                        isEditing = false
                    }
                    .controlSize(.small)
                } else {
                    Text(repo.displayName)
                        .font(.headline)

                    Button {
                        editingName = repo.displayName
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button(role: .destructive) {
                    Task {
                        await appState.removeRepo(repoID: repo.id)
                    }
                } label: {
                    Text("Remove")
                }
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                Label(repo.defaultBranch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(repo.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Picker("Model profile override", selection: profileOverrideBinding) {
                Text("Inherit global default").tag(UUID?.none)
                ForEach(appState.modelProfiles, id: \.profile.id) { entry in
                    Text(profileLabel(entry: entry)).tag(UUID?.some(entry.profile.id))
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.caption)

            if let caption = profileOverrideCaption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var profileOverrideBinding: Binding<UUID?> {
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

    private var profileOverrideCaption: String? {
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

    private func commitRename() {
        let newName = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            isEditing = false
            return
        }
        isEditing = false
        // Update display name locally (daemon rename is for worktrees, not repos)
        // For repos we update the local model; the daemon doesn't store display name overrides
        if let idx = appState.repos.firstIndex(where: { $0.id == repo.id }) {
            appState.repos[idx].displayName = newName
        }
    }
}
