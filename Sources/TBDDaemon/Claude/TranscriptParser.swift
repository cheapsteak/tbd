import Foundation
import TBDShared

/// Loads a Claude Code session JSONL into a structured `[TranscriptItem]`.
/// Replaces `ClaudeSessionScanner.loadMessages` once the cutover task lands.
///
/// This parser is deliberately permissive — malformed or unknown lines are
/// skipped rather than failing the whole session. JSONL writes from Claude
/// Code may be partial during live polling; we tolerate that.
enum TranscriptParser {
    /// Parse a top-level Claude session JSONL into transcript items in file order.
    /// Subagent (sidechain) JSONLs referenced by Task tool_results are recursively
    /// parsed and attached to the corresponding `.toolCall` items.
    static func parse(filePath: String) -> [TranscriptItem] {
        return parse(filePath: filePath, visitedAgentIDs: [], skipSidechain: true)
    }

    /// Recursive worker. `visitedAgentIDs` prevents cycles between subagent files.
    /// `skipSidechain == true` for the parent (top-level) JSONL; `false` when
    /// parsing a subagent file (whose lines all carry `isSidechain: true`).
    private static func parse(
        filePath: String,
        visitedAgentIDs: Set<String>,
        skipSidechain: Bool
    ) -> [TranscriptItem] {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        // First pass: collect raw line dicts; index tool_results and agent ids.
        var rawLines: [[String: Any]] = []
        var toolResultsByID: [String: ToolResult] = [:]
        var agentIDByToolUseID: [String: String] = [:]

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            rawLines.append(json)

            if json["type"] as? String == "user",
               let message = json["message"] as? [String: Any],
               let array = message["content"] as? [[String: Any]] {
                for block in array where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    toolResultsByID[id] = extractToolResult(from: block)
                    if let resultMeta = json["toolUseResult"] as? [String: Any],
                       let agentID = resultMeta["agentId"] as? String {
                        agentIDByToolUseID[id] = agentID
                    }
                }
            }
        }

        // Resolve subagent paths relative to the parent file.
        // Path scheme: <projectDir>/<sessionID>.jsonl   ↔
        //              <projectDir>/<sessionID>/subagents/agent-<agentID>.jsonl
        let parentURL = URL(fileURLWithPath: filePath)
        let projectDir = parentURL.deletingLastPathComponent()
        let sessionID = parentURL.deletingPathExtension().lastPathComponent
        // For top-level files, the subagents dir is keyed by sessionID.
        // For subagent files (already inside .../<sessionID>/subagents/), we need
        // to use the SAME subagents dir for nested subagent resolution.
        let subagentsDir: URL
        if skipSidechain {
            subagentsDir = projectDir.appendingPathComponent(sessionID).appendingPathComponent("subagents")
        } else {
            // We're already inside a subagents/ dir; reuse it for nested agents.
            subagentsDir = projectDir
        }

        let iso = ISO8601DateFormatter()
        var items: [TranscriptItem] = []

        for json in rawLines {
            if skipSidechain, json["isSidechain"] as? Bool == true { continue }

            let lineUUID = (json["uuid"] as? String) ?? UUID().uuidString
            let timestamp = (json["timestamp"] as? String).flatMap { iso.date(from: $0) }
            let typeStr = json["type"] as? String

            if typeStr == "user", let kind = UserMessageClassifier.classify(json) {
                let text = extractUserText(from: json) ?? ""
                if kind == .slashEnvelope {
                    let (name, args) = parseSlashEnvelope(text)
                    items.append(.slashCommand(id: lineUUID, name: name, args: args, timestamp: timestamp))
                } else {
                    items.append(.systemReminder(id: lineUUID, kind: kind, text: text, timestamp: timestamp))
                }
                continue
            }

            if typeStr == "user", UserMessageClassifier.isRealUserMessage(json),
               let text = UserMessageClassifier.extractText(json) {
                items.append(.userPrompt(id: lineUUID, text: text, timestamp: timestamp))
                continue
            }

            // Sidechain user lines that aren't classified as system reminders and
            // aren't a "real" user message under isRealUserMessage's heuristics
            // (which is keyed on the array form) — fall back to treating string
            // content as a user prompt.
            if !skipSidechain, typeStr == "user",
               let message = json["message"] as? [String: Any],
               let s = message["content"] as? String, !s.isEmpty {
                items.append(.userPrompt(id: lineUUID, text: s, timestamp: timestamp))
                continue
            }

            if typeStr == "assistant" {
                guard let message = json["message"] as? [String: Any] else { continue }

                // String-content fallback (matches existing scanner behavior).
                if let s = message["content"] as? String {
                    if !s.isEmpty {
                        items.append(.assistantText(id: "\(lineUUID)#0", text: s, timestamp: timestamp))
                    }
                    continue
                }

                guard let blocks = message["content"] as? [[String: Any]] else { continue }
                for (index, block) in blocks.enumerated() {
                    let blockID = "\(lineUUID)#\(index)"
                    let blockType = block["type"] as? String
                    switch blockType {
                    case "thinking":
                        let text = (block["thinking"] as? String) ?? ""
                        items.append(.thinking(id: blockID, text: text, timestamp: timestamp))
                    case "text":
                        let text = (block["text"] as? String) ?? ""
                        if !text.isEmpty {
                            items.append(.assistantText(id: blockID, text: text, timestamp: timestamp))
                        }
                    case "tool_use":
                        let toolID = (block["id"] as? String) ?? blockID
                        let name = (block["name"] as? String) ?? ""
                        let input = block["input"] ?? [:]
                        let inputData = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
                        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"
                        let result = toolResultsByID[toolID]

                        var subagent: Subagent? = nil
                        if name == "Task", let agentID = agentIDByToolUseID[toolID] {
                            subagent = resolveSubagent(
                                agentID: agentID,
                                subagentsDir: subagentsDir,
                                visitedAgentIDs: visitedAgentIDs
                            )
                        }

                        items.append(.toolCall(
                            id: toolID, name: name, inputJSON: inputJSON,
                            result: result, subagent: subagent, timestamp: timestamp
                        ))
                    default:
                        continue
                    }
                }
            }
        }

        return items
    }

    private static func resolveSubagent(
        agentID: String,
        subagentsDir: URL,
        visitedAgentIDs: Set<String>
    ) -> Subagent? {
        if visitedAgentIDs.contains(agentID) {
            // Cycle detected — surface a single system reminder noting it.
            let cycleNote: TranscriptItem = .systemReminder(
                id: "cycle-\(agentID)",
                kind: .other,
                text: "Subagent recursion cycle detected for agent \(agentID); halting nested parse.",
                timestamp: nil
            )
            return Subagent(agentID: agentID, agentType: nil, items: [cycleNote])
        }

        let jsonlPath = subagentsDir.appendingPathComponent("agent-\(agentID).jsonl").path
        guard FileManager.default.fileExists(atPath: jsonlPath) else { return nil }

        var nextVisited = visitedAgentIDs
        nextVisited.insert(agentID)
        let items = parse(filePath: jsonlPath, visitedAgentIDs: nextVisited, skipSidechain: false)

        let metaPath = subagentsDir.appendingPathComponent("agent-\(agentID).meta.json").path
        let agentType = readAgentType(from: metaPath)

        return Subagent(agentID: agentID, agentType: agentType, items: items)
    }

    private static func readAgentType(from metaPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: metaPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["agentType"] as? String ?? json["agent_type"] as? String
    }

    // MARK: - helpers

    static let bodyCharCap = 2000
    static let bodyLineCap = 30

    static func extractToolResult(from block: [String: Any]) -> ToolResult {
        let isError = (block["is_error"] as? Bool) ?? false
        let raw: String
        if let s = block["content"] as? String {
            raw = s
        } else if let array = block["content"] as? [[String: Any]] {
            raw = array.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            raw = ""
        }

        let (truncated, originalCount) = truncate(raw)
        return ToolResult(
            text: truncated,
            truncatedTo: originalCount == truncated.count ? nil : originalCount,
            isError: isError
        )
    }

    /// Returns (truncatedText, originalCharLength). The caller compares
    /// lengths to decide whether to set `truncatedTo`.
    static func truncate(_ text: String) -> (String, Int) {
        let originalCount = text.count
        var capped = text
        if originalCount > bodyCharCap {
            capped = String(text.prefix(bodyCharCap))
        }
        let lines = capped.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > bodyLineCap {
            capped = lines.prefix(bodyLineCap).joined(separator: "\n")
        }
        return (capped, originalCount)
    }

    static func extractUserText(from json: [String: Any]) -> String? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String { return s }
        if let array = message["content"] as? [[String: Any]] {
            return array.first(where: { $0["type"] as? String == "text" })
                .flatMap { $0["text"] as? String }
        }
        return nil
    }

    /// Returns the un-truncated body text for an item id, or nil if not found.
    /// itemID forms:
    ///  - `tool_use_id` (e.g. "toolu_abc") → returns the matching tool_result content
    ///  - `<lineUUID>#<blockIndex>` → returns the assistant block's text/thinking
    ///  - bare `lineUUID` → returns the user message content
    static func lookupFullBody(filePath: String, itemID: String) -> String? {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Parse the composite id form first.
        let lineUUID: String
        let blockIndex: Int?
        if let hashIdx = itemID.firstIndex(of: "#") {
            lineUUID = String(itemID[..<hashIdx])
            blockIndex = Int(itemID[itemID.index(after: hashIdx)...])
        } else {
            lineUUID = itemID
            blockIndex = nil
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // tool_use_id match — search tool_result blocks within user lines.
            if let message = json["message"] as? [String: Any],
               let array = message["content"] as? [[String: Any]] {
                for block in array where block["type"] as? String == "tool_result" {
                    if (block["tool_use_id"] as? String) == itemID {
                        if let s = block["content"] as? String { return s }
                        if let inner = block["content"] as? [[String: Any]] {
                            return inner.compactMap { $0["text"] as? String }.joined(separator: "\n")
                        }
                    }
                }
            }

            // line UUID match.
            if (json["uuid"] as? String) == lineUUID {
                if let blockIndex,
                   let message = json["message"] as? [String: Any],
                   let blocks = message["content"] as? [[String: Any]],
                   blockIndex < blocks.count {
                    let block = blocks[blockIndex]
                    return (block["text"] as? String) ?? (block["thinking"] as? String)
                }
                if let message = json["message"] as? [String: Any] {
                    if let s = message["content"] as? String { return s }
                    if let array = message["content"] as? [[String: Any]] {
                        return array.first(where: { $0["type"] as? String == "text" })
                            .flatMap { $0["text"] as? String }
                    }
                }
            }
        }
        return nil
    }

    /// Parse `<command-name>foo</command-name><command-args>bar</command-args>` envelopes.
    /// Returns the command name (without leading `/`) and optional args text.
    static func parseSlashEnvelope(_ text: String) -> (name: String, args: String?) {
        func extract(_ tag: String) -> String? {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            guard let openRange = text.range(of: open),
                  let closeRange = text.range(of: close, range: openRange.upperBound..<text.endIndex) else {
                return nil
            }
            return String(text[openRange.upperBound..<closeRange.lowerBound])
        }
        let raw = extract("command-name") ?? ""
        let name = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        let args = extract("command-args")
        return (name, args?.isEmpty == true ? nil : args)
    }
}
