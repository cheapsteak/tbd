import Foundation
import TBDShared

/// A collapsed run of non-narrative transcript rows. The first child ID is the
/// stable identity, so an append-only poll can extend the active group without
/// losing the user's disclosure state.
struct ActivityGroupSummary: Hashable {
    let id: String
    let itemCount: Int
    let labels: [String]
    let errorCount: Int
    let pendingCount: Int
    let requiresResponse: Bool
    let isExpanded: Bool

    var statusLabel: String {
        if requiresResponse { return "Needs response" }
        if errorCount == 1 { return "1 failed" }
        if errorCount > 1 { return "\(errorCount) failed" }
        if pendingCount > 0 { return "In progress" }
        return "Complete"
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
        toggledGroupIDs: Set<String> = []
    ) -> TranscriptPresentation {
        let baseNodes = transcriptRenderNodes(from: items)
        var projected: [TranscriptRenderNode] = []
        projected.reserveCapacity(baseNodes.count)
        var pendingActivity: [TranscriptRenderNode] = []

        func flushActivity() {
            guard let first = pendingActivity.first else { return }
            let groupID = "\(first.id)#activity-group"
            let requiresResponse = pendingActivity.contains(where: isResponseRequired)
            let errorCount = pendingActivity.reduce(into: 0) { total, node in
                if isError(node) { total += 1 }
            }
            let pendingCount = pendingActivity.reduce(into: 0) { total, node in
                if isPending(node) { total += 1 }
            }
            let defaultsExpanded = requiresResponse || errorCount > 0
            let isExpanded = toggledGroupIDs.contains(groupID) ? !defaultsExpanded : defaultsExpanded
            let summary = ActivityGroupSummary(
                id: groupID,
                itemCount: pendingActivity.count,
                labels: representativeLabels(from: pendingActivity),
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

    private nonisolated static func representativeLabels(
        from nodes: [TranscriptRenderNode]
    ) -> [String] {
        var labels: [String] = []
        for node in nodes {
            let label: String
            switch node.kind {
            case .toolCall(_, let name, _, _, _, _):
                label = toolLabel(name)
            case .systemReminder:
                label = "Context"
            case .skillBody:
                label = "Skill"
            case .chatBubble, .activityGroupSummary, .subagentSummary:
                continue
            }
            if !labels.contains(label) { labels.append(label) }
            if labels.count == 3 { break }
        }
        return labels
    }

    private nonisolated static func toolLabel(_ name: String) -> String {
        switch name {
        case "Bash": return "Commands"
        case "Read": return "Reads"
        case "Write": return "Writes"
        case "Edit", "MultiEdit": return "Edits"
        case "Grep", "Glob": return "Search"
        case "Task", "Agent": return "Delegation"
        case "AskUserQuestion": return "Question"
        case "WebFetch", "WebSearch": return "Web"
        default:
            if name.hasPrefix("mcp__") { return "Connected tools" }
            return name
        }
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
