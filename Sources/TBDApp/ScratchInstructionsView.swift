import SwiftUI
import TBDShared

/// Sheet for editing the global, user-customizable system-prompt layer for
/// scratch spaces (repo-less worktrees). Mirrors `RepoInstructionsView`'s
/// "General Instructions" section but presented as a sheet (Cancel/Save)
/// rather than a persistent autosaving tab — see `EditEndpointSheet` in
/// `Settings/ModelProfilesSettingsView.swift` for the sheet convention.
struct ScratchInstructionsView: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @State private var isLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Scratch Instructions").font(.headline)
            Text("Added to all new Claude sessions in scratch spaces (repo-less worktrees).")
                .font(.callout)
                .foregroundStyle(.secondary)

            if isLoaded {
                TextEditor(text: $draft)
                    .font(.body.monospaced())
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    Spacer()
                    Button("Reset to Default") {
                        draft = RepoConstants.defaultScratchInstructions
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
                .frame(minHeight: 200)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isLoaded)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            guard !isLoaded else { return }
            let config = await appState.fetchConfig()
            let effective = config?.scratchInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
            draft = (effective?.isEmpty == false ? config?.scratchInstructions : nil)
                ?? RepoConstants.defaultScratchInstructions
            isLoaded = true
        }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultTrimmed = RepoConstants.defaultScratchInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let toSave: String? = (trimmed.isEmpty || trimmed == defaultTrimmed) ? nil : trimmed
        Task {
            await appState.setScratchInstructions(toSave)
            dismiss()
        }
    }
}
