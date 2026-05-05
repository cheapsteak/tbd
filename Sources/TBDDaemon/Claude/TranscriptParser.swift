import Foundation
import TBDShared

/// Loads a Claude Code session JSONL into a structured `[TranscriptItem]`.
/// Replaces `ClaudeSessionScanner.loadMessages` once the cutover task lands.
///
/// This parser is deliberately permissive — malformed or unknown lines are
/// skipped rather than failing the whole session. JSONL writes from Claude
/// Code may be partial during live polling; we tolerate that.
enum TranscriptParser {
    /// Parse a JSONL file into transcript items in file order.
    /// (Subagent recursion and body truncation land in Tasks 5 and 6.)
    static func parse(filePath: String) -> [TranscriptItem] {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        // First pass: collect raw JSON dicts in order, indexing tool_results by tool_use_id.
        var rawLines: [[String: Any]] = []
        var toolResultsByID: [String: ToolResult] = [:]

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
                }
            }
        }

        // Second pass: emit TranscriptItems for non-sidechain lines.
        let iso = ISO8601DateFormatter()
        var items: [TranscriptItem] = []

        for json in rawLines {
            // Sidechain lines are handled by the recursive subagent parser (Task 5).
            // Skip them here — the parent Task tool_use is what surfaces subagent presence.
            if json["isSidechain"] as? Bool == true { continue }

            let lineUUID = (json["uuid"] as? String) ?? UUID().uuidString
            let timestamp = (json["timestamp"] as? String).flatMap { iso.date(from: $0) }
            let typeStr = json["type"] as? String

            // System / slash command / environment classification first.
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

            if typeStr == "assistant" {
                guard let message = json["message"] as? [String: Any] else { continue }

                // Some sessions (and our minimal fixture) store assistant content
                // as a plain string instead of an array of blocks. Treat that as
                // a single text block.
                if let contentString = message["content"] as? String {
                    if !contentString.isEmpty {
                        items.append(.assistantText(id: "\(lineUUID)#0", text: contentString, timestamp: timestamp))
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
                        items.append(.toolCall(
                            id: toolID, name: name, inputJSON: inputJSON,
                            result: result, subagent: nil, timestamp: timestamp
                        ))
                    default:
                        continue
                    }
                }
            }
        }

        return items
    }

    // MARK: - helpers

    static func extractToolResult(from block: [String: Any]) -> ToolResult {
        let isError = (block["is_error"] as? Bool) ?? false
        let text: String
        if let s = block["content"] as? String {
            text = s
        } else if let array = block["content"] as? [[String: Any]] {
            text = array.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            text = ""
        }
        return ToolResult(text: text, truncatedTo: nil, isError: isError)
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
