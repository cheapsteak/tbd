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
}
