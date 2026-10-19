import AppKit
import SwiftUI
import TBDShared

/// Clones a repository and adds it to TBD. Opened from "Clone from URL…" in the
/// sidebar's Add Repository menu and from "Clone Repository…" on the empty
/// start screen. The rules live in `CloneRepositoryModel`; this view only lays
/// them out.
struct CloneRepositorySheet: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        CloneRepositoryForm(appState: appState)
    }
}

extension CloneRepositoryModel {
    /// The production wiring: real git without prompts, the real file system,
    /// and `repo.add` through `AppState` so the new repo lands in the sidebar.
    static func live(appState: AppState) -> CloneRepositoryModel {
        CloneRepositoryModel(
            userDefaults: appState.userDefaults,
            homeDirectory: NSHomeDirectory(),
            fileExists: { path in FileManager.default.fileExists(atPath: path) },
            makeCloner: { url, destination in
                RepoCloner(url: url, destination: destination, mode: .noPrompt)
            },
            resolveShortForm: { owner, repo in
                await RepoCloner.githubCloneURL(owner: owner, repo: repo)
            },
            addRepo: { path in
                _ = try await appState.tryAddRepo(path: path)
            })
    }
}

/// Split from `CloneRepositorySheet` so the model can be built in `init` from
/// the environment's `AppState`, and the first frame already has its fields.
private struct CloneRepositoryForm: View {
    @State private var model: CloneRepositoryModel
    @Environment(\.dismiss) private var dismiss

    init(appState: AppState) {
        _model = State(initialValue: CloneRepositoryModel.live(appState: appState))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone Repository")
                .font(.headline)

            field("Repository") {
                TextField("", text: $model.repositoryText, prompt: Text("URL or owner/repo"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isCloning)
                    .onSubmit(startClone)
                if let message = model.validationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            field("Clone into") {
                HStack {
                    Text(Self.abbreviated(model.parentDirectory))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…", action: chooseParent)
                        .disabled(model.isCloning)
                }
            }

            field("Folder name") {
                TextField("", text: $model.folderName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isCloning)
                    .onSubmit(startClone)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(Self.abbreviated(model.destinationPath), systemImage: "folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.destinationExists, !model.isCloning {
                    Text(CloneRepositoryModel.destinationExistsMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if case .cloning(let progress) = model.phase {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if let failure = model.failureMessage {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // While git runs, Cancel stops the clone and the sheet stays
                // open; otherwise it closes the sheet.
                Button("Cancel") {
                    if model.isCloning {
                        model.cancel()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button("Clone", action: startClone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canClone)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(model.isCloning)
        .onChange(of: model.phase) { _, phase in
            if phase == .done {
                dismiss()
            }
        }
        // However the sheet goes away, a clone still running stops with it.
        .onDisappear {
            model.cancel()
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func startClone() {
        guard model.canClone else { return }
        let cloneModel = self.model
        Task {
            await cloneModel.start()
        }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.parentDirectory, isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            model.parentDirectory = url.path
        }
    }

    private static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
