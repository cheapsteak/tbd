import Foundation
import os
import TBDShared

private let notesLogger = Logger(subsystem: "com.tbd.app", category: "notes")

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

    /// Creates an empty file at `path` (with intermediate directories) when
    /// none exists, so external editors can open a real on-disk file. Existing
    /// files are left untouched. Failures are logged (not surfaced).
    func ensureFileExists(at path: String) {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !FileManager.default.createFile(atPath: path, contents: Data()) {
                notesLogger.debug("notepad ensure-exists failed to create file at \(path, privacy: .public)")
            }
        } catch {
            notesLogger.debug("notepad ensure-exists failed at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes `content` verbatim to `path`. Empty/whitespace-only content
    /// deletes the file. Creates intermediate directories; writes atomically.
    /// Failures are logged (not surfaced) — mirrors the hooks storage pattern.
    func write(_ content: String, to path: String) {
        do {
            try writeOrThrow(content, to: path)
        } catch {
            notesLogger.debug("notepad write failed at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `write`, surfacing the failure instead of logging it at `.debug`.
    ///
    /// The notepad can afford a swallowed write — its text is still in the
    /// editor and the next keystroke tries again. A per-note content file
    /// cannot: since the daemon left the content path, this file is the only
    /// copy of the text, so `AppState.saveNoteContent` needs to know a write
    /// failed in order to log it at `.error`.
    func writeOrThrow(_ content: String, to path: String) throws {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            return
        }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
