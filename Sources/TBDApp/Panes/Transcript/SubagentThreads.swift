import Foundation
import TBDShared

/// One selectable subagent thread within a session transcript, derived from a
/// `Task`/`Agent` tool call that carries a nested `Subagent`. Pure value type;
/// the Threads column binds to an array of these.
struct SessionThread: Identifiable, Equatable {
    let id: String          // the parent Task toolCall's id (== AgentCard.id)
    let description: String?
    let agentType: String?
    let itemCount: Int       // visible items in the subagent timeline
    let isError: Bool
}

/// Decodes the `description` field from a Task tool call's input JSON. Mirrors
/// the `Input` decoder used by `AgentCard`. Returns nil for missing/empty.
nonisolated func decodeThreadDescription(_ inputJSON: String) -> String? {
    struct Input: Decodable { let description: String? }
    guard let data = inputJSON.data(using: .utf8),
          let parsed = try? JSONDecoder().decode(Input.self, from: data),
          let desc = parsed.description, !desc.isEmpty
    else { return nil }
    return desc
}

/// Flat, appearance-ordered list of every subagent thread in `items`, recursing
/// into nested subagents (depth-2+) so each appears as its own row. Pure; safe
/// off the main actor.
nonisolated func sessionThreads(from items: [TranscriptItem]) -> [SessionThread] {
    var out: [SessionThread] = []
    func walk(_ items: [TranscriptItem]) {
        for item in items {
            guard case .toolCall(let id, let name, let inputJSON, _, let result, let subagent, _, _) = item,
                  name == "Task" || name == "Agent",
                  let sub = subagent
            else { continue }
            let visibleCount = sub.items.filter { !isHiddenInTranscript($0) }.count
            out.append(SessionThread(
                id: id,
                description: decodeThreadDescription(inputJSON),
                agentType: sub.agentType,
                itemCount: visibleCount,
                isError: result?.isError ?? false
            ))
            walk(sub.items)
        }
    }
    walk(items)
    return out
}

/// True when a transcript with these items should show the Threads column.
nonisolated func shouldShowThreadsColumn(_ items: [TranscriptItem]) -> Bool {
    !sessionThreads(from: items).isEmpty
}

/// Resolves which timeline to render for a drill `path`. Empty path → the root
/// (Main) timeline. Each path element is a Task toolCall id at successive
/// nesting levels. An unresolvable id stops at the deepest resolvable prefix
/// (stale-path tolerance). Pure.
nonisolated func resolveThread(root: [TranscriptItem], path: [String]) -> [TranscriptItem] {
    var current = root
    for id in path {
        guard let next = subagentItems(forToolCallID: id, in: current) else { break }
        current = next
    }
    return current
}

/// The heading/breadcrumb label for the deepest path entry, or nil when the
/// path is empty or unresolvable.
nonisolated func threadLabel(root: [TranscriptItem], path: [String]) -> String? {
    guard let last = path.last else { return nil }
    var current = root
    for id in path.dropLast() {
        guard let next = subagentItems(forToolCallID: id, in: current) else { return nil }
        current = next
    }
    for item in current {
        if case .toolCall(let tid, _, let inputJSON, _, _, _, _, _) = item, tid == last {
            return decodeThreadDescription(inputJSON) ?? "Subagent"
        }
    }
    return nil
}

/// Direct-child lookup: the nested subagent timeline of the Task toolCall with
/// `id` among `items` (non-recursive — each drill level is explicit in the path).
private nonisolated func subagentItems(forToolCallID id: String, in items: [TranscriptItem]) -> [TranscriptItem]? {
    for item in items {
        if case .toolCall(let tid, _, _, _, _, let subagent, _, _) = item, tid == id {
            return subagent?.items
        }
    }
    return nil
}
