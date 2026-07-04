import SwiftUI
import TBDShared

/// Instructions tab for `ScratchDetailView`: two debounced-autosave sections
/// for the global scratch-space config fields — mirrors `RepoInstructionsView`'s
/// two-section, 1s-debounce, "Saved" indicator pattern, but for
/// `Config.scratchRenamePrompt` / `Config.scratchInstructions` instead of a
/// per-repo `Repo` row.
///
/// Deliberately NOT built by refactoring `ScratchInstructionsView` (the
/// existing sheet, still used from `ScratchSectionView`'s context menu) into a
/// shared widget: that view's explicit Cancel/Save-then-dismiss flow and this
/// tab's debounced-autosave-on-change flow have different save triggers and
/// lifecycles, so extracting a shared "editing widget" would mostly just move
/// the `TextEditor` + "Reset to Default" markup into a wrapper while leaving
/// the two views' surrounding save logic duplicated anyway. Writing fresh,
/// consistent-looking markup here keeps both views simple and leaves the
/// sheet's existing behavior/tests untouched.
struct ScratchInstructionsTabView: View {
    @EnvironmentObject var appState: AppState

    @State private var renamePromptDraft: String = ""
    @State private var instructionsDraft: String = ""
    @State private var showSaved = false
    @State private var saveTask: Task<Void, Never>?
    @State private var initialized = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Rename Nudge Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rename Nudge")
                        .font(.title3)
                        .fontWeight(.medium)
                    Text("Sent once, nudging the agent to rename the scratch space once its topic is clear (only while it still has its auto-generated name).")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if initialized {
                        TextEditor(text: $renamePromptDraft)
                            .font(.body.monospaced())
                            .frame(minHeight: 160)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                        HStack {
                            Spacer()
                            Button("Reset to Default") {
                                renamePromptDraft = RepoConstants.defaultScratchRenamePrompt
                                scheduleSave()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .frame(minHeight: 160)
                    }
                }

                Divider()

                // MARK: - Scratch Instructions Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scratch Instructions")
                        .font(.title3)
                        .fontWeight(.medium)
                    Text("Added to all new Claude sessions in scratch spaces (repo-less worktrees).")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if initialized {
                        TextEditor(text: $instructionsDraft)
                            .font(.body.monospaced())
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                        HStack {
                            Spacer()
                            Button("Reset to Default") {
                                instructionsDraft = RepoConstants.defaultScratchInstructions
                                scheduleSave()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .frame(minHeight: 120)
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
        .task {
            guard !initialized else { return }
            let config = await appState.fetchConfig()
            renamePromptDraft = config?.scratchRenamePrompt ?? RepoConstants.defaultScratchRenamePrompt
            instructionsDraft = config?.scratchInstructions ?? RepoConstants.defaultScratchInstructions
            initialized = true
        }
        .onChange(of: renamePromptDraft) { _, _ in
            guard initialized else { return }
            scheduleSave()
        }
        .onChange(of: instructionsDraft) { _, _ in
            guard initialized else { return }
            scheduleSave()
        }
        .onDisappear {
            saveTask?.cancel()
            guard initialized else { return }
            let renameToSave = normalizedRenamePrompt
            let instructionsToSave = normalizedInstructions
            Task {
                await appState.setScratchRenamePrompt(renameToSave)
                await appState.setScratchInstructions(instructionsToSave)
            }
        }
    }

    private var normalizedRenamePrompt: String? {
        let trimmed = renamePromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultTrimmed = RepoConstants.defaultScratchRenamePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || trimmed == defaultTrimmed) ? nil : renamePromptDraft
    }

    private var normalizedInstructions: String? {
        let trimmed = instructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultTrimmed = RepoConstants.defaultScratchInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || trimmed == defaultTrimmed) ? nil : instructionsDraft
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            let renameToSave = normalizedRenamePrompt
            let instructionsToSave = normalizedInstructions

            await appState.setScratchRenamePrompt(renameToSave)
            await appState.setScratchInstructions(instructionsToSave)

            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showSaved = true }
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.3)) { showSaved = false }
        }
    }
}
