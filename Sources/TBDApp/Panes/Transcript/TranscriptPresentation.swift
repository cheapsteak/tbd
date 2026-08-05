import Foundation
import TBDShared

/// One vocabulary entry in a collapsed group's activity phrase. Each bucket
/// with a nonzero count contributes exactly one clause, and `allCases`
/// declaration order IS the clause order — fixed by this list, never
/// chronological.
///
/// The first eight mirror Claude Code's own renderer verbatim (including
/// `bash` genuinely coming last). The remaining four exist because TBD groups
/// rows Claude Code's summary never sees — web tools, `AskUserQuestion`,
/// injected context and skill bodies all reach a group here, and folding them
/// into `other` would report an injected CLAUDE.md as "called 1 tool".
enum ActivityBucket: String, CaseIterable, Hashable {
    case edit
    case search
    case read
    case list
    case web
    case mcp
    case agent
    case question
    case context
    case skill
    case other
    case bash

    /// Present participle while the group is still running, simple past once
    /// every item has landed.
    var verbs: (running: String, done: String) {
        switch self {
        case .edit: return ("editing", "edited")
        case .search: return ("searching for", "searched for")
        case .read: return ("reading", "read")
        case .list: return ("listing", "listed")
        case .web: return ("fetching", "fetched")
        case .mcp: return ("calling", "called")
        case .agent: return ("running", "ran")
        case .question: return ("asking", "asked")
        case .context: return ("including", "included")
        case .skill: return ("loading", "loaded")
        case .other: return ("calling", "called")
        case .bash: return ("running", "ran")
        }
    }

    /// Per-clause singular/plural pair. `mcp` names servers instead of a noun,
    /// so it never consults this.
    func noun(count: Int) -> String {
        switch self {
        case .edit, .read: return count == 1 ? "file" : "files"
        case .search: return count == 1 ? "pattern" : "patterns"
        case .list: return count == 1 ? "directory" : "directories"
        case .web: return count == 1 ? "URL" : "URLs"
        case .agent: return count == 1 ? "agent" : "agents"
        case .question: return count == 1 ? "question" : "questions"
        case .context: return count == 1 ? "context injection" : "context injections"
        case .skill: return count == 1 ? "skill" : "skills"
        case .bash: return count == 1 ? "shell command" : "shell commands"
        case .mcp, .other: return count == 1 ? "tool" : "tools"
        }
    }

    /// `<verb> <count> <noun>`, always lowercase — the caller capitalizes only
    /// the first clause of the joined phrase. Counts stay numerals.
    ///
    /// `mcp` is the one irregular form: it names the servers rather than
    /// counting tools ("called github", "called github, sentry 3 times"),
    /// falling back to the regular shape if no server name could be read.
    func clause(count: Int, running: Bool, mcpServers: [String] = []) -> String {
        let verb = running ? verbs.running : verbs.done
        if self == .mcp, !mcpServers.isEmpty {
            let names = mcpServers.joined(separator: ", ")
            return count > 1 ? "\(verb) \(names) \(count) times" : "\(verb) \(names)"
        }
        return "\(verb) \(count) \(noun(count: count))"
    }
}

/// A collapsed run of non-narrative transcript rows. The first child ID is the
/// stable identity, so an append-only poll can extend the active group without
/// losing the user's disclosure state.
struct ActivityGroupSummary: Hashable {
    let id: String
    /// Total grouped rows. Drives the ≥2 unwrap rule and nothing user-visible —
    /// the row title reports per-bucket counts, not a raw action total.
    let itemCount: Int
    /// Per-bucket tallies behind `activityPhrase`. `read` counts DISTINCT file
    /// paths, so three reads of one file say "Read 1 file".
    let bucketCounts: [ActivityBucket: Int]
    /// Distinct MCP server names, in first-appearance order.
    let mcpServers: [String]
    let errorCount: Int
    let pendingCount: Int
    let requiresResponse: Bool
    let isExpanded: Bool

    init(
        id: String,
        itemCount: Int,
        bucketCounts: [ActivityBucket: Int],
        mcpServers: [String] = [],
        errorCount: Int = 0,
        pendingCount: Int = 0,
        requiresResponse: Bool = false,
        isExpanded: Bool = false
    ) {
        self.id = id
        self.itemCount = itemCount
        self.bucketCounts = bucketCounts
        self.mcpServers = mcpServers
        self.errorCount = errorCount
        self.pendingCount = pendingCount
        self.requiresResponse = requiresResponse
        self.isExpanded = isExpanded
    }

