import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The app owns note content: `note.list` carries none, so `NotePaneView`
/// reads and writes `TBDConstants.noteContentPath` itself. Two rules in that
/// path are data-loss-shaped and are what these cases pin.
///
/// - A missing file is not an empty note. When the legacy DB column still
///   holds the text, `noteContent` must fall back to the daemon rather than
///   loading `""` for the autosave to write back.
/// - An emptying save must go through the daemon, which deletes the file and
///   clears that column together. If the app deleted the file itself, the
///   surviving column would resurrect the text on the next open.
///
/// Constructs `AppState(userDefaults:)` against a throwaway suite —
/// `UserDefaults.standard` on this unbundled executable is the developer's
/// real TBDApp.plist (see TabUnreadCompletionTests). Content files go to a
/// per-test temp directory through `noteContentPathResolver` rather than to a
/// `TBD_HOME`-derived path: `TBD_HOME` is process-global and concurrently
/// running daemon suites `setenv` it, so a test that resolved the path twice
/// could get two different answers (`Tests/CLAUDE.md`, and the same reason
/// `NotesFileStoreTests` uses `temporaryDirectory`).
@MainActor
@Suite("Note content file access")
struct NoteContentFileAccessTests {

    /// Runs `body` against a fresh `AppState` whose note content files live in
    /// a per-test temp directory, removed afterwards.
    private func withState(_ body: (AppState) async -> Void) async {
        let suiteName = "TBDAppTests.NoteContentFileAccess.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-note-content-\(UUID().uuidString)")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: dir)
        }
        let state = AppState(userDefaults: defaults)
        state.noteContentPathResolver = { worktreeID, noteID in
            dir.appendingPathComponent(worktreeID.uuidString)
                .appendingPathComponent("\(noteID.uuidString).md").path
        }
        await body(state)
    }

    /// Registers one note summary and returns its identity plus its content
    /// path, resolved the way the code under test resolves it.
    private func seedNote(
        state: AppState, hasLegacyContent: Bool
    ) -> (worktreeID: UUID, noteID: UUID, path: String) {
        let worktreeID = UUID()
        let note = NoteSummary(worktreeID: worktreeID, title: "Notes",
                               hasLegacyContent: hasLegacyContent)
        state.notes[worktreeID] = [note]
        return (worktreeID, note.id, state.noteContentPathResolver(worktreeID, note.id))
    }

    private func makeParentDir(of path: String) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
    }

    @Test("an existing content file is read off disk, never from the daemon")
    func readsTheFileDirectly() async {
        await withState { state in
            let seed = seedNote(state: state, hasLegacyContent: false)
            makeParentDir(of: seed.path)
            try? "from the file".write(toFile: seed.path, atomically: true, encoding: .utf8)

            var fetched = false
            state.noteLegacyContentFetcher = { _ in
                fetched = true
                return "from the daemon"
            }

            let text = await state.noteContent(noteID: seed.noteID, worktreeID: seed.worktreeID)

            #expect(text == "from the file")
            #expect(!fetched, "a present content file must not provoke an RPC")
        }
    }

    @Test("a missing file with legacy column content falls back to the daemon")
    func missingFileWithLegacyContentFallsBack() async {
        await withState { state in
            let seed = seedNote(state: state, hasLegacyContent: true)
            #expect(!FileManager.default.fileExists(atPath: seed.path))

            var askedFor: UUID?
            state.noteLegacyContentFetcher = { noteID in
                askedFor = noteID
                return "never exported"
            }

            let text = await state.noteContent(noteID: seed.noteID, worktreeID: seed.worktreeID)

            #expect(text == "never exported",
                    "loading \"\" here would let the autosave destroy the note")
            #expect(askedFor == seed.noteID)
        }
    }

    @Test("a content file that exists but cannot be read returns nil, not empty")
    func unreadableFileReturnsNil() async {
        await withState { state in
            // The ordinary modern note: file-backed, empty legacy column.
            // Without the exists-check this returns "" — the failed read is
            // indistinguishable from a missing file, and the guard below hands
            // back "" for a note with no legacy content.
            let seed = seedNote(state: state, hasLegacyContent: false)
            makeParentDir(of: seed.path)
            try? "real content nobody may overwrite"
                .write(toFile: seed.path, atomically: true, encoding: .utf8)
            // Restore the mode in `defer` regardless of the outcome, or
            // `withState`'s directory removal cannot delete the file.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: seed.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: seed.path)
            }

            var fetched = false
            state.noteLegacyContentFetcher = { _ in
                fetched = true
                return "unexpected"
            }

            let text = await state.noteContent(noteID: seed.noteID, worktreeID: seed.worktreeID)

            // Without this, the pane marks itself loaded on "" and the next
            // keystroke autosaves that over content still on disk.
            #expect(text == nil, "an unreadable file must not load as empty")
            #expect(!fetched, "an existing file must not fall through to the legacy fallback")
            #expect(FileManager.default.fileExists(atPath: seed.path),
                    "and the file is of course still there")
        }
    }

    @Test("a missing file with no legacy content loads as empty, with no RPC")
    func missingFileWithoutLegacyContentLoadsEmpty() async {
        await withState { state in
            let seed = seedNote(state: state, hasLegacyContent: false)
            var fetched = false
            state.noteLegacyContentFetcher = { _ in
                fetched = true
                return "unexpected"
            }

            let text = await state.noteContent(noteID: seed.noteID, worktreeID: seed.worktreeID)

            #expect(text == "", "a fresh note is genuinely empty, and must still load")
            #expect(!fetched)
        }
    }

    @Test("a failed legacy fetch returns nil so the pane never marks itself loaded")
    func failedLegacyFetchReturnsNil() async {
        await withState { state in
            let seed = seedNote(state: state, hasLegacyContent: true)
            struct Boom: Error {}
            state.noteLegacyContentFetcher = { _ in throw Boom() }

            let text = await state.noteContent(noteID: seed.noteID, worktreeID: seed.worktreeID)

            #expect(text == nil, "nil is 'did not load'; \"\" would be 'loaded, and empty'")
        }
    }

    @Test("a non-empty save writes the file and never reaches the daemon")
    func nonEmptySaveWritesTheFileDirectly() async {
        await withState { state in
            let seed = seedNote(state: state, hasLegacyContent: false)
            var emptied = false
            state.noteEmptier = { _ in
                emptied = true
                return Note(worktreeID: seed.worktreeID, title: "Notes")
            }

            await state.saveNoteContent(
                noteID: seed.noteID, worktreeID: seed.worktreeID, content: "written by the app")

            let onDisk = try? String(contentsOfFile: seed.path, encoding: .utf8)
            #expect(onDisk == "written by the app")
            #expect(!emptied, "ordinary saves must not go through the daemon")
        }
    }

    /// A write that cannot land must fail quietly and locally: no file, no
    /// trap, and above all not mistaken for an emptying — which would delete
    /// the note's legacy column too. Driven by making the note's parent a
    /// regular FILE, so `createDirectory` throws.
    ///
    /// This does NOT pin that the failure is surfaced. `saveNoteContent` logs
    /// it at `.error` via `writeOrThrow` rather than swallowing it at `.debug`
    /// the way `NotesFileStore.write` does, but both leave the same observable
    /// state, so only a logging seam that does not exist here could tell them
    /// apart.
    @Test("a save that cannot reach disk fails without creating or emptying anything")
    func failedWriteLeavesNoFileAndNoEmptying() async {
        await withState { state in
            let seed = seedNote(state: state, hasLegacyContent: false)
            let parent = (seed.path as NSString).deletingLastPathComponent
            makeParentDir(of: parent)
            #expect(FileManager.default.createFile(atPath: parent, contents: Data()),
                    "a regular file where the note's directory should be")

            var emptied = false
            state.noteEmptier = { _ in
                emptied = true
                return Note(worktreeID: seed.worktreeID, title: "Notes")
            }

            await state.saveNoteContent(
                noteID: seed.noteID, worktreeID: seed.worktreeID, content: "cannot land")

            #expect(!FileManager.default.fileExists(atPath: seed.path))
            #expect(!emptied, "a failed write is not an emptying")
        }
    }

    @Test("an emptying save routes through the daemon and clears the legacy flag")
    func emptyingSaveRoutesThroughTheDaemon() async {
        await withState { state in
            let seed = seedNote(state: state, hasLegacyContent: true)
            makeParentDir(of: seed.path)
            try? "about to be cleared".write(toFile: seed.path, atomically: true, encoding: .utf8)

            var emptiedID: UUID?
            state.noteEmptier = { noteID in
                emptiedID = noteID
                return Note(id: noteID, worktreeID: seed.worktreeID, title: "Notes")
            }

            await state.saveNoteContent(
                noteID: seed.noteID, worktreeID: seed.worktreeID, content: "   \n")

            #expect(emptiedID == seed.noteID,
                    "only the daemon can delete the file and clear the legacy column together")
            #expect(state.notes[seed.worktreeID]?.first?.hasLegacyContent == false,
                    "and the cached summary must follow, so no stale fallback fires")
        }
    }

    @Test("noteHasContent is the union of the legacy column and the file")
    func noteHasContentTakesTheUnion() async {
        await withState { state in
            // Legacy column only.
            let legacy = seedNote(state: state, hasLegacyContent: true)
            #expect(state.noteHasContent(worktreeID: legacy.worktreeID, noteID: legacy.noteID))

            // File only.
            let fileOnly = seedNote(state: state, hasLegacyContent: false)
            #expect(!state.noteHasContent(
                worktreeID: fileOnly.worktreeID, noteID: fileOnly.noteID),
                    "neither source yet")
            makeParentDir(of: fileOnly.path)
            try? "on disk".write(toFile: fileOnly.path, atomically: true, encoding: .utf8)
            #expect(state.noteHasContent(
                worktreeID: fileOnly.worktreeID, noteID: fileOnly.noteID),
                    "the file alone must be enough — closing the tab deletes the row")
        }
    }

    /// `noteHasContent`'s `false` skips the confirmation and hard-deletes the
    /// note row, so it may only be reached by a file that is genuinely there
    /// and genuinely empty. A path whose size cannot be established must
    /// answer `true`.
    ///
    /// A directory standing in for the file is the one such state a test can
    /// actually construct in-process: `fileSizeKey` is nil for it, while a
    /// `chmod 000` file still stats fine and so would not discriminate.
    @Test("a content path whose size cannot be read counts as content")
    func noteHasContentAssumesContentWhenSizeIsUnavailable() async {
        await withState { state in
            let seed = seedNote(state: state, hasLegacyContent: false)
            makeParentDir(of: seed.path)
            try? FileManager.default.createDirectory(
                atPath: seed.path, withIntermediateDirectories: false)

            #expect(state.noteHasContent(worktreeID: seed.worktreeID, noteID: seed.noteID),
                    "an unsizeable path must not read as 'no content'")
        }
    }

    @Test("a zero-byte content file counts as no content")
    func noteHasContentIsFalseForAnEmptyFile() async {
        await withState { state in
            let seed = seedNote(state: state, hasLegacyContent: false)
            makeParentDir(of: seed.path)
            #expect(FileManager.default.createFile(atPath: seed.path, contents: Data()))

            #expect(!state.noteHasContent(worktreeID: seed.worktreeID, noteID: seed.noteID),
                    "a file that is there and empty is the one case that may answer false")
        }
    }

    /// The close alert advertises where the note's text is kept. It must name
    /// the path the app actually writes to — one resolver, one answer — or the
    /// user is told their content survives somewhere it does not.
    @Test("the close confirmer is told the resolver's path, not a derived one")
    func closeConfirmerReceivesTheResolvedPath() async {
        await withState { state in
            let seed = seedNote(state: state, hasLegacyContent: true)
            state.tabs[seed.worktreeID] = [
                Tab(id: seed.noteID, content: .note(noteID: seed.noteID), label: nil)
            ]

            var advertised: String?
            state.noteCloseConfirmer = { _, path in
                advertised = path
                return false
            }

            state.closeTab(worktreeID: seed.worktreeID, index: 0)

            #expect(advertised == seed.path,
                    "the advertised path must be the one the app writes to")
            #expect(advertised != TBDConstants.noteContentPath(
                worktreeID: seed.worktreeID, noteID: seed.noteID),
                    "and this test is vacuous unless the resolver was overridden")
        }
    }
}
