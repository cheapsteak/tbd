import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Notes")

/// One note's latest rename still persisting (`AppState.noteRenameTails`):
/// its task, which the next rename of that note awaits first, a token that
/// tells a rename whether it is still the latest, and the title the daemon
/// last confirmed for the note, which a failed rename puts back.
struct NoteRenameTail {
    let token: UUID
    let task: Task<Void, Never>
    /// The note's title as the daemon last confirmed it: its summary's title
    /// when this chain of renames began, then the title of each rename that
    /// persisted. Nil when `notes` held no summary for the note then and no
    /// rename has persisted since.
    var confirmedTitle: String?
}

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
    /// the app writes the file itself (`saveNoteContent`). Every control that
    /// edits a note's title comes here: its tab, in the workspace tab bar or
    /// the side region's strip, and the legacy pane header's title.
    ///
    /// Synchronous, like `renameTab`: the new title lands in `notes` at once,
    /// in the same frame as the rename field closing, so the tab never flashes
    /// the old title. The title then persists through `noteTitleUpdater` on a
    /// task. A failure is handed to `handleConnectionError` and puts back the
    /// title the daemon last confirmed (`NoteRenameTail.confirmedTitle`) —
    /// unless a later rename of the note is still to persist, which sets its
    /// own title or puts the confirmed one back itself. So two failed renames
    /// leave the title the daemon holds, not the first one's.
    ///
    /// One note's renames persist one at a time, in the order they were
    /// made: each waits for the one before it (`noteRenameTails`). Sent side
    /// by side they could commit out of order, leaving the daemon on an older
    /// title than the app shows until the next notes refresh brought it back.
    func renameNote(noteID: UUID, worktreeID: UUID, title: String) {
        let pending = noteRenameTails[noteID]
        // A chain beginning now takes the summary's title as the daemon's;
        // one under way keeps what its renames confirmed.
        let confirmedTitle = pending == nil
            ? notes[worktreeID]?.first(where: { $0.id == noteID })?.title
            : pending?.confirmedTitle
        patchNoteSummary(noteID: noteID, worktreeID: worktreeID) { $0.title = title }
        let before = pending?.task
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await before?.value
            await self?.persistNoteRename(noteID: noteID, worktreeID: worktreeID, title: title, token: token)
            // The chain has drained unless a later rename queued behind this one.
            if self?.noteRenameTails[noteID]?.token == token {
                self?.noteRenameTails.removeValue(forKey: noteID)
            }
        }
        noteRenameTails[noteID] = NoteRenameTail(token: token, task: task, confirmedTitle: confirmedTitle)
    }

    /// One rename's persist, the rename `token` names. The title goes to the
    /// daemon. On success it becomes the chain's confirmed title, and the
    /// summary takes the daemon's answer. On a failure, while this is still
    /// the note's latest rename, the summary takes the confirmed title back.
    /// Either write lands only while the note still shows this rename's title.
    /// Each patches just the fields it changed rather than rebuilding the
    /// summary: the daemon's `Note.content` is the OVERLAID content, so
    /// `NoteSummary(from:)` would over-report `hasLegacyContent` for every
    /// file-backed note.
    private func persistNoteRename(noteID: UUID, worktreeID: UUID, title: String, token: UUID) async {
        do {
            let updated = try await noteTitleUpdater(noteID, title)
            noteRenameTails[noteID]?.confirmedTitle = updated.title
            patchNoteSummary(noteID: noteID, worktreeID: worktreeID, whileTitled: title) {
                $0.title = updated.title
                $0.updatedAt = updated.updatedAt
            }
        } catch {
            logger.error("Failed to rename note: \(error, privacy: .public)")
            if let tail = noteRenameTails[noteID], tail.token == token, let confirmed = tail.confirmedTitle {
                patchNoteSummary(noteID: noteID, worktreeID: worktreeID, whileTitled: title) {
                    $0.title = confirmed
                }
            }
            handleConnectionError(error)
        }
    }

    /// Applies `patch` to a note's summary in `notes`, when the worktree holds
    /// one — and, given `whileTitled`, only while its title is still that one.
    private func patchNoteSummary(
        noteID: UUID, worktreeID: UUID, whileTitled title: String? = nil,
        _ patch: (inout NoteSummary) -> Void
    ) {
        guard var summaries = notes[worktreeID],
              let index = summaries.firstIndex(where: { $0.id == noteID }) else { return }
        if let title, summaries[index].title != title { return }
        patch(&summaries[index])
        notes[worktreeID] = summaries
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

    /// Delete a note, through `noteDeleter`.
    func deleteNote(noteID: UUID, worktreeID: UUID) async {
        do {
            try await noteDeleter(noteID)
            notes[worktreeID]?.removeAll { $0.id == noteID }
        } catch {
            logger.error("Failed to delete note: \(error)")
            handleConnectionError(error)
        }
    }

}
