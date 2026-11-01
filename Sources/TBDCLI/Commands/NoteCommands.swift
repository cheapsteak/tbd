import ArgumentParser
import Foundation
import TBDShared

struct NoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "List a worktree's notes",
        subcommands: [NoteList.self]
    )
}

// MARK: - note list

struct NoteList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List a worktree's notes and which have a panel — read-only",
        discussion: """
            Each note shows its ID, title, and the panel showing it, if any. Open a note \
            that has no panel with `tbd panel open <worktree> --note <id>`.
            """
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)
        let notes: [NoteSummary] = try client.call(
            method: RPCMethod.noteList,
            params: NoteListParams(worktreeID: worktreeID),
            resultType: [NoteSummary].self
        )
        // Unscoped: the reply carries the worktree's panels even when it has no
        // tab surface.
        let panels: PanelGetResult = try client.call(
            method: RPCMethod.panelGet,
            params: PanelGetParams(worktreeID: worktreeID, tabID: nil),
            resultType: PanelGetResult.self
        )
        let entries = noteListEntries(notes: notes, worktreePanels: panels.worktreePanels)
        if json {
            printJSON(entries)
        } else {
            for line in noteListLines(entries) {
                print(line)
            }
        }
    }
}

/// One note in `tbd note list`: its ID and title, and the worktree panel
/// showing it, if any.
struct NoteListEntry: Codable, Equatable {
    let id: UUID
    let title: String
    let hasPanel: Bool
    let panelID: UUID?
}

/// `notes` oldest first, each paired with the worktree panel that shows it.
func noteListEntries(notes: [NoteSummary], worktreePanels: [WorktreePanel]) -> [NoteListEntry] {
    var panelByNote: [UUID: PanelID] = [:]
    for panel in worktreePanels {
        if case .note(let noteID) = panel.content {
            panelByNote[noteID] = panel.id
        }
    }
    return notes.sorted { $0.createdAt < $1.createdAt }.map { note in
        let panelID = panelByNote[note.id]
        return NoteListEntry(
            id: note.id, title: note.title, hasPanel: panelID != nil, panelID: panelID)
    }
}

/// The text `tbd note list` prints (an untitled note reads "Note"), or a
/// message when there is none.
func noteListLines(_ entries: [NoteListEntry]) -> [String] {
    guard !entries.isEmpty else { return ["No notes found."] }
    return entries.map { entry in
        let title = entry.title.isEmpty ? "Note" : entry.title
        if let panelID = entry.panelID {
            return "\(entry.id)  \(title)  panel \(panelID)"
        }
        return "\(entry.id)  \(title)  no panel"
    }
}

/// Resolve a worktree argument that could be a UUID or a name. Duplicated,
/// like the copies in `PanelCommands.swift` and `TerminalCommands.swift`
/// (each `private`), rather than promoted to a shared helper: an internal
/// twin would make every call in those files ambiguous.
private func resolveWorktreeArg(_ nameOrID: String, client: SocketClient) throws -> UUID {
    if let id = UUID(uuidString: nameOrID) {
        return id
    }
    let worktrees: [Worktree] = try client.call(
        method: RPCMethod.worktreeList,
        params: WorktreeListParams(),
        resultType: [Worktree].self
    )
    let matches = worktrees.filter { $0.name == nameOrID || $0.displayName == nameOrID }
    guard let match = matches.first else {
        throw CLIError.invalidArgument("No worktree found with name or ID: \(nameOrID)")
    }
    if matches.count > 1 {
        throw CLIError.invalidArgument("Multiple worktrees match '\(nameOrID)'. Use the full ID instead.")
    }
    return match.id
}
