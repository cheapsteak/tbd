import ArgumentParser
import Foundation
import Testing
import TBDShared

@testable import TBDCLI

@Suite("tbd note list")
struct NoteCommandsTests {
    private let worktreeID = UUID()

    private func note(_ title: String, created: TimeInterval) -> NoteSummary {
        NoteSummary(
            worktreeID: worktreeID, title: title,
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: created))
    }

    @Test func entriesCarryAPanelExactlyForNotesWithOne() {
        let shown = note("Shown", created: 1)
        let hidden = note("Hidden", created: 2)
        let panelID = UUID()
        let panels = [
            WorktreePanel(id: UUID(), content: .changes),
            WorktreePanel(id: panelID, content: .note(noteID: shown.id)),
        ]
        let entries = noteListEntries(notes: [shown, hidden], worktreePanels: panels)
        #expect(entries == [
            NoteListEntry(id: shown.id, title: "Shown", hasPanel: true, panelID: panelID),
            NoteListEntry(id: hidden.id, title: "Hidden", hasPanel: false, panelID: nil),
        ])
    }

    @Test func entriesAreOrderedByCreation() {
        let older = note("Older", created: 1)
        let newer = note("Newer", created: 2)
        let entries = noteListEntries(notes: [newer, older], worktreePanels: [])
        #expect(entries.map(\.title) == ["Older", "Newer"])
    }

    @Test func linesShowThePanelOrNoPanel() {
        let withPanel = NoteListEntry(id: UUID(), title: "A", hasPanel: true, panelID: UUID())
        let without = NoteListEntry(id: UUID(), title: "B", hasPanel: false, panelID: nil)
        let lines = noteListLines([withPanel, without])
        #expect(lines[0] == "\(withPanel.id)  A  panel \(withPanel.panelID!)")
        #expect(lines[1] == "\(without.id)  B  no panel")
    }

    @Test func anUntitledNoteReadsNoteInTextButKeepsItsTitleInJSON() {
        let entry = NoteListEntry(id: UUID(), title: "", hasPanel: false, panelID: nil)
        #expect(noteListLines([entry]) == ["\(entry.id)  Note  no panel"])
        #expect(entry.title.isEmpty)
    }

    @Test func topLevelCommandRegistersNote() {
        #expect(TBDCommand.configuration.subcommands.contains { $0._commandName == "note" })
    }

    @Test func noNotesSaysSo() {
        #expect(noteListLines([]) == ["No notes found."])
    }

    @Test func listParsesWithJSONFlag() throws {
        let cmd = try NoteList.parse(["wt", "--json"])
        #expect(cmd.worktree == "wt")
        #expect(cmd.json)
        #expect(!(try NoteList.parse(["wt"])).json)
    }

    @Test func noteCommandListsTheListVerb() {
        let names = NoteCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(names == ["list"])
    }
}