    /// The row's whole title, in Claude Code's phrasing: "Ran 2 shell
    /// commands", "Read 3 files", "Ran 2 shell commands, read 1 file".
    ///
    /// One clause per nonzero bucket, joined with ", " — a flat comma list with
    /// no "and", no "N more", no generic fallback. Only the FIRST clause is
    /// capitalized; later clauses stay lowercase. While anything in the group is
    /// still pending, every verb goes to its present participle and the phrase
    /// gains a trailing "…", which is why the row carries no separate "active"
    /// badge: the tense already says it.
    ///
    /// Both renderers read this one property. The previous per-renderer segment
    /// assembly is what let the native and SwiftUI rows drift apart.
    var activityPhrase: String {
        let running = pendingCount > 0
        let clauses = ActivityBucket.allCases.compactMap { bucket -> String? in
            guard let count = bucketCounts[bucket], count > 0 else { return nil }
            return bucket.clause(count: count, running: running, mcpServers: mcpServers)
        }
        // Unreachable: every render-node kind maps to a bucket, so a group with
        // items always has at least one clause. Total function, not a fallback
        // vocabulary — there is deliberately no generic "N actions" phrasing.
        guard let first = clauses.first else { return "" }
        let phrase = ([first.prefix(1).uppercased() + first.dropFirst()] + clauses.dropFirst())
            .joined(separator: ", ")
        return running ? phrase + "…" : phrase
    }

    /// Trailing status text, or nil when nothing in the group needs attention.
    /// A fully-successful group says nothing: the row's own content already
    /// reads as done, so a "complete" label was redundant chrome on the common
    /// case. Pending work says nothing either — `activityPhrase` already renders
    /// it as "Running 2 shell commands…". Non-nil exactly when
    /// `requiresResponse || errorCount > 0`.
    var statusLabel: String? {
        if requiresResponse { return "Needs response" }
        if errorCount == 1 { return "1 failed" }
        if errorCount > 1 { return "\(errorCount) failed" }
        return nil
    }
}

enum SessionIndexCategory: String, CaseIterable, Hashable {
    case changed
    case sources
    case web
    case delegates

    var title: String {
        switch self {
        case .changed: return "Changed"
        case .sources: return "Sources"
        case .web: return "Web"
        case .delegates: return "Delegates"
        }
    }

    var iconSystemName: String {
        switch self {
        case .changed: return "square.and.pencil"
        case .sources: return "doc.text.magnifyingglass"
        case .web: return "globe"
        case .delegates: return "person.2"
        }
    }
}

struct SessionIndexEntry: Identifiable, Equatable {
    let category: SessionIndexCategory
    let target: String
    var transcriptItemID: String
    var count: Int

    var id: String { "\(category.rawValue):\(target)" }

    var title: String {
        switch category {
        case .changed, .sources:
            let name = URL(fileURLWithPath: target).lastPathComponent
            return name.isEmpty ? target : name
        case .web, .delegates:
            return target
        }
    }

    var detail: String? {
        guard title != target else { return nil }
        return target
    }
}

struct SessionIndexSection: Identifiable, Equatable {
    let category: SessionIndexCategory
    let entries: [SessionIndexEntry]
    var id: SessionIndexCategory { category }
}

enum SessionIndexDisplayMode: Equatable {
    case inlineRail
    case inspector

    static let inlineThreshold: CGFloat = 980

    static func resolve(width: CGFloat) -> Self {
        width >= inlineThreshold ? .inlineRail : .inspector
    }
}

/// Pure session-local projection for the transcript workbench. It never changes
/// transcript data: grouping only controls which existing rows appear beside a
/// summary, and index extraction only reads structured tool input JSON.
struct TranscriptPresentation {
    let nodes: [TranscriptRenderNode]
    let indexSections: [SessionIndexSection]

    var indexEntryCount: Int {
        indexSections.reduce(0) { $0 + $1.entries.count }
    }

