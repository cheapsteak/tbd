import AppKit
import SwiftUI
import TBDShared

struct SidebarContextMenu: View {
    let worktree: Worktree
    var onRename: () -> Void
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if worktree.status == .main || worktree.status == .creating {
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
                    $0.claudeSessionID != nil && $0.suspendedAt == nil
                }
                let hasSuspendedClaude = terminals.contains {
                    $0.claudeSessionID != nil && $0.suspendedAt != nil
                }

                if hasUnsuspendedClaude {
                    Button("Suspend Claude") {
                        let wtID = worktree.id
                        let claudeTerminalIDs = terminals
                            .filter { $0.claudeSessionID != nil && $0.suspendedAt == nil }
                            .map { $0.id }
                        // Set synchronously before any async work — pill appears immediately
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
                            claudeTerminalIDs.forEach { appState.suspendingTerminalIDs.remove($0) }
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

                Button("Archive", role: .destructive) {
                    let wtID = worktree.id
                    Task {
                        await appState.archiveWorktree(id: wtID)
                    }
                }

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
