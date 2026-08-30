import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Notes")

/// Outcome of reading a note's content file. Distinguishes a file that is
/// absent (loads as empty) from one that is present but unreadable (must not
/// load at all) — `try? String(contentsOfFile:)` alone collapses the two.
private enum NoteContentRead: Sendable {
    case text(String)
    case missing
    case unreadable
}

extension AppState {
    // MARK: - Note Actions

    /// Create a note in a worktree and add a new tab for it.
    func createNote(worktreeID: UUID) async {
        do {
            let note = try await daemonClient.createNote(worktreeID: worktreeID)
            // `notes` holds metadata only — the daemon hands back a full
            // `Note` here, so summarize it rather than caching content.
            notes[worktreeID, default: []].append(NoteSummary(from: note))
            let tab = Tab(id: note.id, content: .note(noteID: note.id), label: nil)
            tabs[worktreeID, default: []].append(tab)
        } catch {
            logger.error("Failed to create note: \(error)")
            handleConnectionError(error)
        }
    }

    /// Rename a note. TITLE ONLY — note content no longer travels this path;
    /// the app writes the file itself (`saveNoteContent`).
    func updateNote(noteID: UUID, worktreeID: UUID, title: String) async {
        do {
            let updated = try await daemonClient.updateNote(noteID: noteID, title: title)
            if let idx = notes[worktreeID]?.firstIndex(where: { $0.id == noteID }) {
                // Patch the fields this call changed rather than rebuilding the
                // summary: the daemon's `Note.content` is the OVERLAID content,
                // so `NoteSummary(from:)` would over-report `hasLegacyContent`
                // for every file-backed note.
                notes[worktreeID]?[idx].title = updated.title
                notes[worktreeID]?[idx].updatedAt = updated.updatedAt
            }
        } catch {
            logger.error("Failed to update note: \(error)")
            handleConnectionError(error)
        }
    }

    /// Load a note's text for an opening pane.
    ///
    /// Read straight off disk, off the main thread — the same shape as
    /// `selectClosedTerminal`. The daemon is not in this path.
    ///
    /// Returns `nil` whenever the text could not be established — an
    /// unreadable content file, or a failed legacy fetch. The caller must
    /// treat that as "did not load" and never as "empty": an empty editor that
    /// believes it loaded will autosave its emptiness over the file. `""` is
    /// returned only for a note that genuinely has no content anywhere.
    func noteContent(noteID: UUID, worktreeID: UUID) async -> String? {
        let path = noteContentPathResolver(worktreeID, noteID)
        let outcome = await Task.detached(priority: .userInitiated) { () -> NoteContentRead in
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                return .text(text)
            }
            // A failed read is not by itself a missing file, so ask. `try?`
            // collapses "absent", "no permission", "I/O error" and "not UTF-8"
            // into one nil, and only the first of those may load as empty.
            return FileManager.default.fileExists(atPath: path) ? .unreadable : .missing
        }.value

        switch outcome {
        case .text(let text):
            return text
        case .unreadable:
            // The file is THERE and its bytes could not be had. Returning ""
            // — or falling through to the legacy check, which returns "" for
            // every ordinary file-backed note — would mark the pane loaded on
            // empty text, and the next keystroke or tab switch would autosave
            // that emptiness over content that is still on disk. `nil` is
            // "did not load", and the pane stays inert.
            logger.error(
                "Note content file exists but could not be read: \(path, privacy: .public)")
            return nil
        case .missing:
            break
        }

        // Genuinely no file. `NotesFileStore.read` would hand back "" for this
        // case AND for the one above, which is why it is deliberately not
        // used: "missing" and "unreadable" have to be told apart. A missing
        // file on a row whose LEGACY DB column still holds content means the
        // startup export never drained it, and loading "" would let the next
        // save destroy it.
        guard notes[worktreeID]?.first(where: { $0.id == noteID })?.hasLegacyContent == true else {
            return ""
        }
        do {
            return try await noteLegacyContentFetcher(noteID)
        } catch {
            logger.error("Failed to fetch legacy note content: \(error, privacy: .public)")
            handleConnectionError(error)
            return nil
        }
    }

    /// Persist a note's text.
    ///
    /// Non-empty content is written straight to the file, off the main thread.
    ///
    /// EMPTYING is the one exception and it is a data-loss trap, not a style
    /// choice: the daemon's `update` deletes the file AND clears the legacy DB
    /// column in one step. If the app deleted the file itself, a surviving
    /// column would make the next open see "file missing + hasLegacyContent"
    /// and resurrect the text the user just deleted.
    func saveNoteContent(noteID: UUID, worktreeID: UUID, content: String) async {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                _ = try await noteEmptier(noteID)
                if let idx = notes[worktreeID]?.firstIndex(where: { $0.id == noteID }) {
                    notes[worktreeID]?[idx].hasLegacyContent = false
                }
            } catch {
                // A deleted note answers "Note not found" here, which
                // handleConnectionError already absorbs silently.
                logger.error("Failed to empty note: \(error, privacy: .public)")
                handleConnectionError(error)
            }
            return
        }
        let path = noteContentPathResolver(worktreeID, noteID)
        do {
            // `writeOrThrow`, not `write`: this file is the only copy of the
            // text now that the daemon is out of the content path, and the
            // RPC that used to carry this write reported its failures. A
            // `.debug` line would make a full disk or a permission change look
            // exactly like a successful save.
            try await Task.detached(priority: .userInitiated) {
                try NotesFileStore().writeOrThrow(content, to: path)
            }.value
        } catch {
            logger.error("Failed to write note content to \(path, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Whether a note has content, from the two places that can hold it.
    ///
    /// Content lives in the file; the legacy DB column still holds it for the
    /// handful of rows the daemon's startup export never drained. Neither
    /// source alone is the answer, so the union lives here rather than at the
    /// call sites — `closeTab` hard-deletes the note row, so a wrong `false`
    /// is a silent delete.
    ///
    /// Synchronous, and one stat: it runs on a user gesture (closing a tab),
    /// never on the poll. That is the whole reason it is allowed to touch the
    /// filesystem at all.
    func noteHasContent(worktreeID: UUID, noteID: UUID) -> Bool {
        if notes[worktreeID]?.first(where: { $0.id == noteID })?.hasLegacyContent == true {
            return true
        }
        let path = noteContentPathResolver(worktreeID, noteID)
        // Existence first, size second. Asking for the size alone and folding
        // its failure into `?? 0` would make "no file" and "could not size
        // this file" the same answer — the same `try?` collapse `noteContent`
        // above is careful not to make, and here a wrong `false` skips the
        // prompt and hard-deletes the row. So only a file that is genuinely
        // there AND genuinely zero bytes may answer `false`.
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let size = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return true
        }
        return size > 0
    }

    /// Delete a note.
    func deleteNote(noteID: UUID, worktreeID: UUID) async {
        do {
            try await daemonClient.deleteNote(noteID: noteID)
            notes[worktreeID]?.removeAll { $0.id == noteID }
        } catch {
            logger.error("Failed to delete note: \(error)")
            handleConnectionError(error)
        }
    }

}
