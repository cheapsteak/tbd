import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: deterministic, in-process state only. Every daemon hop goes through
// an injected seam (`PanelTabsFixture`), so no socket opens, and no
// confirmation alert runs.

/// Closing a note's side-panel tab hard-deletes the note row, so
/// `closeSidePanel` asks for confirmation when the note has content (empty
/// notes close silently). The branch is driven by `AppState.noteHasContent`,
/// the union of the polled summary's `hasLegacyContent` and a single stat of
/// the content file — the daemon does no filesystem work for `note.list`, so
/// the close cannot inspect the text and does not need to. These cases drive
/// the legacy leg, with the file leg pointed at an empty directory; the file
/// leg is in `SidePanelNoteCloseTests`. The confirmer is injectable
/// (`AppState.noteCloseConfirmer`) so both branches run without a real modal
/// NSAlert.
///
/// A note is never a workspace tab, so the workspace tab bar's `closeTab`
/// asks nothing and deletes no note, even for a note tab held in memory from
/// an older build.
@MainActor
@Suite("Note close confirmation")
struct NoteCloseConfirmTests {
    private typealias Fixture = PanelTabsFixture

    /// A workspace tab whose side strip shows one note as a worktree panel,
    /// in front.
    private struct Seeded {
        let surface: WorkspaceTabSurface
        let panelID: PanelID
        let noteID: UUID
        var worktreeID: UUID { surface.worktreeID }
        var tabID: UUID { surface.id }
    }

