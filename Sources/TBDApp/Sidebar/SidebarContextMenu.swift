import AppKit
import SwiftUI
import TBDShared

struct SidebarContextMenu: View {
    let worktree: Worktree
    var onRename: () -> Void
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if worktree.isScratch {
                Button("New Claude Terminal") {
                    let wtID = worktree.id
                    Task {
                        await appState.createClaudeTerminal(worktreeID: wtID)
                    }
                }
                Button("New Codex Terminal") {
                    let wtID = worktree.id
                    Task {
                        await appState.createCodexTerminal(worktreeID: wtID)
                    }
                }
                Button("New Shell Terminal") {
                    let wtID = worktree.id
                    Task {
                        await appState.createTerminal(worktreeID: wtID)
                    }
                }
                Divider()
                Button("Rename...") {
                    onRename()
                }
                if worktree.promotedToRepoID == nil {
                    Text("To promote: run `tbd scratch promote <dest>` from a session here")
                        .font(.caption)
                }
                Divider()
                Button("Open in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(worktree.path, forType: .string)
                }
                Divider()
                // `.destructive` role for consistency with the non-scratch
                // "Archive" button below, even though scratch archive is
                // recoverable (revive exists) and leaves the folder untouched
                // on disk — the repo-worktree Archive button is styled the
                // same way despite being recoverable too.
                Button("Archive", role: .destructive) {
                    Task { await appState.archiveScratch(id: worktree.id) }
                }
                Button("Delete Scratch Space", role: .destructive) {
                    appState.deleteScratch(id: worktree.id)
                }
            } else if worktree.status == .main || worktree.status == .creating {
                // Main / creating worktree: only Finder and Copy Path (no rename/archive)
                if !worktree.path.isEmpty {
                    Button("Open in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
                    }

                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(worktree.path, forType: .string)
                    }
                }
            } else {
                Button("Rename...") {
                    onRename()
                }

                let terminals = appState.terminals[worktree.id] ?? []
                let hasUnsuspendedClaude = terminals.contains {
                    $0.isClaudeResumable && $0.suspendedAt == nil
                }
                let hasSuspendedClaude = terminals.contains {
                    $0.isClaudeResumable && $0.suspendedAt != nil
                }
                let hasActiveChildren = !appState.children(of: worktree.id).isEmpty

                if hasUnsuspendedClaude {
                    Button("Suspend Claude") {
                        let wtID = worktree.id
                        let claudeTerminalIDs = terminals
                            .filter { $0.isClaudeResumable && $0.suspendedAt == nil }
                            .map { $0.id }
                        // Capture screenshot synchronously before any state change
                        for id in claudeTerminalIDs {
                            if let screenshot = appState.snapshotProviders[id]?() {
                                appState.setSuspendingSnapshot(screenshot, for: id)
                            }
                        }
                        // Now set suspending state (removes TerminalPanelView, shows screenshot)
                        claudeTerminalIDs.forEach { appState.suspendingTerminalIDs.insert($0) }
                        Task {
                            try? await appState.daemonClient.worktreeSuspend(worktreeID: wtID)
                            // Poll until all Claude terminals are suspended (daemon now async)
                            // 200ms intervals for first 2s, 500ms after — up to 15s total
                            for i in 0..<30 {
                                await appState.refreshTerminals(worktreeID: wtID)
                                let updated = appState.terminals[wtID] ?? []
                                if claudeTerminalIDs.allSatisfy({ id in
                                    updated.first(where: { $0.id == id })?.suspendedAt != nil
                                }) {
                                    break
                                }
                                try? await Task.sleep(for: .milliseconds(i < 10 ? 200 : 500))
                            }
                            claudeTerminalIDs.forEach {
                                appState.suspendingTerminalIDs.remove($0)
                                appState.removeSuspendingSnapshot(for: $0)
                            }
                        }
                    }
                }

                if hasSuspendedClaude {
                    Button("Resume Claude") {
                        let wtID = worktree.id
                        Task {
                            try? await appState.daemonClient.worktreeResume(worktreeID: wtID)
                            await appState.refreshTerminals(worktreeID: wtID)
                        }
                    }
                }

                // Scratch spaces have no repo, so nesting isn't offered for them.
                if let repoID = worktree.repoID {
                    Button("Create Nested Worktree") {
                        appState.createWorktree(repoID: repoID, parentWorktreeID: worktree.id)
                    }
                }

                Button("Archive", role: .destructive) {
                    let wtID = worktree.id
                    Task {
                        await appState.archiveWorktree(id: wtID)
                    }
                }
                .disabled(hasActiveChildren)
                .help(hasActiveChildren ? "Archive nested worktrees first" : "")

                Divider()

                Button("Open in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
                }

                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(worktree.path, forType: .string)
                }
            }
        }
    }
}