    nonisolated static func build(
        items: [TranscriptItem],
        expansionOverrides: [String: Bool] = [:]
    ) -> TranscriptPresentation {
        let baseNodes = transcriptRenderNodes(from: items)
        var projected: [TranscriptRenderNode] = []
        projected.reserveCapacity(baseNodes.count)
        var pendingActivity: [TranscriptRenderNode] = []

        func flushActivity() {
            guard let first = pendingActivity.first else { return }
            // A run of exactly one activity is not worth wrapping: a "Read 1
            // file" summary repeats what the row underneath already says and
            // offers a disclosure control with nothing behind it. Emit the row
            // itself, as if it had never been grouped. Both renderers inherit
            // this — neither can see a one-item summary node. (Claude Code
            // collapses only runs of two or more for the same reason.)
            if pendingActivity.count == 1 {
                projected.append(first)
                pendingActivity.removeAll(keepingCapacity: true)
                return
            }
            let groupID = "\(first.id)#activity-group"
            let requiresResponse = pendingActivity.contains(where: isResponseRequired)
            let errorCount = pendingActivity.reduce(into: 0) { total, node in
                if isError(node) { total += 1 }
            }
            let pendingCount = pendingActivity.reduce(into: 0) { total, node in
                if isPending(node) { total += 1 }
            }
            let defaultsExpanded = requiresResponse || errorCount > 0
            let isExpanded = expansionOverrides[groupID] ?? defaultsExpanded
            let tally = activityTally(of: pendingActivity)
            let summary = ActivityGroupSummary(
                id: groupID,
                itemCount: pendingActivity.count,
                bucketCounts: tally.counts,
                mcpServers: tally.mcpServers,
                errorCount: errorCount,
                pendingCount: pendingCount,
                requiresResponse: requiresResponse,
                isExpanded: isExpanded
            )
            projected.append(TranscriptRenderNode(
                id: groupID,
                kind: .activityGroupSummary(summary),
                badgeUsage: nil
            ))
            if isExpanded { projected.append(contentsOf: pendingActivity) }
            pendingActivity.removeAll(keepingCapacity: true)
        }

        for node in baseNodes {
            if case .chatBubble = node.kind {
                flushActivity()
                projected.append(node)
            } else {
                pendingActivity.append(node)
            }
        }
        flushActivity()

        return TranscriptPresentation(
            nodes: projected,
            indexSections: makeIndexSections(from: items)
        )
    }

    private nonisolated static func isResponseRequired(_ node: TranscriptRenderNode) -> Bool {
        if case .toolCall(_, let name, _, _, _, _) = node.kind {
            return name == "AskUserQuestion"
        }
        return false
    }

    private nonisolated static func isError(_ node: TranscriptRenderNode) -> Bool {
        if case .toolCall(_, _, _, _, let result, _) = node.kind {
            return result?.isError == true
        }
        return false
    }

    private nonisolated static func isPending(_ node: TranscriptRenderNode) -> Bool {
        if case .toolCall(_, let name, _, _, let result, _) = node.kind {
            return name != "AskUserQuestion" && result == nil
        }
        return false
    }

    /// Tallies a group's rows into the buckets `activityPhrase` reads.
    ///
    /// Counts here are monotonic across polls by construction: a group's member
    /// list is append-only (a narrative bubble ends the run rather than
    /// reordering it) and each row's bucket is a pure function of its tool name,
    /// which never changes once written. So a streaming render can only ever see
    /// a count hold or rise — no separate high-water-mark state is needed, and
    /// `TranscriptPresentation.build` stays a pure function of its inputs.
    nonisolated static func activityTally(
        of nodes: [TranscriptRenderNode]
    ) -> (counts: [ActivityBucket: Int], mcpServers: [String]) {
        var counts: [ActivityBucket: Int] = [:]
        var mcpServers: [String] = []
        // Reads are counted by DISTINCT target, so re-reading one file three
        // times (a very common shape) says "Read 1 file" rather than "3 files".
        var readTargets: Set<String> = []

        for node in nodes {
            let bucket = activityBucket(for: node)
            switch bucket {
            case .read:
                // A read whose path could not be parsed falls back to its own
                // row identity, so it still counts once and never merges with
                // an unrelated read.
                let target = readFilePath(of: node) ?? node.id
                guard readTargets.insert(target).inserted else { continue }
            case .mcp:
                if case .toolCall(_, let name, _, _, _, _) = node.kind,
                   let server = mcpServerName(name),
                   !mcpServers.contains(server) {
                    mcpServers.append(server)
                }
            default:
                break
            }
            counts[bucket, default: 0] += 1
        }
        return (counts, mcpServers)
    }