    private static func seed(_ state: AppState, hasLegacyContent: Bool) -> Seeded {
        let worktreeID = UUID()
        let tabID = UUID()
        let panelID = UUID()
        let note = NoteSummary(worktreeID: worktreeID, title: "Notes", hasLegacyContent: hasLegacyContent)
        state.notes = [worktreeID: [note]]
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, primary: .terminal(terminalID: tabID),
            side: SideRegion(activePanelID: panelID),
            worktreePanels: [WorktreePanel(id: panelID, content: .note(noteID: note.id))],
            revision: 1)
        state.panelSurfaces = [worktreeID: [tabID: surface]]
        return Seeded(surface: surface, panelID: panelID, noteID: note.id)
    }

    /// The daemon's tab once the close has applied: no panel left.
    private static func closed(_ seeded: Seeded) -> WorkspaceTabSurface {
        var reply = seeded.surface
        reply.side = .empty
        reply.worktreePanels = []
        reply.revision += 1
        return reply
    }

    /// Points the file leg of `noteHasContent` at an empty temp directory,
    /// which the caller removes, so these cases exercise the legacy leg alone
    /// and never depend on the process-global TBD_HOME (see
    /// NoteContentFileAccessTests).
    private static func useEmptyNoteFiles(_ state: AppState) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-note-close-\(UUID().uuidString)")
        state.noteContentPathResolver = { worktreeID, noteID in
            root.appendingPathComponent(worktreeID.uuidString)
                .appendingPathComponent("\(noteID.uuidString).md").path
        }
        return root
    }

    /// Stubs the confirmation to answer `answer`, and the delete to succeed,
    /// recording both.
    private static func stubNoteSeams(_ state: AppState, confirming answer: Bool) -> NoteCloseRecorder {
        let recorder = NoteCloseRecorder()
        state.noteCloseConfirmer = { _, _ in recorder.confirm(answer: answer) }
        state.noteDeleter = { @MainActor noteID in recorder.delete(noteID) }
        return recorder
    }

    private static func close(_ state: AppState, _ seeded: Seeded) async {
        await state.closeSidePanel(
            worktreeID: seeded.worktreeID, tabID: seeded.tabID,
            panelID: seeded.panelID, content: .note(noteID: seeded.noteID))
    }

    // MARK: - The side-panel tab

    @Test("a note with legacy content asks, and declining keeps the panel and the note")
    func nonEmptyNoteDeclinedKeepsPanelAndNote() async {
        await Fixture.withState { state in
            let root = Self.useEmptyNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let seeded = Self.seed(state, hasLegacyContent: true)
            let envelopes = Fixture.collectEnvelopes(state, replying: Self.closed(seeded))
            let notes = Self.stubNoteSeams(state, confirming: false)

            await Self.close(state, seeded)

            #expect(notes.confirmations == 1, "a non-empty note must prompt before closing")
            #expect(envelopes.envelopes.isEmpty, "declining the prompt sends no close")
            #expect(notes.deleted.isEmpty)
            #expect(state.panelSurface(worktreeID: seeded.worktreeID, tabID: seeded.tabID) == seeded.surface)
        }
    }

    @Test("a note with legacy content, confirmed, closes its panel and deletes the note")
    func nonEmptyNoteConfirmedClosesAndDeletes() async {
        await Fixture.withState { state in
            let root = Self.useEmptyNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let seeded = Self.seed(state, hasLegacyContent: true)
            let envelopes = Fixture.collectEnvelopes(state, replying: Self.closed(seeded))
            let notes = Self.stubNoteSeams(state, confirming: true)

            await Self.close(state, seeded)

            #expect(notes.confirmations == 1)
            let applied = envelopes.envelopes.map(\.operation)
            let expectedApplied: [PanelOperation] = [.close(panelID: seeded.panelID)]
            #expect(applied == expectedApplied)
            let expectedDeleted: [UUID] = [seeded.noteID]
            #expect(notes.deleted == expectedDeleted)
        }
    }

    @Test("an empty note closes and deletes without asking")
    func emptyNoteClosesSilently() async {
        await Fixture.withState { state in
            let root = Self.useEmptyNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let seeded = Self.seed(state, hasLegacyContent: false)
            let envelopes = Fixture.collectEnvelopes(state, replying: Self.closed(seeded))
            // Declining would block the close, so a prompt cannot go unnoticed.
            let notes = Self.stubNoteSeams(state, confirming: false)

            await Self.close(state, seeded)

            #expect(notes.confirmations == 0, "a note with no content must not prompt")
            let applied = envelopes.envelopes.map(\.operation)
            let expectedApplied: [PanelOperation] = [.close(panelID: seeded.panelID)]
            #expect(applied == expectedApplied)
            let expectedDeleted: [UUID] = [seeded.noteID]
            #expect(notes.deleted == expectedDeleted)
        }
    }

    // MARK: - The workspace tab bar

    @Test("closeTab on a note tab left from an older build closes it at once, asks nothing and keeps the note")
    func leftoverNoteTabClosesAtOnceAndKeepsTheNote() async {
        await Fixture.withState { state in
            let root = Self.useEmptyNoteFiles(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let worktreeID = UUID()
            let note = NoteSummary(worktreeID: worktreeID, title: "Notes", hasLegacyContent: true)
            let agent = Fixture.terminalTab(label: "agent")
            let noteTab = TBDShared.Tab(id: note.id, content: .note(noteID: note.id), label: nil)
            state.notes = [worktreeID: [note]]
            state.tabs = [worktreeID: [agent, noteTab]]
            // An editor of the note is open: the close must not wait on it.
            let flushes = PanelEventLog()
            _ = state.registerNoteSaveFlusher(noteID: note.id) { flushes.record("flushed") }
            let notes = Self.stubNoteSeams(state, confirming: false)

            state.closeTab(worktreeID: worktreeID, index: 1)

            let remaining: [UUID] = state.tabs[worktreeID]?.map(\.id) ?? []
            let expectedRemaining: [UUID] = [agent.id]
            #expect(remaining == expectedRemaining, "the tab closed before closeTab returned")
            await Fixture.drainMainActor()
            #expect(notes.confirmations == 0)
            #expect(notes.deleted.isEmpty, "closing a workspace tab never deletes a note")
            #expect(flushes.events.isEmpty)
            #expect(state.notes[worktreeID]?.count == 1)
        }
    }
}

/// Every confirmation asked and every note deleted, in order.
@MainActor
final class NoteCloseRecorder {
    private(set) var confirmations = 0
    private(set) var deleted: [UUID] = []

    func confirm(answer: Bool) -> Bool {
        confirmations += 1
        return answer
    }

    func delete(_ noteID: UUID) {
        deleted.append(noteID)
    }
}
