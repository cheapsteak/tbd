import AppKit
import SwiftUI
import TBDShared

struct SidebarContextMenu: View {
    let worktree: Worktree
    @EnvironmentObject var appState: AppState
    @Binding var showRenameAlert: Bool
    @Binding var renameText: String

    var body: some View {
        Button("Rename...") {
            renameText = worktree.displayName
            showRenameAlert = true
        }

        Button("Archive") {
            appState.archiveWorktree(id: worktree.id)
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
