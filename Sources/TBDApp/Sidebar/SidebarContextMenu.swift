import AppKit
import SwiftUI
import TBDShared

struct SidebarContextMenu: View {
    let worktree: Worktree
    var onRename: () -> Void
    @EnvironmentObject var appState: AppState

    private var status: WorktreeMergeStatusResult? {
        appState.mergeStatus[worktree.id]
    }

    private var canMerge: Bool {
        status?.canMerge ?? true
    }

    private var mergeTooltip: String? {
        status?.reason
    }

    var body: some View {
        Group {
            if worktree.status == .main {
                // Main worktree: only Finder and Copy Path
                Button("Open in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
                }

                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(worktree.path, forType: .string)
                }
            } else {
                Button("Rename...") {
                    onRename()
                }

                if let reason = mergeTooltip, !canMerge {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Merge to Main") {
                    Task {
                        await appState.mergeWorktree(id: worktree.id)
                    }
                }
                .disabled(!canMerge)

                Button("Merge to Main & Archive") {
                    Task {
                        await appState.mergeWorktree(id: worktree.id, archiveAfter: true)
                    }
                }
                .disabled(!canMerge)

                Button("Archive") {
                    Task {
                        await appState.archiveWorktree(id: worktree.id)
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
        .onAppear {
            if worktree.status != .main {
                Task {
                    await appState.refreshMergeStatus(worktreeID: worktree.id)
                }
            }
        }
    }
}
