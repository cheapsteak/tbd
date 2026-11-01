import Foundation
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

// Tier 1: deterministic, in-process state only. A note's title reaches the
// daemon through the stubbed `noteTitleUpdater` seam (`PanelTabsFixture`).
// Clearing a tab's label goes through `renameTab`, whose persist has no seam:
// its RPC fails with no daemon running, after the in-memory change these
// tests assert (as `TabReorderTests` does).

/// The controls that live on a tab now that panes draw no header (panel tabs
/// spec, "The renderer"): renaming a note's tab in the side region's strip
/// writes the note's title and nothing else, renaming a workspace tab sets
/// its label, a rename asked for on one bar survives the bar moving to
/// another view, the right-click menu offers the terminal's pin, a web tab's
/// tooltip is its full address, and a tab's rename field keeps the label's
/// width.
@Suite("Tab rename, pin and tooltip")
@MainActor
struct TabRenameTests {
    private typealias Fixture = PanelTabsFixture

    // MARK: - Fixtures

    /// One worktree holding one note, titled `title`. Returns the worktree.
    private static func seedNote(_ state: AppState, noteID: UUID, title: String) -> UUID {
        let worktreeID = UUID()
        state.notes = [worktreeID: [NoteSummary(id: noteID, worktreeID: worktreeID, title: title)]]
        return worktreeID
    }

    private static func noteTitle(_ state: AppState, noteID: UUID, worktreeID: UUID) -> String? {
        state.notes[worktreeID]?.first(where: { $0.id == noteID })?.title
    }

    private static func label(_ state: AppState, tabID: UUID, worktreeID: UUID) -> String? {
        state.tabs[worktreeID]?.first(where: { $0.id == tabID })?.label
    }

    /// Stubs the title update to record each write, refusing the titles
    /// `refuses` names and answering every other with the note so titled.
    private static func stubTitleUpdater(
        _ state: AppState, worktreeID: UUID,
        refuses: @escaping @MainActor (String) -> Bool = { _ in false }
    ) -> NoteTitleWriteRecorder {
        let recorder = NoteTitleWriteRecorder()
        state.noteTitleUpdater = { @MainActor noteID, title in
            recorder.record(NoteTitleWrite(noteID: noteID, title: title))
            if refuses(title) {
                throw PanelTabsFixture.Rejected(message: "note.update refused")
            }
            return Note(id: noteID, worktreeID: worktreeID, title: title)
        }
        return recorder
    }

    // MARK: - Renaming a workspace tab

