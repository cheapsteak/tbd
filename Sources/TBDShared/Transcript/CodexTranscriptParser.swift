import CryptoKit
import Foundation

/// Reads complete Codex rollout records. Two streaming passes correlate tool
/// outputs and canonical messages even when their matching rows are far apart.
/// Tail parsing retains only its requested items, but still scans earlier
/// records: an arbitrary byte window cannot guarantee the full parse's suffix.
public enum CodexTranscriptParser {
    public static func parse(filePath: String) -> [TranscriptItem] {
        read(filePath: filePath, limit: nil)
    }

    public static func parseTail(filePath: String, limit: Int) -> [TranscriptItem] {
        read(filePath: filePath, limit: max(0, limit))
    }

    private static func read(filePath: String, limit: Int?) -> [TranscriptItem] {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return [] }
        defer { try? handle.close() }
        return (try? parse(fileHandle: handle, limit: limit)) ?? []
    }

    /// The daemon passes its already-authorized descriptor so no path is
    /// reopened between validation and consumption. The caller owns the handle.
    public static func parse(fileHandle: FileHandle, limit: Int? = nil) throws -> [TranscriptItem] {
        if let limit, limit <= 0 { return [] }
        let end = try fileHandle.seekToEnd()
        var canonicalCounts: [Data: Int] = [:]
        var results: [String: ToolResult] = [:]
        var turn = ""
        try records(fileHandle: fileHandle, endOffset: end) { record, offset in
            updateTurn(record, offset: offset, turn: &turn)
            guard let payload = record["payload"] as? [String: Any],
                  record["type"] as? String == "response_item" else { return }
            if let message = message(record) {
                canonicalCounts[message.key(turn: turn), default: 0] += 1
            }
            let type = payload["type"] as? String
            if type == "function_call_output" || type == "custom_tool_call_output",
               let callID = payload["call_id"] as? String {
                results[callID] = toolResult(payload)
            }
        }
        let dates = Dates()
        var items: [TranscriptItem] = []
        var ringIndex = 0
        turn = ""
        try records(fileHandle: fileHandle, endOffset: end) { record, offset in
            updateTurn(record, offset: offset, turn: &turn)
            guard let payload = record["payload"] as? [String: Any] else { return }
            let envelope = record["type"] as? String
            let id = payload["id"] as? String ?? record["id"] as? String ?? "codex-byte-\(offset)"
            let timestamp = dates.parse(record["timestamp"] as? String)
            let item: TranscriptItem
            if let message = message(record) {
                let key = message.key(turn: turn)
                if envelope == "event_msg", let count = canonicalCounts[key], count > 0 {
                    canonicalCounts[key] = count - 1
                    return
                }
                item = message.role == "user"
                    ? .userPrompt(id: id, text: message.text, timestamp: timestamp)
                    : .assistantText(id: id, text: message.text, timestamp: timestamp)
            } else if envelope == "response_item" {
                switch payload["type"] as? String {
                case "reasoning":
                    let text = contentText(payload["summary"]) ?? contentText(payload["content"]) ?? ""
                    guard !text.isEmpty else { return }
                    item = .thinking(id: id, text: text, timestamp: timestamp)
                case "function_call", "custom_tool_call":
                    let toolID = payload["call_id"] as? String ?? id
                    let raw: Any
                    if payload["type"] as? String == "custom_tool_call" {
                        raw = ["input": payload["input"] ?? ""]
                    } else if let arguments = payload["arguments"] as? String {
                        raw = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8), options: [.fragmentsAllowed]))
                            ?? ["arguments": arguments]
                    } else {
                        raw = payload["arguments"] ?? [:]
                    }
                    let (capped, truncated) = TranscriptParser.truncateInputStrings(raw)
                    let input = jsonText(capped)
                    item = .toolCall(id: toolID, name: payload["name"] as? String ?? "", inputJSON: input,
                                     inputTruncatedTo: truncated ? jsonText(raw).count : nil,
                                     result: results[toolID], subagent: nil, timestamp: timestamp)
                default: return
                }
            } else { return }
            if let limit, items.count == limit {
                items[ringIndex] = item
                ringIndex = (ringIndex + 1) % limit
            } else {
                items.append(item)
            }
        }
        if ringIndex > 0 { return Array(items[ringIndex...] + items[..<ringIndex]) }
        return items
    }

    /// Bounded previews for history. Counts complete lines without retaining
    /// them; decodes at most 64 KiB per record and keeps at most 300 characters
    /// of each preview. Oversized tool bodies never enter the summary decoder.
    public struct SummaryMetadata {
        public init() {}
        public var lineCount = 0
        public var firstUserMessage: String?
        public var lastUserMessage: String?
        public var lastMessageAt: Date?
        public var cwd: String?
        public var gitBranch: String?
    }

    public static func summary(fileHandle: FileHandle) throws -> SummaryMetadata {
        var summary = SummaryMetadata()
        let dates = Dates()
        try records(fileHandle: fileHandle, endOffset: fileHandle.seekToEnd(), maxRecordBytes: 65_536,
                    onLine: { summary.lineCount += 1 }) { record, _ in
            if record["type"] as? String == "session_meta", let payload = record["payload"] as? [String: Any] {
                summary.cwd = payload["cwd"] as? String
                summary.gitBranch = (payload["git"] as? [String: Any])?["branch"] as? String
            }
            if let message = message(record), message.role == "user" {
                let preview = String(message.text.prefix(300))
                if summary.firstUserMessage == nil { summary.firstUserMessage = preview }
                summary.lastUserMessage = preview
            }
            if let date = dates.parse(record["timestamp"] as? String) {
                summary.lastMessageAt = max(summary.lastMessageAt ?? date, date)
            }
        }
        return summary
    }

    private struct Message {
        let role: String
        let text: String
        func key(turn: String) -> Data {
            Data(SHA256.hash(data: Data((turn + "\0" + role + "\0" + text).utf8)))
        }
    }

    private static func updateTurn(_ record: [String: Any], offset: UInt64, turn: inout String) {
        guard let payload = record["payload"] as? [String: Any] else { return }
        let type = record["type"] as? String
        guard type == "turn_context" || type == "event_msg" && payload["type"] as? String == "task_started" else { return }
        turn = payload["turn_id"] as? String ?? "codex-turn-byte-\(offset)"
    }

    private static func message(_ record: [String: Any]) -> Message? {
        guard let payload = record["payload"] as? [String: Any] else { return nil }
        let role: String
        let text: String?
        switch record["type"] as? String {
        case "response_item":
            guard payload["type"] as? String == "message",
                  let value = payload["role"] as? String, value == "user" || value == "assistant" else { return nil }
            role = value
            text = role == "user" ? userContentText(payload["content"]) : contentText(payload["content"])
        case "event_msg":
            switch payload["type"] as? String {
            case "user_message": role = "user"
            case "agent_message": role = "assistant"
            default: return nil
            }
            text = payload["message"] as? String
        default: return nil
        }
        guard let text, !text.isEmpty else { return nil }
        return Message(role: role, text: text)
    }

    private static func contentText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return nil }
        let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// Codex writes injected context as its own input-text block. Filter that
    /// block while retaining user text elsewhere in the same response item.
    private static func userContentText(_ value: Any?) -> String? {
        let texts: [String]
        if let text = value as? String {
            texts = [text]
        } else if let blocks = value as? [[String: Any]] {
            texts = blocks.compactMap { $0["text"] as? String }
        } else { return nil }
        let text = texts.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !(trimmed.hasPrefix("<environment_context>") && trimmed.hasSuffix("</environment_context>"))
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func jsonText(_ value: Any) -> String {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
              let text = String(data: bytes, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func toolResult(_ payload: [String: Any]) -> ToolResult {
        let output = payload["output"]
        let object: [String: Any]?
        if let text = output as? String {
            object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        } else { object = output as? [String: Any] }
        let raw = object.flatMap { contentText($0["output"] ?? $0["content"]) }
            ?? contentText(output) ?? output.map(jsonText) ?? ""
        let (text, count) = TranscriptParser.truncate(raw)
        let metadata = object?["metadata"] as? [String: Any]
        let exitCode = metadata?["exit_code"] as? Int ?? object?["exit_code"] as? Int
        let isError = payload["is_error"] as? Bool == true || object?["is_error"] as? Bool == true
            || exitCode.map { $0 != 0 } == true
        return ToolResult(text: text, truncatedTo: text.count == count ? nil : count, isError: isError)
    }

    private struct Dates {
        let fractional: ISO8601DateFormatter
        let seconds = ISO8601DateFormatter()
        init() {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }
        func parse(_ text: String?) -> Date? {
            guard let text else { return nil }
            return fractional.date(from: text) ?? seconds.date(from: text)
        }
    }

    /// Never decodes a whole file or accepts its trailing partial record.
    /// Both transcript passes share the 1 MiB record bound; drain oversized
    /// records to their newline without retaining their remaining bytes.
    /// Absolute byte offsets include malformed records and multi-byte UTF-8.
    private static func records(
        fileHandle: FileHandle, endOffset: UInt64, maxRecordBytes: Int = 1_048_576,
        onLine: () -> Void = {}, consume: ([String: Any], UInt64) -> Void
    ) throws {
        try fileHandle.seek(toOffset: 0)
        var offset: UInt64 = 0
        var readOffset: UInt64 = 0
        var pending = Data()
        var oversized = false
        while readOffset < endOffset,
              let chunk = try fileHandle.read(upToCount: Int(min(65_536, endOffset - readOffset))), !chunk.isEmpty {
            readOffset += UInt64(chunk.count)
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let newline = chunk[start...].firstIndex(of: 0x0A)
                let end = newline ?? chunk.endIndex
                if !oversized {
                    if pending.count + end - start > maxRecordBytes {
                        oversized = true
                        pending.removeAll(keepingCapacity: true)
                    } else { pending.append(contentsOf: chunk[start..<end]) }
                }
                guard let newline else { break }
                onLine()
                if !oversized, let record = try? JSONSerialization.jsonObject(with: pending) as? [String: Any] {
                    consume(record, offset)
                }
                offset = readOffset - UInt64(chunk.count) + UInt64(newline + 1)
                pending.removeAll(keepingCapacity: true)
                oversized = false
                start = newline + 1
            }
        }
    }
}
