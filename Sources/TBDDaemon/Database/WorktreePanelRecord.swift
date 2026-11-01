import Foundation
import GRDB
import os
import TBDShared

private let decodeLogger = Logger(subsystem: "com.tbd.daemon", category: "database.decode")

/// GRDB Record type for the `worktree_panel` table: one row per worktree
/// panel, the side-panel tab a worktree's every workspace tab shows (side
/// panel notes spec, "Daemon"). `position` orders a worktree's panels, left
/// to right; `content` is the JSON of the panel's `WorktreePanelContent`.
/// Deleting the worktree row deletes its panels.
struct WorktreePanelRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "worktree_panel"
    var id: String
    var worktreeID: String
    var position: Int
    var content: String

    init(from panel: WorktreePanel, worktreeID: UUID, position: Int) throws {
        self.id = panel.id.uuidString
        self.worktreeID = worktreeID.uuidString
        self.position = position
        self.content = try encodeJSONString(panel.content)
    }

    /// Failable decode: returns nil after a logged warning, never traps, when
    /// the id or the content fails to parse.
    func toModel() -> WorktreePanel? {
        guard let uuid = UUID(uuidString: id) else {
            decodeLogger.warning("Skipping worktree_panel row \(id, privacy: .public): malformed id")
            return nil
        }
        guard let decoded = decodeJSON(WorktreePanelContent.self, from: content) else {
            decodeLogger.warning("Skipping worktree_panel row \(id, privacy: .public): malformed content")
            return nil
        }
        return WorktreePanel(id: uuid, content: decoded)
    }
}
