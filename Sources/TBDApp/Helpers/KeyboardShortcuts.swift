import SwiftUI

/// Menu commands providing keyboard shortcuts for the app.
struct TBDCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Install Command-Line Tool…") {
                Task { @MainActor in
                    await appState.installCLITool()
                }
            }
        }

        // Worktree commands
        CommandMenu("Worktree") {
            Button("New Worktree") {
                Task { @MainActor in
                    appState.newWorktreeInFocusedRepo()
                }
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Archive Worktree") {
                Task { @MainActor in
                    appState.archiveSelectedWorktree()
                }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(appState.selectedWorktreeIDs.isEmpty)
        }

        // Terminal commands
        CommandMenu("Terminal") {
            Button("New Tab") {
                Task { @MainActor in
                    appState.newTerminalTab()
                }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(appState.selectedWorktreeIDs.isEmpty)

            Button("Close Tab") {
                Task { @MainActor in
                    appState.closeTerminalTab()
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(appState.selectedWorktreeIDs.isEmpty)

            Divider()

            Button("Split Horizontally") {
                Task { @MainActor in
                    appState.splitTerminalHorizontally()
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(appState.selectedWorktreeIDs.isEmpty)

            Button("Split Vertically") {
                Task { @MainActor in
                    appState.splitTerminalVertically()
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(appState.selectedWorktreeIDs.isEmpty)
        }

        // Worktree selection by index (Cmd-1 through Cmd-9)
        CommandMenu("Go") {
            ForEach(1...9, id: \.self) { index in
                Button("Worktree \(index)") {
                    Task { @MainActor in
                        appState.selectWorktreeByIndex(index - 1)
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }
    }
}
