import SwiftUI
import TBDShared

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
        }
        .frame(width: 500, height: 360)
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @AppStorage("enableNotifications") private var enableNotifications: Bool = true
    @AppStorage("skipPermissions") private var skipPermissions: Bool = true

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Enable macOS notifications", isOn: $enableNotifications)
                    .help("Show system notifications when tasks complete or need attention")
            }

            Section("Claude") {
                Toggle("Launch claude with --dangerously-skip-permissions", isOn: $skipPermissions)
                    .help("Skip the interactive permission prompt when launching claude in new worktrees")
            }
        }
        .formStyle(.grouped)
        .padding()
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
                    Text("Use the Add Repository button in the main window toolbar.")
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
        }
        .padding(.vertical, 4)
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
