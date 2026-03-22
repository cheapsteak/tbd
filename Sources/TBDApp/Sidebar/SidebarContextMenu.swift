import AppKit
import SwiftUI
import TBDShared

struct SidebarContextMenu: View {
    let worktree: Worktree
    @EnvironmentObject var appState: AppState
    @Binding var showRenameAlert: Bool
    @Binding var renameText: String

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
            Button("Rename...") {
                renameText = worktree.displayName
                showRenameAlert = true
            }

            Button("Merge to Main") {
                Task {
                    await appState.mergeWorktree(id: worktree.id)
                }
            }
            .disabled(!canMerge)
            .help(mergeTooltip ?? "")

            Button("Merge to Main & Archive") {
                Task {
                    await appState.mergeWorktree(id: worktree.id, archiveAfter: true)
                }
            }
            .disabled(!canMerge)
            .help(mergeTooltip ?? "")

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
        .onAppear {
            Task {
                await appState.refreshMergeStatus(worktreeID: worktree.id)
            }
        }
    }
}