    @Test("renaming a workspace tab sets its label and writes no note title")
    func workspaceTabRenameSetsLabel() async throws {
        let url = try #require(URL(string: "https://example.com/docs"))
        await Fixture.withState { state in
            let worktreeID = UUID()
            let terminal = Fixture.terminalTab()
            let webID = UUID()
            let web = TBDShared.Tab(id: webID, content: .webview(id: webID, url: url), label: "docs")
            state.tabs = [worktreeID: [terminal, web]]

            // An unstubbed `noteTitleUpdater` records an issue if reached.
            state.renameTab(tabID: terminal.id, worktreeID: worktreeID, newLabel: "build")
            state.renameTab(tabID: web.id, worktreeID: worktreeID, newLabel: " ")
            await Fixture.drainMainActor()

            #expect(Self.label(state, tabID: terminal.id, worktreeID: worktreeID) == "build")
            #expect(Self.label(state, tabID: web.id, worktreeID: worktreeID) == nil,
                    "a blank rename clears the label")
        }
    }

    // MARK: - A note's title from a rename

    @Test("a note's rename writes the trimmed text, and nothing when it is blank or already the title")
    func noteTitleFromRename() {
        #expect(TabRename.noteTitle(text: "Plan", currentNoteTitle: "Note") == "Plan")
        #expect(TabRename.noteTitle(text: "  Plan \n", currentNoteTitle: "Note") == "Plan",
                "the title is the trimmed text")
        #expect(TabRename.noteTitle(text: "Plan", currentNoteTitle: nil) == "Plan",
                "a note whose title is not known yet takes the text")
        #expect(TabRename.noteTitle(text: "   ", currentNoteTitle: "Note") == nil)
        #expect(TabRename.noteTitle(text: "", currentNoteTitle: "Note") == nil)
        #expect(TabRename.noteTitle(text: " Note ", currentNoteTitle: "Note") == nil,
                "unchanged once trimmed")
    }

    // MARK: - Renaming a note from the side region's strip

    @Test("renaming a note from the side region's strip writes its title alone; a blank or unchanged one writes nothing")
    func sideNoteRenameWritesTitleOnly() async {
        await Fixture.withState { state in
            let worktreeID = UUID()
            let noteID = UUID()
            let other = Fixture.terminalTab(label: "agent")
            // A note tab held in memory from an older build keeps its label:
            // the rename sets the title and touches no tab.
            let leftover = TBDShared.Tab(id: UUID(), content: .note(noteID: noteID), label: "x")
            state.notes = [worktreeID: [NoteSummary(id: noteID, worktreeID: worktreeID, title: "Note")]]
            state.tabs = [worktreeID: [other, leftover]]
            let writes = Self.stubTitleUpdater(state, worktreeID: worktreeID)

            for text in ["   ", "", "Note", " Note \n"] {
                state.commitSideNoteRename(noteID: noteID, worktreeID: worktreeID, text: text)
            }
            await Fixture.drainMainActor()

            #expect(writes.writes.isEmpty, "a blank or unchanged title writes nothing")
            #expect(state.noteRenameTails.isEmpty, "nor starts a rename")
            #expect(Self.noteTitle(state, noteID: noteID, worktreeID: worktreeID) == "Note")

            state.commitSideNoteRename(noteID: noteID, worktreeID: worktreeID, text: "  Plan ")

            // At once, before the persist task runs: no flash of the old title.
            #expect(Self.noteTitle(state, noteID: noteID, worktreeID: worktreeID) == "Plan",
                    "the trimmed title shows at once")
            #expect(writes.writes.isEmpty, "the title persists on a task, never inline")
            await Fixture.drainMainActor()
            let expectedWrites: [NoteTitleWrite] = [NoteTitleWrite(noteID: noteID, title: "Plan")]
            #expect(writes.writes == expectedWrites)
            let expectedTabs: [TBDShared.Tab] = [other, leftover]
            #expect(state.tabs[worktreeID] == expectedTabs, "no workspace tab changes")
        }
    }

    // MARK: - Persisting a note's title

    @Test("a failed note rename restores the title")
    func failedNoteRenameRestoresTitle() async {
        await Fixture.withState { state in
            let noteID = UUID()
            let worktreeID = Self.seedNote(state, noteID: noteID, title: "Note")
            let writes = Self.stubTitleUpdater(state, worktreeID: worktreeID, refuses: { _ in true })

            state.renameNote(noteID: noteID, worktreeID: worktreeID, title: "Plan")
            #expect(Self.noteTitle(state, noteID: noteID, worktreeID: worktreeID) == "Plan",
                    "the title shows at once")

            await Fixture.drainMainActor()

            #expect(writes.writes.count == 1)
            #expect(Self.noteTitle(state, noteID: noteID, worktreeID: worktreeID) == "Note")
        }
    }

    @Test("a failed note rename followed by one that succeeds ends on the second's title")
    func failedNoteRenameKeepsLaterTitle() async {
        await Fixture.withState { state in
            let noteID = UUID()
            let worktreeID = Self.seedNote(state, noteID: noteID, title: "Note")
            let writes = Self.stubTitleUpdater(
                state, worktreeID: worktreeID, refuses: { $0 == "First" })

            state.renameNote(noteID: noteID, worktreeID: worktreeID, title: "First")
            state.renameNote(noteID: noteID, worktreeID: worktreeID, title: "Second")
            await Fixture.drainMainActor()

            #expect(writes.writes.count == 2)
            #expect(Self.noteTitle(state, noteID: noteID, worktreeID: worktreeID) == "Second")
            #expect(state.noteRenameTails.isEmpty, "the chain drained")
        }
    }

    /// The first failure leaves the title to the rename queued behind it,
    /// which must put back what the daemon holds — not the first rename's
    /// title, which never persisted.
    @Test("two failed renames of one note restore the title the daemon holds")
    func twoFailedNoteRenamesRestoreTheDaemonsTitle() async {
        await Fixture.withState { state in
            let noteID = UUID()
            let worktreeID = Self.seedNote(state, noteID: noteID, title: "Note")
            let writes = Self.stubTitleUpdater(state, worktreeID: worktreeID, refuses: { _ in true })

            state.renameNote(noteID: noteID, worktreeID: worktreeID, title: "First")
            state.renameNote(noteID: noteID, worktreeID: worktreeID, title: "Second")
            await Fixture.drainMainActor()

            let expectedWrites: [NoteTitleWrite] = [
                NoteTitleWrite(noteID: noteID, title: "First"),
                NoteTitleWrite(noteID: noteID, title: "Second"),
            ]
            #expect(writes.writes == expectedWrites)
            #expect(Self.noteTitle(state, noteID: noteID, worktreeID: worktreeID) == "Note")
            #expect(state.noteRenameTails.isEmpty, "the chain drained")
        }
    }

    @Test("a note rename that succeeds then one that fails restores the first's title")
    func failedNoteRenameAfterASuccessRestoresIt() async {
        await Fixture.withState { state in
            let noteID = UUID()
            let worktreeID = Self.seedNote(state, noteID: noteID, title: "Note")
            let writes = Self.stubTitleUpdater(
                state, worktreeID: worktreeID, refuses: { $0 == "Second" })

            state.renameNote(noteID: noteID, worktreeID: worktreeID, title: "First")
            state.renameNote(noteID: noteID, worktreeID: worktreeID, title: "Second")
            await Fixture.drainMainActor()

            #expect(writes.writes.count == 2)
            #expect(Self.noteTitle(state, noteID: noteID, worktreeID: worktreeID) == "First",
                    "the daemon holds the first title")
            #expect(state.noteRenameTails.isEmpty, "the chain drained")
        }
    }

    @Test("two renames of one note reach the daemon in order, though the first finishes after the second was asked for")
    func renamesOfOneNotePersistInOrder() async throws {
        try await Fixture.withState { state in
            let noteID = UUID()
            let worktreeID = Self.seedNote(state, noteID: noteID, title: "Note")
            let log = PanelEventLog()
            let gate = PanelCallGate()
            state.noteTitleUpdater = { @MainActor noteID, title in
                log.record("call \(title)")
                // The first rename's write is still in flight on the daemon
                // until the test releases it.
                if title == "First" { await gate.wait() }
                log.record("commit \(title)")
                return Note(id: noteID, worktreeID: worktreeID, title: title)
            }

            state.renameNote(noteID: noteID, worktreeID: worktreeID, title: "First")
            await Fixture.drainMainActor()
            try #require(gate.isHolding, "precondition: the first rename is in flight")
            state.renameNote(noteID: noteID, worktreeID: worktreeID, title: "Second")
            await Fixture.drainMainActor()

            let whileFirstInFlight: [String] = ["call First"]
            #expect(log.events == whileFirstInFlight, "the second rename waits for the first")
            #expect(Self.noteTitle(state, noteID: noteID, worktreeID: worktreeID) == "Second",
                    "the app shows the latest title at once")

            gate.release()
            await Fixture.drainMainActor()

            let expectedEvents: [String] = ["call First", "commit First", "call Second", "commit Second"]
            #expect(log.events == expectedEvents)
            #expect(Self.noteTitle(state, noteID: noteID, worktreeID: worktreeID) == "Second")
            #expect(state.noteRenameTails.isEmpty, "the chain drained")
        }
    }

    @Test("renames of two notes do not wait for each other")
    func renamesOfTwoNotesDoNotWait() async throws {
        try await Fixture.withState { state in
            let worktreeID = UUID()
            let heldID = UUID()
            let freeID = UUID()
            state.notes = [worktreeID: [
                NoteSummary(id: heldID, worktreeID: worktreeID, title: "Held"),
                NoteSummary(id: freeID, worktreeID: worktreeID, title: "Free"),
            ]]
            let log = PanelEventLog()
            let gate = PanelCallGate()
            state.noteTitleUpdater = { @MainActor noteID, title in
                log.record("call \(title)")
                if noteID == heldID { await gate.wait() }
                log.record("commit \(title)")
                return Note(id: noteID, worktreeID: worktreeID, title: title)
            }

            state.renameNote(noteID: heldID, worktreeID: worktreeID, title: "Held renamed")
            await Fixture.drainMainActor()
            try #require(gate.isHolding, "precondition: the first note's rename is in flight")
            state.renameNote(noteID: freeID, worktreeID: worktreeID, title: "Free renamed")
            await Fixture.drainMainActor()

            let whileHeld: [String] = ["call Held renamed", "call Free renamed", "commit Free renamed"]
            #expect(log.events == whileHeld, "the other note's rename went out beside the held one")

            gate.release()
            await Fixture.drainMainActor()
            #expect(state.noteRenameTails.isEmpty)
        }
    }

    // MARK: - The rename field's width

    @Test("a tab's rename field keeps the label's width from when editing began, never under 60 pt")
    func renameFieldKeepsTheLabelsWidth() {
        let wideLabel: CGFloat = 140
        let narrowLabel: CGFloat = 24
        let unmeasured: CGFloat = 0
        let floor: CGFloat = 60
        #expect(TabRenameFieldWidth.minimum(labelWidth: wideLabel) == wideLabel)
        #expect(TabRenameFieldWidth.minimum(labelWidth: narrowLabel) == floor)
        #expect(TabRenameFieldWidth.minimum(labelWidth: unmeasured) == floor)
        #expect(TabRenameFieldWidth.floor == floor)
    }

    // MARK: - A rename across a change of view

    @Test("a pending rename opens the matching tab's field once, and no other tab's")
    func pendingRenamePickUp() async {
        let tabID = UUID()
        let otherID = UUID()
        let matching = TabRenamePickUp.decide(tabID: tabID, pendingID: tabID)
        let expectedMatching = TabRenamePickUp(startsEditing: true, pendingIDAfter: nil)
        #expect(matching == expectedMatching)
        let other = TabRenamePickUp.decide(tabID: otherID, pendingID: tabID)
        let expectedOther = TabRenamePickUp(startsEditing: false, pendingIDAfter: tabID)
        #expect(other == expectedOther)
        let nothingPending = TabRenamePickUp.decide(tabID: tabID, pendingID: nil)
        let expectedNothing = TabRenamePickUp(startsEditing: false, pendingIDAfter: nil)
        #expect(nothingPending == expectedNothing)

        await Fixture.withState { state in
            state.requestTabRename(tabID: tabID)
            #expect(state.pendingTabRenameID == tabID)

            #expect(!state.takePendingTabRename(tabID: otherID))
            #expect(state.pendingTabRenameID == tabID, "another tab's item leaves the request")

            #expect(state.takePendingTabRename(tabID: tabID))
            #expect(state.pendingTabRenameID == nil, "the matching item clears the request")
            #expect(!state.takePendingTabRename(tabID: tabID), "a taken request opens the field once")
        }
    }

    // MARK: - Pin and tooltip

    @Test("the pin menu offers Pin, Unpin, or nothing")
    func pinMenuTitle() {
        let unpinned = TBDShared.Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1")
        let pinned = TBDShared.Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            pinnedAt: Date(timeIntervalSince1970: 1_000))
        let noTerminal: TBDShared.Terminal? = nil
        #expect(TabPinMenu.title(for: unpinned) == "Pin")
        #expect(TabPinMenu.title(for: pinned) == "Unpin")
        #expect(TabPinMenu.title(for: noTerminal) == nil)
    }

    @Test("a web tab's tooltip is its full address; no other tab has one")
    func webTabTooltip() throws {
        let url = try #require(URL(string: "https://example.com/docs/page?q=1#top"))
        let web: PaneContent = .webview(id: UUID(), url: url)
        #expect(WorkspaceTabTooltip.text(for: web) == "https://example.com/docs/page?q=1#top")

        let others: [PaneContent] = [
            .terminal(terminalID: UUID()),
            .note(noteID: UUID()),
            .codeViewer(id: UUID(), path: "/w/a.md"),
            .liveTranscript(id: UUID(), terminalID: UUID()),
        ]
        for content in others {
            let tooltip = WorkspaceTabTooltip.text(for: content)
            #expect(tooltip == nil, "\(content) has no tooltip")
        }
    }
}

/// One title sent to the daemon.
private struct NoteTitleWrite: Equatable {
    let noteID: UUID
    let title: String
}

/// Every title sent to the daemon, in order.
@MainActor
private final class NoteTitleWriteRecorder {
    private(set) var writes: [NoteTitleWrite] = []
    func record(_ write: NoteTitleWrite) { writes.append(write) }
}
