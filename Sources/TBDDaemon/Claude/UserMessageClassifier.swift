import Foundation
import TBDShared

/// Determines whether a decoded JSONL line is a real user-authored message
/// vs. a tool result, system reminder, or other system-generated content.
///
/// This is the single place to update detection heuristics. The fixture at
/// Tests/Fixtures/sample-session.jsonl documents the classification decisions.
enum UserMessageClassifier {

    /// Prefixes that mark system-generated content in the user role.
    private static let systemPrefixes: [String] = [
        "<system-reminder",
        "<command-",
        "<tool_result",
        "<local-command-",
        "<environment_details",
    ]

    /// Case-insensitive substrings that mark injected context blocks (checked after trimming leading `# `).
    private static let injectedContextPrefixes: [String] = [
        "git repository context",
        "repository context",
        "current working directory:",
    ]

    /// Returns true if the parsed JSONL object is a real user message.
    static func isRealUserMessage(_ line: [String: Any]) -> Bool {
        guard
            line["type"] as? String == "user",
            let message = line["message"] as? [String: Any],
            message["role"] as? String == "user"
        else { return false }

        if let content = message["content"] as? String {
            return !hasSystemPrefix(content)
        }

        if let array = message["content"] as? [[String: Any]] {
            // All tool_result blocks → not a real message
            if array.allSatisfy({ $0["type"] as? String == "tool_result" }) {
                return false
            }
            // Check the first text block's content
            if let firstText = array.first(where: { $0["type"] as? String == "text" }),
               let text = firstText["text"] as? String {
                return !hasSystemPrefix(text)
            }
            return false
        }

        return false
    }

    /// Extracts display text from a real user message line. Returns nil if empty.
    /// Precondition: call only on lines that pass `isRealUserMessage` — behavior
    /// on other line types is undefined.
    static func extractText(_ line: [String: Any]) -> String? {
        guard let message = line["message"] as? [String: Any] else { return nil }

        if let text = message["content"] as? String {
            return text.isEmpty ? nil : text
        }

        if let array = message["content"] as? [[String: Any]] {
            return array
                .first(where: { $0["type"] as? String == "text" })
                .flatMap { $0["text"] as? String }
                .flatMap { $0.isEmpty ? nil : $0 }
        }

        return nil
    }

    /// Returns the typed system kind for a user-role JSONL line if it's a
    /// system-injected envelope rather than a real user prompt; returns nil
    /// for real user messages.
    static func classify(_ line: [String: Any]) -> SystemKind? {
        guard
            line["type"] as? String == "user",
            let message = line["message"] as? [String: Any],
            message["role"] as? String == "user"
        else { return nil }

        let text: String
        if let s = message["content"] as? String {
            text = s
        } else if let array = message["content"] as? [[String: Any]] {
            // Pure tool_result blocks aren't user-typed messages and aren't system reminders either.
            if array.allSatisfy({ $0["type"] as? String == "tool_result" }) {
                return nil
            }
            text = (array.first(where: { $0["type"] as? String == "text" })?["text"] as? String) ?? ""
        } else {
            return nil
        }

        if text.hasPrefix("Base directory for this skill:") { return .skillBody }
        if text.hasPrefix("<system-reminder") { return .toolReminder }
        if text.hasPrefix("<command-") { return .slashEnvelope }
        if text.hasPrefix("<environment_details") { return .environmentDetails }
        if text.hasPrefix("<local-command-") { return .hookOutput }

        // Heuristic injected-context detection (markdown headings stripped).
        let stripped = text.hasPrefix("#")
            ? String(text.drop(while: { $0 == "#" || $0 == " " }))
            : text
        let lower = stripped.lowercased()
        if injectedContextPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return .environmentDetails
        }

        // Unknown tag-like prefix → generic "other" injection. The tag must
        // start with `<`, contain only letters/underscores/hyphens, and end at
        // a `>` or whitespace.
        if text.hasPrefix("<"),
           let endOfTag = text.firstIndex(where: { $0 == ">" || $0 == " " }),
           text.distance(from: text.startIndex, to: endOfTag) > 1,
           text[text.index(after: text.startIndex)..<endOfTag].allSatisfy({ $0.isLetter || $0 == "_" || $0 == "-" }) {
            return .other
        }

        return nil
    }

    private static func hasSystemPrefix(_ text: String) -> Bool {
        if systemPrefixes.contains(where: { text.hasPrefix($0) }) { return true }
        // Strip leading markdown heading markers before checking injected context prefixes
        let stripped = text.hasPrefix("#") ? text.drop(while: { $0 == "#" || $0 == " " }) : text[...]
        let lower = stripped.lowercased()
        return injectedContextPrefixes.contains(where: { lower.hasPrefix($0) })
    }
}
