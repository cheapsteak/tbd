import Foundation
import Testing
@testable import TBDApp
import TBDShared

private func makeWorktree(repoID: UUID?) -> Worktree {
    Worktree(repoID: repoID, name: "wt", displayName: "wt",
             branch: "b", path: "/tmp/wt", tmuxServer: "srv")
}

@Suite struct NotesScopeTests {
    @Test func resolvesRepoScopeWhenRepoIDPresent() {
        let repoID = UUID()
        #expect(NotesScope.resolve(for: makeWorktree(repoID: repoID)) == .repo(repoID))
    }

    @Test func resolvesWorktreeScopeForScratch() {
        let wt = makeWorktree(repoID: nil)
        #expect(NotesScope.resolve(for: wt) == .worktree(wt.id))
    }

    @Test func notesPathMatchesConstantsForRepoScope() {
        let repoID = UUID()
        #expect(NotesScope.repo(repoID).notesPath == TBDConstants.notesPath(repoID: repoID))
    }

    @Test func notesPathMatchesConstantsForWorktreeScope() {
        let wtID = UUID()
        #expect(NotesScope.worktree(wtID).notesPath == TBDConstants.notesPath(worktreeID: wtID))
    }
}

@Suite struct NotesFileStoreTests {
    let store = NotesFileStore()

    private func tempNotesPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-notes-test-\(UUID().uuidString)")
            .appendingPathComponent("notes.md")
            .path
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    @Test func writeThenReadRoundtrips() {
        let path = tempNotesPath()
        store.write("hello\nworld\n", to: path)
        #expect(store.read(at: path) == "hello\nworld\n")
        cleanup(path)
    }

    @Test func readMissingFileReturnsEmpty() {
        #expect(store.read(at: tempNotesPath()) == "")
    }

    @Test func writeEmptyOrWhitespaceDeletesFile() {
        let path = tempNotesPath()
        store.write("something", to: path)
        #expect(FileManager.default.fileExists(atPath: path))
        store.write("   \n  ", to: path)
        #expect(!FileManager.default.fileExists(atPath: path))
        cleanup(path)
    }

    @Test func writeCreatesIntermediateDirectories() {
        let path = tempNotesPath() // parent dir does not exist yet
        store.write("content", to: path)
        #expect(store.read(at: path) == "content")
        cleanup(path)
    }
}
