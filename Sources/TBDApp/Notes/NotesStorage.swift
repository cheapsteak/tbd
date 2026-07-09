import Foundation
import TBDShared

/// Identifies where a worktree's notepad content is stored on disk.
/// Repo-backed worktrees share one notepad per repo; scratch worktrees
/// (no repo) get a per-worktree notepad.
enum NotesScope: Equatable {
    case repo(UUID)
    case worktree(UUID)

    /// Repo-scoped when the worktree belongs to a repo; else worktree-scoped
    /// (scratch worktrees have no `repoID`).
    static func resolve(for worktree: Worktree) -> NotesScope {
        if let repoID = worktree.repoID {
            return .repo(repoID)
        }
        return .worktree(worktree.id)
    }

    /// Absolute path to this scope's `notes.md` on disk.
    var notesPath: String {
        switch self {
        case .repo(let id): return TBDConstants.notesPath(repoID: id)
        case .worktree(let id): return TBDConstants.notesPath(worktreeID: id)
        }
    }
}

/// Reads and writes a free-text notepad file on disk. Mirrors the
/// preSession/setup hook storage pattern (`RepoHooksSettingsView`): direct
/// `FileManager` access; empty/whitespace-only content deletes the file.
struct NotesFileStore {
    /// Returns the file's contents, or "" when the file does not exist.
    func read(at path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Writes `content` verbatim to `path`. Empty/whitespace-only content
    /// deletes the file. Creates intermediate directories; writes atomically.
    func write(_ content: String, to path: String) {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
