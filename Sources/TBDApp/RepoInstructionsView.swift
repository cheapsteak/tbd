import SwiftUI
import TBDShared

struct RepoInstructionsView: View {
    let repoID: UUID
    @EnvironmentObject var appState: AppState

    @State private var renamePromptDraft: String = ""
    @State private var customInstructionsDraft: String = ""
    @State private var showSaved = false
    @State private var saveTask: Task<Void, Never>?
    @State private var initialized = false

    private var repo: Repo? {
        appState.repos.first { $0.id == repoID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Rename Prompt Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rename Prompt")
                        .font(.title3)
                        .fontWeight(.medium)
                    Text("Sent with the first message in worktrees that haven't been renamed yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $renamePromptDraft)
                        .font(.body.monospaced())
                        .frame(minHeight: 160)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                    HStack {
                        Spacer()
                        Button("Reset to Default") {
                            renamePromptDraft = RepoConstants.defaultRenamePrompt
                            scheduleSave()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // MARK: - General Instructions Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("General Instructions")
                        .font(.title3)
                        .fontWeight(.medium)
                    Text("Added to all new Claude sessions in this repo.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $customInstructionsDraft)
                            .font(.body.monospaced())
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                        if customInstructionsDraft.isEmpty {
                            Text("e.g. Always use pytest. Never mock the database.")
                                .font(.body.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                }

                // MARK: - Save Indicator
                HStack {
                    Spacer()
                    if showSaved {
                        Text("Saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if let repo {
                renamePromptDraft = repo.renamePrompt ?? RepoConstants.defaultRenamePrompt
                customInstructionsDraft = repo.customInstructions ?? ""
            }
        }
        .onChange(of: renamePromptDraft) { _, _ in
            guard initialized else { return }
            scheduleSave()
        }
        .onChange(of: customInstructionsDraft) { _, _ in
            guard initialized else { return }
            scheduleSave()
        }
        .onDisappear {
            saveTask?.cancel()
            // Flush any pending edits
            let renameToSave = renamePromptDraft == RepoConstants.defaultRenamePrompt ? nil : renamePromptDraft
            let instructionsToSave = customInstructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customInstructionsDraft
            Task {
                await appState.updateRepoInstructions(repoID: repoID, renamePrompt: renameToSave, customInstructions: instructionsToSave)
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            let renameToSave: String?
            if renamePromptDraft == RepoConstants.defaultRenamePrompt {
                renameToSave = nil
            } else {
                renameToSave = renamePromptDraft
            }

            let instructionsToSave: String? = customInstructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : customInstructionsDraft

            let success = await appState.updateRepoInstructions(
                repoID: repoID,
                renamePrompt: renameToSave,
                customInstructions: instructionsToSave
            )

            guard success else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showSaved = true }
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.3)) { showSaved = false }
        }
    }
}
