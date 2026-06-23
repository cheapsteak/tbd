import Foundation
import TBDShared

/// Loads REAL Claude Code session JSONL files into `[TranscriptItem]` for the
/// env-gated visual-comparison harness (`TranscriptVisualCompareHarness`).
///
/// The production parser (`TranscriptParser`) lives in `TBDDaemonLib`, which the
/// `TBDAppTests` target does NOT link (it depends only on `TBDApp`). So this is
/// a focused re-implementation that mirrors `TranscriptParser`'s mapping for the
/// common line types — user text, assistant text/thinking, assistant `tool_use`
/// (→ `.toolCall`), and `tool_result` (attached back to the matching tool call).
/// It deliberately covers only the common types; the goal is realistic rendered
/// content to hunt the reported "overlapping bubbles" defect, not byte-perfect
/// fidelity with the daemon.
///
/// Real session files contain real on-disk worktree names in their PATHS only.
/// No such name is committed here: paths are discovered at runtime via a glob in
/// the developer's `~/tbd/profiles/...` tree, or overridden by an env var, so the
/// committed source carries no real fixture names.
enum TranscriptCompareRealSessions {

    /// A real-session scenario: a stable output name plus the resolved JSONL path
    /// and the message window (in *item* indices) to render.
    struct Scenario {
        let name: String
        let jsonlPath: String
        /// Inclusive item-index window into the parsed `[TranscriptItem]`. Full
        /// real sessions can be many MB; we render a representative slice.
        let window: Range<Int>
    }

    /// Resolves the real-session scenarios available on this machine. Returns an
    /// empty array (the harness then skips real scenarios) when no files are
    /// found, so the gated run still succeeds on a machine without these sessions.
    ///
    /// Discovery order per scenario:
    ///  1. An explicit override env var (`TBD_COMPARE_REAL_GOOGLEFLOW` /
    ///     `TBD_COMPARE_REAL_TBD`) — an absolute path to a `.jsonl`.
    ///  2. A glob under `~/tbd/profiles/*/claude/projects/...`.
    static func scenarios() -> [Scenario] {
        var result: [Scenario] = []

        // The "Google Flow" teammate session that reportedly showed the overlap:
        // consecutive user → assistant → tool exchanges. We render a window that
        // includes the opening user prompt and the first few assistant turns +
        // tool calls — the right-aligned-bubble-over-assistant-text pattern.
        if let path = resolve(
            envVar: "TBD_COMPARE_REAL_GOOGLEFLOW",
            // 2907c5ee session. Discovered by id-glob so no worktree name is committed.
            globSessionPrefix: "2907c5ee"
        ) {
            result.append(Scenario(name: "real-googleflow", jsonlPath: path, window: 0..<28))
        }

        // A real TBD session: varied content (prose, tool calls, code, lists).
        if let path = resolve(
            envVar: "TBD_COMPARE_REAL_TBD",
            globSessionPrefix: "0223dcd2"
        ) {
            result.append(Scenario(name: "real-tbd", jsonlPath: path, window: 0..<30))
        }

        return result
    }

    /// Resolve a JSONL path: env-var override first, else a recursive glob under
    /// the profiles dir for a file whose name starts with `globSessionPrefix`.
    private static func resolve(envVar: String, globSessionPrefix: String) -> String? {
        if let override = ProcessInfo.processInfo.environment[envVar],
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let profilesRoot = "\(home)/tbd/profiles"
        return firstJSONL(under: profilesRoot, sessionPrefix: globSessionPrefix)
    }

    /// Depth-limited search for `<sessionPrefix>*.jsonl` under any
    /// `profiles/*/claude/projects/*/` directory. Returns the first match.
    private static func firstJSONL(under profilesRoot: String, sessionPrefix: String) -> String? {
        let fm = FileManager.default
        guard let profiles = try? fm.contentsOfDirectory(atPath: profilesRoot) else { return nil }
        for profile in profiles {
            let projects = "\(profilesRoot)/\(profile)/claude/projects"
            guard let projectDirs = try? fm.contentsOfDirectory(atPath: projects) else { continue }
            for project in projectDirs {
                let dir = "\(projects)/\(project)"
                guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for file in files where file.hasPrefix(sessionPrefix) && file.hasSuffix(".jsonl") {
                    return "\(dir)/\(file)"
                }
            }
        }
        return nil
    }

    // MARK: - Parsing (mirrors TranscriptParser for the common line types)

    private static let bodyCharCap = 2000

