import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: deterministic, in-process state only. `note.create` and
// `panel.apply` go through injected seams (`AppState.noteCreator`,
// `PanelTabsFixture`), so no socket opens.

/// The side strip's New Note (side panel notes spec, "App"): a note is made
/// only there, so it is born where it lives. `AppState.createNote` creates the
/// note, lists its summary in `notes`, and opens it as a worktree panel in the
/// workspace tab whose strip it came from. It never makes a workspace tab.
@Suite("Side strip New Note")
@MainActor
struct SideStripNewNoteTests {
    private typealias Fixture = PanelTabsFixture

    @Test("New Note creates the note, then opens it as a worktree panel in the tab it came from")
    func newNoteCreatesThenOpensInItsTab() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let surface = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 1)
            state.panelSurfaces = [worktreeID: [tabID: surface]]
            let created = Note(worktreeID: worktreeID, title: "Note")
            let creates = PanelEventLog()
            state.noteCreator = { @MainActor worktreeID in
                creates.record("create \(worktreeID)")
                return created
            }
            let panelID = UUID()
            var reply = surface
            reply.worktreePanels = [WorktreePanel(id: panelID, content: .note(noteID: created.id))]
            reply.side.activePanelID = panelID
            reply.revision = 2
            let envelopes = Fixture.collectEnvelopes(state, replying: reply)

            await state.createNote(worktreeID: worktreeID, tabID: tabID)

            let expectedCreates: [String] = ["create \(worktreeID)"]
            #expect(creates.events == expectedCreates)
            let applied = envelopes.envelopes.map(\.operation)
            let expectedApplied: [PanelOperation] = [.open(content: .note(noteID: created.id), newPanel: false)]
            #expect(applied == expectedApplied)
            #expect(envelopes.envelopes.first?.tabID == tabID, "the note opens in the tab it came from")
            let listed: [UUID] = state.notes[worktreeID]?.map(\.id) ?? []
            let expectedListed: [UUID] = [created.id]
            #expect(listed == expectedListed)
            #expect(state.tabs[worktreeID] == nil, "a note never becomes a workspace tab")
            #expect(state.panelSurface(worktreeID: worktreeID, tabID: tabID) == reply, "the daemon's reply is adopted")
        }
    }

    @Test("a failed create opens nothing, lists nothing, and shows an error toast")
    func failedCreateOpensNothing() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let tabID = UUID()
            state.noteCreator = { @MainActor _ in
                throw PanelTabsFixture.Rejected(message: "note.create refused")
            }
            // The fixture's `panel.apply` records an issue if it is reached.
            #expect(state.activeToast == nil, "precondition: no toast showing")

            await state.createNote(worktreeID: worktreeID, tabID: tabID)

            #expect(state.notes[worktreeID] == nil)
            #expect(state.tabs[worktreeID] == nil)
            #expect(state.activeToast?.style == .error)
            let message = state.activeToast?.message ?? ""
            #expect(message.contains("note.create refused"), "the toast carries the error: \(message)")
        }
    }

    @Test("a notes refresh that lands while the create is in flight leaves the note listed once")
    func createdNoteIsListedOnce() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let tabID = UUID()
            let surface = Fixture.surface(tabID: tabID, worktreeID: worktreeID, revision: 1)
            state.panelSurfaces = [worktreeID: [tabID: surface]]
            let created = Note(worktreeID: worktreeID, title: "Note")
            state.noteCreator = { @MainActor [weak state] worktreeID in
                // The refresh lists the new note before the create's reply lands.
                state?.adoptNotes([NoteSummary(from: created)], worktreeIDs: [worktreeID])
                return created
            }
            _ = Fixture.collectEnvelopes(state, replying: surface)

            await state.createNote(worktreeID: worktreeID, tabID: tabID)

            let listed: [UUID] = state.notes[worktreeID]?.map { $0.id } ?? []
            let expectedListed: [UUID] = [created.id]
            #expect(listed == expectedListed)
        }
    }
}