    /// Total classification: every render-node kind lands in exactly one bucket,
    /// which is what makes `activityPhrase` non-empty for any real group.
    nonisolated static func activityBucket(for node: TranscriptRenderNode) -> ActivityBucket {
        switch node.kind {
        case .toolCall(_, let name, _, _, _, _):
            return activityBucket(forToolNamed: name)
        case .systemReminder:
            return .context
        case .skillBody:
            return .skill
        case .chatBubble, .activityGroupSummary, .subagentSummary:
            // Unreachable in a group: bubbles flush the run, and the other two
            // are never produced by `transcriptRenderNodes(from:)`.
            return .other
        }
    }

    nonisolated static func activityBucket(forToolNamed name: String) -> ActivityBucket {
        switch name {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return .edit
        case "Grep", "Glob": return .search
        case "Read", "NotebookRead": return .read
        case "LS": return .list
        case "WebFetch", "WebSearch": return .web
        case "Task", "Agent": return .agent
        case "AskUserQuestion": return .question
        case "Bash": return .bash
        default:
            return name.hasPrefix("mcp__") ? .mcp : .other
        }
    }

    /// `mcp__github__list_prs` → `github`. Nil for anything that is not an MCP
    /// tool name or carries no server segment.
    nonisolated static func mcpServerName(_ toolName: String) -> String? {
        guard toolName.hasPrefix("mcp__") else { return nil }
        let server = toolName.dropFirst("mcp__".count)
            .components(separatedBy: "__")
            .first ?? ""
        return server.isEmpty ? nil : server
    }

    private nonisolated static func readFilePath(of node: TranscriptRenderNode) -> String? {
        guard case .toolCall(_, _, let inputJSON, _, _, _) = node.kind,
              let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return stringValue("file_path", in: object)
            ?? stringValue("notebook_path", in: object)
    }

    private struct EntryKey: Hashable {
        let category: SessionIndexCategory
        let target: String
    }

    private nonisolated static func makeIndexSections(
        from items: [TranscriptItem]
    ) -> [SessionIndexSection] {
        var orderedKeys: [EntryKey] = []
        var entries: [EntryKey: SessionIndexEntry] = [:]

        for item in items {
            guard case .toolCall(let id, let name, let inputJSON, _, _, _, _, _) = item,
                  let candidate = indexCandidate(toolName: name, inputJSON: inputJSON) else {
                continue
            }
            let target = candidate.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            let key = EntryKey(category: candidate.category, target: target)
            if var existing = entries[key] {
                existing.count += 1
                existing.transcriptItemID = id
                entries[key] = existing
            } else {
                orderedKeys.append(key)
                entries[key] = SessionIndexEntry(
                    category: candidate.category,
                    target: target,
                    transcriptItemID: id,
                    count: 1
                )
            }
        }

        return SessionIndexCategory.allCases.compactMap { category in
            let categoryEntries = orderedKeys.compactMap { key -> SessionIndexEntry? in
                guard key.category == category else { return nil }
                return entries[key]
            }
            guard !categoryEntries.isEmpty else { return nil }
            return SessionIndexSection(category: category, entries: categoryEntries)
        }
    }

    private nonisolated static func indexCandidate(
        toolName: String,
        inputJSON: String
    ) -> (category: SessionIndexCategory, target: String)? {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        switch toolName {
        case "Write", "Edit", "MultiEdit":
            return stringValue("file_path", in: object).map { (.changed, $0) }
        case "Read":
            return stringValue("file_path", in: object).map { (.sources, $0) }
        case "Task", "Agent":
            return stringValue("description", in: object).map { (.delegates, $0) }
        case "WebFetch":
            return stringValue("url", in: object).map { (.web, $0) }
        case "WebSearch":
            return stringValue("query", in: object).map { (.web, $0) }
        default:
            guard isRecognizedMCPWebTool(toolName) else { return nil }
            if let url = stringValue("url", in: object) { return (.web, url) }
            return stringValue("query", in: object).map { (.web, $0) }
        }
    }

    private nonisolated static func stringValue(
        _ key: String,
        in object: [String: Any]
    ) -> String? {
        object[key] as? String
    }

    private nonisolated static func isRecognizedMCPWebTool(_ name: String) -> Bool {
        guard name.hasPrefix("mcp__"), let leaf = name.split(separator: "__").last else {
            return false
        }
        return [
            "browser_navigate", "browser_open", "browser_search", "web_fetch", "web_search"
        ].contains(String(leaf))
    }
}