    /// Parse a top-level session JSONL into `[TranscriptItem]`. Sidechain lines
    /// are skipped (matching `TranscriptParser`'s top-level pass); subagent
    /// resolution is intentionally omitted — Task tool_use just renders without a
    /// nested disclosure, which is fine for a visual comparison.
    static func parse(filePath: String) -> [TranscriptItem] {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var rawLines: [[String: Any]] = []
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
                for block in array where (block["type"] as? String) == "tool_result" {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    toolResultsByID[id] = extractToolResult(from: block)
                }
            }
        }

        var items: [TranscriptItem] = []
        for (i, json) in rawLines.enumerated() {
            if json["isSidechain"] as? Bool == true { continue }
            let lineUUID = stableIDs[i]
            let timestamp: Date? = nil
            let typeStr = json["type"] as? String

            if typeStr == "user" {
                guard let message = json["message"] as? [String: Any],
                      message["role"] as? String == "user" else { continue }

                // String content: a real typed prompt, unless it's a system
                // envelope we skip (matching the classifier's prefixes).
                if let s = message["content"] as? String {
                    if isSystemEnvelope(s) || s.isEmpty { continue }
                    items.append(.userPrompt(id: lineUUID, text: s, timestamp: timestamp))
                    continue
                }
                guard let array = message["content"] as? [[String: Any]] else { continue }
                // Pure tool_result lines carry no user-authored text.
                if array.allSatisfy({ ($0["type"] as? String) == "tool_result" }) { continue }
                if let text = array.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
                   !text.isEmpty, !isSystemEnvelope(text) {
                    items.append(.userPrompt(id: lineUUID, text: text, timestamp: timestamp))
                }
                continue
            }

            if typeStr == "assistant" {
                guard let message = json["message"] as? [String: Any] else { continue }
                if let s = message["content"] as? String {
                    if !s.isEmpty {
                        items.append(.assistantText(id: "\(lineUUID)#0", text: s, timestamp: timestamp, usage: nil))
                    }
                    continue
                }
                guard let blocks = message["content"] as? [[String: Any]] else { continue }
                for (index, block) in blocks.enumerated() {
                    let blockID = "\(lineUUID)#\(index)"
                    switch block["type"] as? String {
                    case "thinking":
                        let text = (block["thinking"] as? String) ?? ""
                        if !text.isEmpty {
                            items.append(.thinking(id: blockID, text: text, timestamp: timestamp))
                        }
                    case "text":
                        let text = (block["text"] as? String) ?? ""
                        if !text.isEmpty {
                            items.append(.assistantText(id: blockID, text: text, timestamp: timestamp, usage: nil))
                        }
                    case "tool_use":
                        let toolID = (block["id"] as? String) ?? blockID
                        let name = (block["name"] as? String) ?? ""
                        let rawInput = block["input"] ?? [:]
                        let inputData = (try? JSONSerialization.data(
                            withJSONObject: rawInput, options: [.sortedKeys])) ?? Data()
                        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"
                        items.append(.toolCall(
                            id: toolID, name: name, inputJSON: inputJSON,
                            inputTruncatedTo: nil,
                            result: toolResultsByID[toolID], subagent: nil,
                            timestamp: timestamp, usage: nil
                        ))
                    default:
                        continue
                    }
                }
            }
        }
        return items
    }

    /// Slice a parsed session to a representative window of item indices,
    /// clamped to the available count.
    static func parseWindow(filePath: String, window: Range<Int>) -> [TranscriptItem] {
        let all = parse(filePath: filePath)
        guard !all.isEmpty else { return [] }
        let lower = max(0, window.lowerBound)
        let upper = min(all.count, window.upperBound)
        guard lower < upper else { return all }
        return Array(all[lower..<upper])
    }

    // MARK: - helpers (mirror TranscriptParser)

    private static func isSystemEnvelope(_ text: String) -> Bool {
        let prefixes = [
            "<system-reminder", "<command-", "<tool_result", "<local-command-",
            "<environment_details", "Base directory for this skill:",
        ]
        return prefixes.contains(where: { text.hasPrefix($0) })
    }

    private static func extractToolResult(from block: [String: Any]) -> ToolResult {
        let isError = (block["is_error"] as? Bool) ?? false
        let raw: String
        if let s = block["content"] as? String {
            raw = s
        } else if let array = block["content"] as? [[String: Any]] {
            raw = array.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            raw = ""
        }
        let original = raw.count
        var capped = raw
        if original > bodyCharCap { capped = String(raw.prefix(bodyCharCap)) }
        let lines = capped.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 20 { capped = lines.prefix(20).joined(separator: "\n") }
        return ToolResult(
            text: capped,
            truncatedTo: original == capped.count ? nil : original,
            isError: isError
        )
    }
}
