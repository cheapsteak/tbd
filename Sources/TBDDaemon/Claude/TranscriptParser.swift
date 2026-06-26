import Foundation
import os
import TBDShared

/// Loads a Claude Code session JSONL into a structured `[TranscriptItem]`.
///
/// This parser is deliberately permissive — malformed or unknown lines are
/// skipped rather than failing the whole session. JSONL writes from Claude
/// Code may be partial during live polling; we tolerate that.
enum TranscriptParser {
    private static let perfLog = Logger(subsystem: "com.tbd.daemon", category: "perf-transcript")
    /// Shared ISO8601 formatter that accepts Claude Code's fractional-seconds
    /// timestamps (e.g. `2026-05-05T03:06:16.813Z`). Without
    /// `.withFractionalSeconds`, every such timestamp silently fails to parse.
    /// `ISO8601DateFormatter` is documented as thread-safe for read-only use.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parse a top-level Claude session JSONL into transcript items in file order.
    ///
    /// Only the PARENT file is read. Task/Agent tool calls render as ordinary
    /// tool cards (their description + result); the parser deliberately does NOT
    /// open the `<sessionID>/subagents/agent-*.jsonl` files. Recursively parsing
    /// every subagent transcript made opening a session with many subagents cost
    /// O(all subagent bytes) — ~13s on heavy sessions — for content the UI no
    /// longer surfaces. Parse cost is now O(parent file).
    static func parse(filePath: String) -> [TranscriptItem] {
        let basename = (filePath as NSString).lastPathComponent
        perfLog.debug("parse.start file=\(basename, privacy: .public)")
        let start = ContinuousClock.now
        var totalBytes = 0
        let result = parse(filePath: filePath, totalBytes: &totalBytes)
        let elapsed = ContinuousClock.now - start
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        perfLog.debug("parse.end file=\(basename, privacy: .public) elapsed_ms=\(ms, privacy: .public) items=\(result.count, privacy: .public) bytes=\(totalBytes, privacy: .public)")
        return result
    }

    /// Worker that reads a single Claude JSONL file. Sidechain (subagent) lines
    /// in the parent file are skipped; subagent files are never opened.
    private static func parse(
        filePath: String,
        totalBytes: inout Int
    ) -> [TranscriptItem] {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        totalBytes += data.count

        // First pass: collect raw line dicts; index tool_results.
        var rawLines: [[String: Any]] = []
        // Parallel to rawLines. Stable per-line identifier used as a fallback
        // when a line is missing the `uuid` field. Using a fresh UUID() here
        // would make messagesEqual permanently false for that item (forcing a
        // @Published write on every poll). Line index is process-stable and
        // cheap; in practice every Claude JSONL line carries a `uuid` so this
        // fallback is defensive.
        var stableIDs: [String] = []
        var toolResultsByID: [String: ToolResult] = [:]

        var lineIndex = 0
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            defer { lineIndex += 1 }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            rawLines.append(json)
            stableIDs.append((json["uuid"] as? String) ?? "line-\(lineIndex)")

            if json["type"] as? String == "user",
               let message = json["message"] as? [String: Any],
               let array = message["content"] as? [[String: Any]] {
                let toolResultBlocks = array.filter { ($0["type"] as? String) == "tool_result" }
                for block in toolResultBlocks {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    toolResultsByID[id] = extractToolResult(from: block)
                }
            }
        }

        var items: [TranscriptItem] = []

