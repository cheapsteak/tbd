import Foundation
import SwiftUI
import TBDShared

@MainActor
final class AppState: ObservableObject {
    @Published var repos: [Repo] = []
    @Published var worktrees: [UUID: [Worktree]] = [:]
    @Published var terminals: [UUID: [Terminal]] = [:]
    @Published var notifications: [UUID: NotificationType?] = [:]
    @Published var selectedWorktreeIDs: Set<UUID> = []
    @Published var isConnected: Bool = false
    @Published var layouts: [UUID: Data] = [:]
    @Published var repoFilter: UUID? = nil

    // MARK: - Actions (delegate to DaemonClient when wired up)

    func addRepo(path: String) {
        // Will be wired to DaemonClient.addRepo(path:)
    }

    func createWorktree(repoID: UUID) {
        // Will be wired to DaemonClient.createWorktree(repoID:)
    }

    func archiveWorktree(id: UUID) {
        // Will be wired to DaemonClient.archiveWorktree(id:)
    }

    func renameWorktree(id: UUID, newName: String) {
        // Will be wired to DaemonClient.renameWorktree(id:newName:)
    }
}
