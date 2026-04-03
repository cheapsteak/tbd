import Foundation
import TBDShared

extension RPCRouter {

    // MARK: - Note Handlers

    func handleNoteCreate(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NoteCreateParams.self, from: paramsData)

        guard try await db.worktrees.get(id: params.worktreeID) != nil else {
            return RPCResponse(error: "Worktree not found: \(params.worktreeID)")
        }

        let note = try await db.notes.create(worktreeID: params.worktreeID)
        return try RPCResponse(result: note)
    }

    func handleNoteGet(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NoteGetParams.self, from: paramsData)

        guard let note = try await db.notes.get(id: params.noteID) else {
            return RPCResponse(error: "Note not found: \(params.noteID)")
        }

        return try RPCResponse(result: note)
    }

    func handleNoteUpdate(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NoteUpdateParams.self, from: paramsData)

        let note = try await db.notes.update(
            id: params.noteID,
            title: params.title,
            content: params.content
        )
        return try RPCResponse(result: note)
    }

    func handleNoteDelete(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NoteDeleteParams.self, from: paramsData)
        try await db.notes.delete(id: params.noteID)
        return .ok()
    }

    func handleNoteList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(NoteListParams.self, from: paramsData)
        let notes = try await db.notes.list(worktreeID: params.worktreeID)
        return try RPCResponse(result: notes)
    }
}