        for (i, json) in rawLines.enumerated() {
            // Subagent (sidechain) lines belong to a nested agent's own
            // conversation; the parent transcript drops them entirely.
            if json["isSidechain"] as? Bool == true { continue }

            let lineUUID = stableIDs[i]
            let timestamp = (json["timestamp"] as? String).flatMap { iso8601.date(from: $0) }
            let typeStr = json["type"] as? String

            if typeStr == "user", let kind = UserMessageClassifier.classify(json) {
                let text = extractUserText(from: json) ?? ""
                // NOTE: TranscriptItem.slashCommand is no longer emitted — slash commands
                // are flattened into .userPrompt so they render as the user's chat bubble
                // (the slash command IS what the user typed). The case remains in the
                // enum for Codable compatibility with any persisted state.
                if kind == .slashEnvelope {
                    let (name, args) = parseSlashEnvelope(text)
                    let bubbleText: String
                    if let args, !args.isEmpty {
                        bubbleText = "/\(name) \(args)"
                    } else {
                        bubbleText = "/\(name)"
                    }
                    items.append(.userPrompt(id: lineUUID, text: bubbleText, timestamp: timestamp))
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
                let usage = extractUsage(from: message)

                // String-content fallback (matches existing scanner behavior).
                if let s = message["content"] as? String {
                    if !s.isEmpty {
                        items.append(.assistantText(id: "\(lineUUID)#0", text: s, timestamp: timestamp, usage: usage))
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
                            items.append(.assistantText(id: blockID, text: text, timestamp: timestamp, usage: usage))
                        }
                    case "tool_use":
                        let toolID = (block["id"] as? String) ?? blockID
                        let name = (block["name"] as? String) ?? ""
                        let rawInput = block["input"] ?? [:]
                        let (truncatedInput, didTruncate) = truncateInputStrings(rawInput)
                        let inputData = (try? JSONSerialization.data(
                            withJSONObject: didTruncate ? truncatedInput : rawInput,
                            options: [.sortedKeys])) ?? Data()
                        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"
                        let inputTruncatedTo: Int? = {
                            guard didTruncate,
                                  let d = try? JSONSerialization.data(withJSONObject: rawInput, options: [.sortedKeys]),
                                  let s = String(data: d, encoding: .utf8) else { return nil }
                            return s.count
                        }()
                        let result = toolResultsByID[toolID]

                        // Task/Agent tool calls render as ordinary tool cards.
                        // We never open the nested subagent transcript, so
                        // `subagent` is always nil.
                        items.append(.toolCall(
                            id: toolID, name: name, inputJSON: inputJSON,
                            inputTruncatedTo: inputTruncatedTo,
                            result: result, subagent: nil, timestamp: timestamp,
                            usage: usage
                        ))
                    default:
                        continue
                    }
                }
            }
        }

        return items
    }

    /// Extract a `TokenUsage` from `message.usage` if all three input-token
    /// fields are present. Output tokens, cache breakdowns, and other fields
    /// are ignored — we only care about the prompt-size signal.
    private static func extractUsage(from message: [String: Any]) -> TokenUsage? {
        guard let usage = message["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? Int else {
            return nil
        }
        // Cache fields are optional in the Anthropic API: users without
        // prompt caching enabled emit `usage` blocks that omit them
        // entirely. Default to 0 so the badge still surfaces a token count
        // for those sessions.
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        return TokenUsage(
            inputTokens: input,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead
        )
    }

    // MARK: - helpers

    static let bodyCharCap = 2000
    static let bodyLineCap = 20

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

    /// Walks `input` recursively and replaces any string value exceeding the
    /// configured caps with its truncated form. Returns (newInput, anyTruncated).
    static func truncateInputStrings(_ input: Any) -> (Any, Bool) {
        if let s = input as? String {
            let (capped, originalCount) = truncate(s)
            return (capped, originalCount != capped.count)
        }
        if let dict = input as? [String: Any] {
            var out: [String: Any] = [:]
            var anyTrunc = false
            for (k, v) in dict {
                let (newV, t) = truncateInputStrings(v)
                out[k] = newV
                if t { anyTrunc = true }
            }
            return (out, anyTrunc)
        }
        if let arr = input as? [Any] {
            var out: [Any] = []
            var anyTrunc = false
            for v in arr {
                let (newV, t) = truncateInputStrings(v)
                out.append(newV)
                if t { anyTrunc = true }
            }
            return (out, anyTrunc)
        }
        return (input, false)
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
    ///  - `<tool_use_id>#input` → returns the un-truncated `tool_use.input` JSON
    ///  - `<lineUUID>#<blockIndex>` → returns the assistant block's text/thinking
    ///  - bare `lineUUID` → returns the user message content
    static func lookupFullBody(filePath: String, itemID: String) -> String? {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Detect the `#input` suffix variant first — when present, we ONLY scan
        // assistant tool_use blocks for a matching id and return their full input
        // JSON. Other branches are skipped because the unsuffixed id would
        // otherwise fall into the tool_result / uuid scans.
        let inputSuffix = "#input"
        let isInputLookup = itemID.hasSuffix(inputSuffix)
        let toolUseIDForInput: String? = isInputLookup
            ? String(itemID.dropLast(inputSuffix.count))
            : nil

        // Parse the composite id form for the non-input branches.
        let lineUUID: String
        let blockIndex: Int?
        if !isInputLookup, let hashIdx = itemID.firstIndex(of: "#") {
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

            if let toolUseID = toolUseIDForInput {
                // Only scan assistant tool_use blocks; ignore tool_result/uuid branches.
                if let message = json["message"] as? [String: Any],
                   let array = message["content"] as? [[String: Any]] {
                    for block in array where block["type"] as? String == "tool_use" {
                        if (block["id"] as? String) == toolUseID {
                            let input = block["input"] ?? [:]
                            if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
                               let s = String(data: data, encoding: .utf8) {
                                return s
                            }
                        }
                    }
                }
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
