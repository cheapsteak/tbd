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
